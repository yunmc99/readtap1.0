import Foundation
@preconcurrency import Vision

/// Centralized Vision OCR tuning so PDF OCR / image OCR behave consistently.
@MainActor
enum OCRTuning {
    /// Initial model: English + Korean (supports en↔ko and same-language lookups).
    nonisolated static func currentRecognitionLanguages() -> [String] {
        // Stable order matters for reproducibility across pipelines.
        // Allow users to bias OCR language to match their "Translate From" setting.
        let preference = TranslationSource.resolved(from: UserDefaults.standard.string(forKey: "translationSource"))
        switch preference {
        case .english:
            return ["en-US"]
        case .korean:
            return ["ko-KR"]
        case .chinese:
            // Chinese source is not user-selectable; fall back to auto.
            return ["en-US", "ko-KR", "ja-JP", "zh-Hans", "zh-Hant"]
        case .auto:
            return ["en-US", "ko-KR", "ja-JP", "zh-Hans", "zh-Hant"]
        }
    }

    /// Returns language list with Korean prioritized (for Korean-heavy documents).
    nonisolated static func koreanPriorityLanguages() -> [String] {
        let preference = TranslationSource.resolved(from: UserDefaults.standard.string(forKey: "translationSource"))
        switch preference {
        case .english:
            return ["en-US"]
        case .korean:
            return ["ko-KR"]
        case .chinese:
            // Chinese source is not user-selectable; fall back to auto.
            return ["ko-KR", "en-US", "ja-JP", "zh-Hans", "zh-Hant"]
        case .auto:
            return ["ko-KR", "en-US", "ja-JP", "zh-Hans", "zh-Hant"]
        }
    }

    nonisolated static func adaptiveLanguagePlans(
        for baseLanguages: [String],
        sampleText: String
    ) -> [[String]] {
        let hasEnglish = baseLanguages.contains(where: { $0.hasPrefix("en") })
        let hasKorean = baseLanguages.contains(where: { $0.hasPrefix("ko") })
        let hasJapanese = baseLanguages.contains(where: { $0.hasPrefix("ja") })
        let hasChinese = baseLanguages.contains(where: { $0.hasPrefix("zh") })
        guard hasEnglish || hasKorean || hasJapanese || hasChinese else { return [] }
        let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let enLang = baseLanguages.first(where: { $0.hasPrefix("en") }) ?? "en-US"
        let koLang = baseLanguages.first(where: { $0.hasPrefix("ko") }) ?? "ko-KR"
        let jaLang = baseLanguages.first(where: { $0.hasPrefix("ja") }) ?? "ja-JP"
        let zhLang = baseLanguages.first(where: { $0.hasPrefix("zh") }) ?? "zh-Hans"
        let ratio = hangulRatio(in: trimmed)

        let orderedCandidates: [[String]]
        if hasEnglish && hasKorean && hasJapanese && hasChinese {
            if ratio > 0.45 {
                orderedCandidates = [[enLang, koLang], [jaLang, enLang], [zhLang, enLang], [koLang, jaLang], [koLang], [jaLang], [zhLang], [enLang]]
            } else if ratio < 0.12 {
                orderedCandidates = [[enLang, koLang], [jaLang, enLang], [koLang], [enLang], [zhLang, enLang], [jaLang], [zhLang]]
            } else {
                orderedCandidates = [[enLang, koLang], [koLang, enLang], [enLang, zhLang], [zhLang, enLang], [jaLang, enLang], [jaLang], [zhLang], [koLang]]
            }
        } else if hasEnglish && hasKorean {
            if ratio > 0.45 {
                orderedCandidates = [[koLang, enLang], [koLang], [enLang]]
            } else if ratio < 0.08 {
                orderedCandidates = [[enLang], [enLang, koLang], [koLang]]
            } else {
                orderedCandidates = [[enLang, koLang], [koLang, enLang]]
            }
        } else if hasEnglish && hasJapanese && hasChinese {
            if ratio > 0.45 {
                orderedCandidates = [[enLang], [jaLang, enLang], [zhLang, enLang], [enLang, zhLang], [jaLang]]
            } else if ratio < 0.12 {
                orderedCandidates = [[jaLang, enLang], [zhLang, enLang], [enLang], [jaLang], [zhLang]]
            } else {
                orderedCandidates = [[enLang, jaLang], [enLang, zhLang], [zhLang, enLang], [jaLang, enLang], [enLang], [jaLang], [zhLang]]
            }
        } else if hasEnglish && hasJapanese {
            if ratio > 0.45 {
                orderedCandidates = [[enLang], [jaLang, enLang], [jaLang]]
            } else {
                orderedCandidates = [[jaLang, enLang], [enLang], [jaLang]]
            }
        } else if hasEnglish && hasChinese {
            orderedCandidates = [[enLang, zhLang], [zhLang, enLang], [enLang], [zhLang]]
        } else if hasJapanese && hasChinese {
            orderedCandidates = [[jaLang, zhLang], [zhLang, jaLang], [jaLang], [zhLang]]
        } else if hasKorean && hasJapanese {
            orderedCandidates = [[koLang, jaLang], [jaLang, koLang], [koLang], [jaLang]]
        } else if hasKorean && hasChinese {
            orderedCandidates = [[koLang, zhLang], [zhLang, koLang], [koLang], [zhLang]]
        } else {
            return []
        }

        return deduplicatedLanguagePlans(
            orderedCandidates.filter { !$0.isEmpty && $0 != baseLanguages },
            excluded: []
        )
    }

    nonisolated static func deduplicatedLanguagePlans(
        _ plans: [[String]],
        excluded: [String]
    ) -> [[String]] {
        var seen: Set<String> = Set(
            excluded.compactMap { plan in
                let normalized = plan
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return normalized.isEmpty ? nil : normalized
            }
        )
        var output: [[String]] = []
        for plan in plans {
            let normalized = plan
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.isEmpty == false }
                .sorted()
                .joined(separator: "|")
            guard normalized.isEmpty == false else { continue }
            guard seen.insert(normalized).inserted else { continue }
            output.append(plan)
        }
        return output
    }

    nonisolated static func configure(
        _ request: VNRecognizeTextRequest,
        minimumTextHeight: Float,
        languages: [String]? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) {
        let useLanguages = languages ?? currentRecognitionLanguages()
        request.recognitionLevel = recognitionLevel
        request.recognitionLanguages = useLanguages
        request.usesLanguageCorrection = shouldUseLanguageCorrection(for: useLanguages)
        let adjustedMinHeight = adjustedMinTextHeight(minimumTextHeight, for: useLanguages)
        request.minimumTextHeight = recognitionLevel == .fast ? max(adjustedMinHeight, 0.008) : adjustedMinHeight
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
    }

    private nonisolated static func shouldUseLanguageCorrection(for languages: [String]) -> Bool {
        // Enable correction for Latin-based languages only.
        // Korean does not benefit from Latin-oriented language correction.
        let hasKoreanOnly = languages.allSatisfy { $0.hasPrefix("ko") }
        if hasKoreanOnly { return false }
        return languages.contains { $0.hasPrefix("en") || $0.hasPrefix("es") }
    }

    /// Raise minimum text height when Korean is the primary language to reduce noise.
    private nonisolated static func adjustedMinTextHeight(_ base: Float, for languages: [String]) -> Float {
        guard let first = languages.first, first.hasPrefix("ko") else { return base }
        // Korean characters are denser; a slightly higher threshold reduces false positives.
        return max(base, 0.005)
    }

    /// Check if a block of OCR text is predominantly Hangul.
    nonisolated static func hangulRatio(in text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let total = text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
        guard total > 0 else { return 0 }
        let hangul = text.unicodeScalars.filter { scalar in
            let v = Int(scalar.value)
            return (0xAC00...0xD7FF).contains(v) ||
                   (0xA960...0xA97F).contains(v) ||
                   (0x1100...0x11FF).contains(v) ||
                   (0x3130...0x318F).contains(v)
        }.count
        return Double(hangul) / Double(total)
    }
}
