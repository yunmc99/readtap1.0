import Foundation
import NaturalLanguage

enum TranslationSource: String, CaseIterable, Identifiable {
    case auto
    case english
    case korean
    case chinese

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .auto: return AppText.t(.translationSourceAuto)
        case .english: return AppText.t(.languageEnglish)
        case .korean: return AppText.t(.languageKorean)
        case .chinese: return AppText.t(.languageChinese)
        }
    }

    var localeLanguage: String {
        switch self {
        case .auto: return "auto"
        case .english: return "en"
        case .korean: return "ko"
        case .chinese: return "zh-Hans"
        }
    }

    nonisolated static func resolved(from storedValue: String?) -> TranslationSource {
        let raw = (storedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return .auto
        }
        if let source = TranslationSource(rawValue: raw) {
            return source
        }
        // Backwards/forward compatibility: accept locale tags directly.
        if raw.hasPrefix("zh") { return .chinese }
        if raw.hasPrefix("ko") { return .korean }
        if raw.hasPrefix("en") { return .english }
        return .auto
    }

    nonisolated static func migrateIfNeeded() {
        let raw = UserDefaults.standard.string(forKey: "translationSource") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chinese source is no longer user-selectable; migrate to auto.
        if trimmed == TranslationSource.chinese.rawValue || trimmed.hasPrefix("zh") {
            UserDefaults.standard.set(TranslationSource.auto.rawValue, forKey: "translationSource")
            return
        }
        let normalized = TranslationSource.resolved(from: trimmed).rawValue
        if trimmed.isEmpty || normalized != trimmed {
            UserDefaults.standard.set(normalized, forKey: "translationSource")
        }
    }
}

enum TranslationTarget: String, CaseIterable, Identifiable {
    case auto
    case english
    case korean
    case chinese

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .auto: return AppText.t(.translationAuto)
        case .english: return AppText.t(.languageEnglish)
        case .korean: return AppText.t(.languageKorean)
        case .chinese: return AppText.t(.languageChinese)
        }
    }

    var localeLanguage: String {
        switch self {
        case .auto: return "auto"
        case .english: return "en"
        case .korean: return "ko"
        case .chinese: return "zh-Hans"
        }
    }

    static func resolved(from storedValue: String?) -> TranslationTarget {
        let raw = (storedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return .auto
        }
        if let target = TranslationTarget(rawValue: raw) {
            return target
        }
        // Backwards/forward compatibility: accept locale tags directly.
        if raw.hasPrefix("zh") { return .chinese }
        if raw.hasPrefix("ko") { return .korean }
        if raw.hasPrefix("en") { return .english }
        return .auto
    }

    func resolvedLocaleLanguage(forSource source: String) -> String {
        switch self {
        case .english:
            return TranslationTarget.english.localeLanguage
        case .korean:
            return TranslationTarget.korean.localeLanguage
        case .chinese:
            return TranslationTarget.chinese.localeLanguage
        case .auto:
            // Auto-flip logic: detect source and pick appropriate target.
            if source.hasPrefix("en") { return TranslationTarget.korean.localeLanguage }
            if source.hasPrefix("ko") {
                if KoreanDictionaryService.isAvailable() { return TranslationTarget.korean.localeLanguage }
                return TranslationTarget.english.localeLanguage
            }
            if source.hasPrefix("zh") { return TranslationTarget.english.localeLanguage }
            return TranslationTarget.english.localeLanguage
        }
    }

    static func resolvedLocaleLanguage(from storedValue: String?, source: String) -> String {
        resolved(from: storedValue).resolvedLocaleLanguage(forSource: source)
    }

    static func migrateIfNeeded() {
        let raw = UserDefaults.standard.string(forKey: "translationTarget") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.set(TranslationTarget.auto.rawValue, forKey: "translationTarget")
        }
    }

    var directionHint: String {
        let enTarget = resolvedLocaleLanguage(forSource: "en")
        let koTarget = resolvedLocaleLanguage(forSource: "ko")
        let zhTarget = resolvedLocaleLanguage(forSource: "zh-Hans")
        let koLabel = koTarget == "ko" ? "KO(\(AppText.L("Dict", "사전", "词典")))" : koTarget.uppercased()
        let zhLabel = zhTarget.hasPrefix("zh") ? "ZH" : zhTarget.uppercased()
        return "EN ➜ \(enTarget.uppercased()) / KO ➜ \(koLabel) / ZH ➜ \(zhLabel)"
    }
}

enum DetectedLanguage: String {
    case english
    case korean
    case spanish
    case japanese
    case simplifiedChinese
    case traditionalChinese
    case unknown

    var code: String {
        switch self {
        case .english: return "en"
        case .korean: return "ko"
        case .spanish: return "es"
        case .japanese: return "ja"
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .unknown: return "und"
        }
    }
}

struct LanguageDetector {
    struct Result {
        let language: DetectedLanguage
        let confidence: Double
    }

    static func detect(_ text: String) -> DetectedLanguage {
        detectResult(text).language
    }

    static func detectResult(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(language: .unknown, confidence: 0) }

        if let heuristic = detectByScriptHeuristics(trimmed) {
            return heuristic
        }

        if containsHangul(trimmed) {
            return Result(language: .korean, confidence: 0.98)
        }
        if containsKana(trimmed) {
            return Result(language: .japanese, confidence: 0.98)
        }
        if containsHan(trimmed) {
            return Result(language: guessByScript(trimmed), confidence: 0.9)
        }
        if containsLatin(trimmed) && trimmed.unicodeScalars.allSatisfy({ ch in
            let v = ch.value
            return (0x0041...0x007A).contains(v)
                || (0x00C0...0x024F).contains(v)
                || (0x1E00...0x1EFF).contains(v)
                || CharacterSet.whitespacesAndNewlines.contains(ch)
        }) {
            return Result(language: .english, confidence: 0.9)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        // Prefer hypotheses so we can reason about confidence for short tokens.
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        if let (topLang, topConfidence) = hypotheses.max(by: { $0.value < $1.value }) {
            let mapped = map(topLang, fallbackText: trimmed)
            return Result(language: mapped, confidence: Double(topConfidence))
        }

        guard let lang = recognizer.dominantLanguage else {
            return Result(language: guessByScript(trimmed), confidence: 0)
        }
        let mapped = map(lang, fallbackText: trimmed)
        return Result(language: mapped, confidence: 0)
    }

    private static func detectByScriptHeuristics(_ text: String) -> Result? {
        let metrics = scriptMetrics(for: text)
        guard metrics.totalCharacterCount >= 2 else { return nil }

        let total = Double(metrics.totalCharacterCount)
        let hangulRatio = Double(metrics.hangulCount) / total
        let kanaRatio = Double(metrics.kanaCount) / total
        let hanRatio = Double(metrics.hanCount) / total
        let latinRatio = Double(metrics.latinCount) / total

        if metrics.hangulCount > 0 && (hangulRatio >= 0.18 || (hangulRatio >= 0.08 && latinRatio < 0.12)) {
            return Result(language: .korean, confidence: min(0.98, 0.74 + (hangulRatio * 1.2)))
        }

        if metrics.kanaCount > 0 && kanaRatio >= 0.18 {
            return Result(language: .japanese, confidence: min(0.98, 0.74 + (kanaRatio * 1.2)))
        }

        if metrics.hanCount > 0 {
            if metrics.hangulCount == 0 && latinRatio < 0.15 {
                return Result(language: detectedChineseVariant(from: text), confidence: 0.72 + min(0.24, hanRatio * 1.4))
            }
        }

        if metrics.latinCount > 0 && metrics.hangulCount == 0 && metrics.kanaCount == 0 && metrics.hanCount == 0 {
            return Result(language: .english, confidence: min(0.95, 0.78 + (latinRatio * 0.6)))
        }

        return nil
    }

    private static func scriptMetrics(for text: String) -> (hangulCount: Int, kanaCount: Int, hanCount: Int, latinCount: Int, totalCharacterCount: Int) {
        var hangulCount = 0
        var kanaCount = 0
        var hanCount = 0
        var latinCount = 0
        var total = 0

        for scalar in text.unicodeScalars {
            let isSeparator = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
            guard !isSeparator else { continue }

            let value = Int(scalar.value)
            let isHangul = (0xAC00...0xD7AF).contains(value)
                || (0x1100...0x11FF).contains(value)
                || (0x3130...0x318F).contains(value)
                || (0xA960...0xA97F).contains(value)
                || (0xD7B0...0xD7FF).contains(value)
                || (0xD7CB...0xD7FB).contains(value)
            let isKana = (0x3040...0x309F).contains(value)
                || (0x30A0...0x30FF).contains(value)
                || (0x31F0...0x31FF).contains(value)
            let isHan = (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0x20000...0x2A6DF).contains(value)
            let isLatin = (0x0041...0x007A).contains(value)
                || (0x00C0...0x024F).contains(value)
                || (0x1E00...0x1EFF).contains(value)
                || (0x0030...0x0039).contains(value)

            if isHangul { hangulCount += 1; total += 1; continue }
            if isKana { kanaCount += 1; total += 1; continue }
            if isHan { hanCount += 1; total += 1; continue }
            if isLatin { latinCount += 1; total += 1; continue }
        }

        return (hangulCount: hangulCount, kanaCount: kanaCount, hanCount: hanCount, latinCount: latinCount, totalCharacterCount: total)
    }

    private static func map(_ lang: NLLanguage, fallbackText: String) -> DetectedLanguage {
        switch lang {
        case .english: return .english
        case .korean: return .korean
        case .spanish: return .spanish
        case .japanese: return .japanese
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        case .undetermined:
            // Common for short tokens (single words). Fall back to script heuristics.
            return guessByScript(fallbackText)
        default:
            // Avoid "und" for short Latin/Korean tokens where script is obvious.
            return guessByScript(fallbackText)
        }
    }

    private static func guessByScript(_ text: String) -> DetectedLanguage {
        // NLLanguageRecognizer can return nil for short tokens; fall back to script heuristics.
        if containsHangul(text) { return .korean }
        if containsKana(text) { return .japanese }
        if containsHan(text) { return detectedChineseVariant(from: text) }
        if containsLatin(text) { return .english }
        return .unknown
    }

    private static func detectedChineseVariant(from text: String) -> DetectedLanguage {
        guard containsHan(text) else { return .unknown }

        if containsTraditionalChineseMarker(text) {
            return .traditionalChinese
        }
        if containsSimplifiedChineseMarker(text) {
            return .simplifiedChinese
        }
        return .simplifiedChinese
    }

    private static func containsTraditionalChineseMarker(_ text: String) -> Bool {
        let traditionalOnlyScalars: Set<UInt32> = [
            0x5F8C, // 後
            0x9EDE, // 點
            0x5F8A, // 徊
            0x908A, // 邊
            0x9084, // 還
            0x88E1, // 裡
            0x81FA, // 臺
            0x500B, // 個
            0x9EBC, // 麼
            0x982D, // 頭
            0x9E97, // 黃
            0x9AD4, // 體
            0x5B57, // 字 (common Traditional/Kanji mixed, acts as weak hint only)
            0x8F38  // 輸
        ]

        return text.unicodeScalars.contains { scalar in
            traditionalOnlyScalars.contains(scalar.value)
        }
    }

    private static func containsSimplifiedChineseMarker(_ text: String) -> Bool {
        let simplifiedOnlyScalars: Set<UInt32> = [
            0x540E, // 后
            0x70B9, // 点
            0x8FD9, // 这
            0x8FB9, // 边
            0x91CC, // 里
            0x4EEC, // 们
            0x7F51, // 网
            0x5F00, // 开
            0x4F53, // 体
            0x5B66, // 学
            0x8FD8, // 还
            0x4E2A, // 个
            0x5BF9, // 对
            0x6E29  // 温 (weak hint)
        ]

        return text.unicodeScalars.contains { scalar in
            simplifiedOnlyScalars.contains(scalar.value)
        }
    }

    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: { scalar in
            (0xAC00...0xD7AF).contains(Int(scalar.value)) || // Hangul Syllables
            (0x1100...0x11FF).contains(Int(scalar.value)) || // Hangul Jamo
            (0x3130...0x318F).contains(Int(scalar.value)) || // Hangul Compatibility Jamo
            (0xA960...0xA97F).contains(Int(scalar.value)) || // Hangul Jamo Extended-A
            (0xD7B0...0xD7FF).contains(Int(scalar.value)) || // Hangul Jamo Extended-B
            (0xD7CB...0xD7FB).contains(Int(scalar.value)) // Hangul Jamo Extended-C (subset)
        })
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: { scalar in
            (0x3040...0x309F).contains(Int(scalar.value)) || // Hiragana
            (0x30A0...0x30FF).contains(Int(scalar.value)) || // Katakana
            (0x31F0...0x31FF).contains(Int(scalar.value))    // Katakana Phonetic Extensions
        })
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: { scalar in
            // Basic CJK Unified Ideographs + Extension A (good enough for quick heuristics).
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
            (0x3400...0x4DBF).contains(Int(scalar.value))
        })
    }

    private static func containsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: { scalar in
            let v = Int(scalar.value)
            // ASCII + Latin-1 Supplement + Latin Extended blocks.
            return (0x0041...0x007A).contains(v)
                || (0x00C0...0x024F).contains(v)
                || (0x1E00...0x1EFF).contains(v)
        })
    }
}
