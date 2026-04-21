//
//  PronunciationPlayer.swift
//  readtap
//
//  Shared AVSpeechSynthesizer wrapper used by WordPopupView and FlashcardDeckView
//  to read out a word (or meaning) in its source/target language.
//

import Foundation
import Combine
import AVFoundation
import NaturalLanguage

enum PronunciationSpeedPreset: String, CaseIterable {
    case slow
    case normal
    case fast

    var rate: Double {
        switch self {
        case .slow:   return 0.38
        case .normal: return PronunciationPlayer.defaultRate
        case .fast:   return 0.52
        }
    }

    /// Returns the preset whose rate is closest to `raw`.
    static func nearest(to raw: Double) -> PronunciationSpeedPreset {
        allCases.min(by: { abs($0.rate - raw) < abs($1.rate - raw) }) ?? .normal
    }
}

@MainActor
final class PronunciationPlayer: NSObject, ObservableObject {
    static let shared = PronunciationPlayer()

    static let defaultRate: Double = 0.45
    static let minRate: Double = 0.35
    static let maxRate: Double = 0.55
    static let rateStorageKey = "pronunciationRate"

    private let synthesizer = AVSpeechSynthesizer()

    /// The text currently being spoken, or nil if idle. Views can observe this to
    /// flip the speaker icon to its filled/active state while playback is live.
    @Published private(set) var speakingText: String?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` using a voice matching the `language` hint (BCP-47 or ISO short
    /// code like "en" / "ko" / "zh"). If the hint is nil or unresolvable, falls back
    /// to NLLanguageRecognizer detection, then to the device locale.
    ///
    /// Uses `.playback` so audio plays even when the ringer switch is set to silent
    /// (standard dictionary-app behavior — the user explicitly tapped to hear audio).
    ///
    /// Calling while already speaking stops the current utterance and starts the new one.
    func speak(_ text: String, language: String? = nil) {
        performSpeak(text, language: language, respectSilentSwitch: false)
    }

    /// Like `speak`, but uses `.ambient` so the hardware silent switch mutes playback.
    /// Intended for passive preview UI (e.g. Settings speed preset buttons) where a
    /// sudden sound in a muted phone would be disruptive.
    func speakPreview(_ text: String, language: String? = nil) {
        performSpeak(text, language: language, respectSilentSwitch: true)
    }

    private func performSpeak(_ text: String, language: String?, respectSilentSwitch: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        configureAudioSession(respectSilentSwitch: respectSilentSwitch)

        let voiceLanguage = resolveVoiceLanguage(language: language, text: trimmed)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.rate = Float(Self.currentRate)
        utterance.pitchMultiplier = 1.0

        speakingText = trimmed
        synthesizer.speak(utterance)
    }

    /// `.playback` (+ `.duckOthers`) plays over music and ignores the silent switch.
    /// `.ambient` mixes with other audio and obeys the silent switch — so a muted
    /// phone stays quiet.
    private func configureAudioSession(respectSilentSwitch: Bool) {
        let session = AVAudioSession.sharedInstance()
        if respectSilentSwitch {
            try? session.setCategory(.ambient, mode: .spokenAudio, options: [])
        } else {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try? session.setActive(true, options: [])
    }

    /// Stops any in-flight playback.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speakingText = nil
    }

    /// Returns true when `text` is the utterance currently being spoken.
    func isSpeaking(_ text: String) -> Bool {
        guard let speakingText else { return false }
        return speakingText == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rate persistence

    static var currentRate: Double {
        let raw = UserDefaults.standard.object(forKey: rateStorageKey) as? Double ?? defaultRate
        return max(minRate, min(maxRate, raw))
    }

    static func setRate(_ rate: Double) {
        let clamped = max(minRate, min(maxRate, rate))
        UserDefaults.standard.set(clamped, forKey: rateStorageKey)
    }

    // MARK: - Language resolution

    private func resolveVoiceLanguage(language: String?, text: String) -> String {
        if let language, let mapped = mapToBCP47(language) {
            return mapped
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let detected = recognizer.dominantLanguage?.rawValue,
           let mapped = mapToBCP47(detected) {
            return mapped
        }
        return Locale.current.identifier
    }

    private func mapToBCP47(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let short = lower.split(separator: "-").first.map(String.init) ?? lower
        switch short {
        case "en": return "en-US"
        case "ko": return "ko-KR"
        case "zh":
            if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") {
                return "zh-TW"
            }
            return "zh-CN"
        case "ja": return "ja-JP"
        case "es": return "es-ES"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "it": return "it-IT"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        default:
            if AVSpeechSynthesisVoice(language: raw) != nil {
                return raw
            }
            return nil
        }
    }
}

extension PronunciationPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.speakingText = nil }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.speakingText = nil }
    }
}
