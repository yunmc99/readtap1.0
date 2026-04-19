import Foundation
import UIKit
import NaturalLanguage

struct LookupNormalizationResult {
    let original: String
    let cleaned: String
    let selected: String
    let candidates: [String]
}

enum LookupNormalizer {
    static func normalizeForLookup(text: String, detectedLanguage: DetectedLanguage) -> LookupNormalizationResult {
        let original = text
        let cleaned = clean(text)
        guard !cleaned.isEmpty else {
            return LookupNormalizationResult(original: original, cleaned: "", selected: "", candidates: [])
        }

        var candidates: [String] = []
        candidates.reserveCapacity(8)
        candidates.append(cleaned)

        let script = ScriptKind.of(cleaned)
        var selected = cleaned

        switch script {
        case .latin:
            let spellcheckLanguages = preferredSpellcheckLanguages(for: detectedLanguage)

            // OCR/PDF text often injects spaces inside a single long word (e.g. "m a t h e m a t i c a l",
            // or line-break hyphenation like "mathemat- ical"). If joining yields a valid word, prefer it.
            if cleaned.contains(where: { $0.isWhitespace }) {
                let joined = cleaned.replacingOccurrences(of: " ", with: "")
                if joined != cleaned {
                    candidates.append(joined)
                    if let correction = bestLatinCorrection(for: joined, languages: spellcheckLanguages) {
                        let cased = applyCasing(from: joined, to: correction)
                        if cased != joined {
                            candidates.append(cased)
                        }
                        if spellcheckLanguages.contains(where: { !isMisspelled(cased, language: $0) }) {
                            selected = cased
                        }
                    }
                    if selected == cleaned, spellcheckLanguages.contains(where: { !isMisspelled(joined, language: $0) }) {
                        selected = joined
                    }
                }
            }

            if let correction = bestLatinCorrection(for: cleaned, languages: spellcheckLanguages) {
                let cased = applyCasing(from: cleaned, to: correction)
                if cased != cleaned {
                    candidates.append(cased)
                }
                selected = cased
            }

            if let split = bestLatinSplitIfMerged(for: cleaned, languages: spellcheckLanguages), split != cleaned {
                candidates.append(split)
                // When the entire input was a merged run (no spaces), prefer the
                // split form so the popup title shows proper word boundaries.
                if !cleaned.contains(where: { $0.isWhitespace }) {
                    selected = split
                }
            }

        case .hangul:
            // Korean OCR sometimes splits a single word into per-syllable tokens ("안 녕 하 세 요").
            // Only auto-join when every token is a single Hangul syllable to avoid breaking real spacing.
            if cleaned.contains(where: { $0.isWhitespace }) {
                let parts = cleaned.split(separator: " ").map(String.init)
                if parts.count >= 2, parts.allSatisfy({ isSingleHangulSyllable($0) }) {
                    let joined = parts.joined()
                    if joined != cleaned {
                        candidates.append(joined)
                        selected = joined
                    }
                }
            }

        default:
            break
        }
        
        // --- NLTagger Lemmatization (Root word extraction) ---
        // If the word is a past-tense verb ("saw"), plural noun ("leaves"), or comparative ("best"),
        // Apple's NLTagger will extract the dictionary root form ("see", "leave", "good").
        // This guarantees that dictionaries (Local or Network) can match the exact root word.
        if script == .latin, detectedLanguage.code.hasPrefix("en") {
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = selected
            if let lemma = tagger.tag(at: selected.startIndex, unit: .word, scheme: .lemma).0,
               let rawValue = lemma.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as String?,
               !rawValue.isEmpty,
               rawValue != selected.lowercased()
            {
                // Inject the lemma (root word) as the secondary candidate just behind the original string.
                candidates.insert(rawValue, at: 1)
            }
        }

        let unique = uniqueStringsPreservingOrder(candidates)
        if !unique.contains(selected) {
            selected = unique.first ?? cleaned
        }
        return LookupNormalizationResult(original: original, cleaned: cleaned, selected: selected, candidates: unique)
    }

    private static func clean(_ text: String) -> String {
        let canonical = text.precomposedStringWithCanonicalMapping
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let sansZeroWidth = trimmed
            .replacingOccurrences(of: "\u{200B}", with: "") // zero-width space
            .replacingOccurrences(of: "\u{2060}", with: "") // word joiner
            .replacingOccurrences(of: "\u{FEFF}", with: "") // zero-width no-break space
            .replacingOccurrences(of: "\u{00AD}", with: "") // soft hyphen (line-break hyphenation)

        let normalizedWhitespace = sansZeroWidth
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        // Normalize apostrophes/quotes for Latin spellcheck.
        let normalizedQuotes = normalizedWhitespace
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")

        let deLigatured = normalizedQuotes
            .replacingOccurrences(of: "\u{FB00}", with: "ff")
            .replacingOccurrences(of: "\u{FB01}", with: "fi")
            .replacingOccurrences(of: "\u{FB02}", with: "fl")
            .replacingOccurrences(of: "\u{FB03}", with: "ffi")
            .replacingOccurrences(of: "\u{FB04}", with: "ffl")
            .replacingOccurrences(of: "\u{FB05}", with: "ft")
            .replacingOccurrences(of: "\u{FB06}", with: "st")

        // OCR can produce Cyrillic/Greek homoglyphs that look like Latin letters (e.g. "rоbust" where "о" is Cyrillic).
        // Normalize a small safe subset so language detection/lookup behaves consistently for en/ko flows.
        let homoglyphNormalized = normalizeLatinHomoglyphsIfNeeded(deLigatured)

        return trimEdgePunctuation(homoglyphNormalized)
    }

    private static func applyCasing(from source: String, to suggestion: String) -> String {
        guard !source.isEmpty, !suggestion.isEmpty else { return suggestion }

        let letters = source.filter { $0.isLetter }
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) {
            return suggestion.uppercased()
        }

        if let first = source.first, first.isUppercase,
           source.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) {
            return suggestion.prefix(1).uppercased() + String(suggestion.dropFirst())
        }

        return suggestion
    }

    private static func trimEdgePunctuation(_ text: String) -> String {
        if text.isEmpty { return "" }
        var start = text.startIndex
        var end = text.endIndex

        func isTrimChar(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar)
                    || CharacterSet.punctuationCharacters.contains(scalar)
                    || CharacterSet.symbols.contains(scalar)
            }
        }

        while start < end, isTrimChar(text[start]) {
            start = text.index(after: start)
        }
        while end > start {
            let prev = text.index(before: end)
            if isTrimChar(text[prev]) {
                end = prev
            } else {
                break
            }
        }
        return start < end ? String(text[start..<end]) : ""
    }

    private static func uniqueStringsPreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(items.count)
        for item in items {
            let key = item.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            output.append(item)
        }
        return output
    }

    private static func isSingleHangulSyllable(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        let v = Int(scalar.value)
        return (0xAC00...0xD7AF).contains(v)
    }

    private static func normalizeLatinHomoglyphsIfNeeded(_ text: String) -> String {
        guard text.isEmpty == false else { return text }
        // Only run when there's some ASCII Latin and at least one likely-confusable scalar.
        let hasASCIILatin = text.unicodeScalars.contains(where: { scalar in
            let v = Int(scalar.value)
            return (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
        })
        guard hasASCIILatin else { return text }

        let hasConfusable = text.unicodeScalars.contains(where: { scalar in
            let v = Int(scalar.value)
            // Cyrillic basic + Greek basic ranges where common homoglyphs live.
            return (0x0370...0x03FF).contains(v) || (0x0400...0x04FF).contains(v)
        })
        guard hasConfusable else { return text }

        var didChange = false
        var output = String.UnicodeScalarView()
        output.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if let replacement = latinHomoglyphReplacement(scalar) {
                didChange = true
                output.append(replacement)
            } else {
                output.append(scalar)
            }
        }
        return didChange ? String(output) : text
    }

    private static func latinHomoglyphReplacement(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.value {
        // Cyrillic lowercase
        case 0x0430: return Unicode.Scalar(0x0061) // а -> a
        case 0x0435: return Unicode.Scalar(0x0065) // е -> e
        case 0x043E: return Unicode.Scalar(0x006F) // о -> o
        case 0x0440: return Unicode.Scalar(0x0070) // р -> p
        case 0x0441: return Unicode.Scalar(0x0063) // с -> c
        case 0x0445: return Unicode.Scalar(0x0078) // х -> x
        case 0x0443: return Unicode.Scalar(0x0079) // у -> y
        case 0x0456: return Unicode.Scalar(0x0069) // і -> i
        case 0x0455: return Unicode.Scalar(0x0073) // ѕ -> s
        case 0x0442: return Unicode.Scalar(0x0074) // т -> t
        case 0x043D: return Unicode.Scalar(0x0068) // н -> h
        case 0x043A: return Unicode.Scalar(0x006B) // к -> k
        case 0x043C: return Unicode.Scalar(0x006D) // м -> m
        case 0x0432: return Unicode.Scalar(0x0062) // в -> b

        // Cyrillic uppercase
        case 0x0410: return Unicode.Scalar(0x0041) // А -> A
        case 0x0415: return Unicode.Scalar(0x0045) // Е -> E
        case 0x041E: return Unicode.Scalar(0x004F) // О -> O
        case 0x0420: return Unicode.Scalar(0x0050) // Р -> P
        case 0x0421: return Unicode.Scalar(0x0043) // С -> C
        case 0x0425: return Unicode.Scalar(0x0058) // Х -> X
        case 0x0423: return Unicode.Scalar(0x0059) // У -> Y
        case 0x0406: return Unicode.Scalar(0x0049) // І -> I
        case 0x0422: return Unicode.Scalar(0x0054) // Т -> T
        case 0x041D: return Unicode.Scalar(0x0048) // Н -> H
        case 0x041A: return Unicode.Scalar(0x004B) // К -> K
        case 0x041C: return Unicode.Scalar(0x004D) // М -> M
        case 0x0412: return Unicode.Scalar(0x0042) // В -> B

        // Greek (common in OCR confusables)
        case 0x03BF: return Unicode.Scalar(0x006F) // ο -> o
        case 0x039F: return Unicode.Scalar(0x004F) // Ο -> O
        case 0x03B1: return Unicode.Scalar(0x0061) // α -> a
        case 0x0391: return Unicode.Scalar(0x0041) // Α -> A
        case 0x03C1: return Unicode.Scalar(0x0070) // ρ -> p
        case 0x03A1: return Unicode.Scalar(0x0050) // Ρ -> P
        case 0x03C7: return Unicode.Scalar(0x0078) // χ -> x
        case 0x03A7: return Unicode.Scalar(0x0058) // Χ -> X
        default:
            return nil
        }
    }

    private enum ScriptKind: Equatable {
        case latin
        case hangul
        case kana
        case han
        case mixed
        case unknown

        static func of(_ text: String) -> ScriptKind {
            var latin = 0
            var hangul = 0
            var kana = 0
            var han = 0
            var otherLetters = 0

            for scalar in text.unicodeScalars {
                let v = Int(scalar.value)
                if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) {
                    hangul += 1
                } else if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) {
                    kana += 1
                } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                    han += 1
                } else if isLatinScalar(v) {
                    latin += 1
                } else if CharacterSet.letters.contains(scalar) {
                    otherLetters += 1
                }
            }

            let buckets = [(ScriptKind.latin, latin), (.hangul, hangul), (.kana, kana), (.han, han)]
            let nonZero = buckets.filter { $0.1 > 0 }
            if nonZero.count > 1 { return .mixed }
            if let (kind, count) = buckets.max(by: { $0.1 < $1.1 }), count > 0 { return kind }
            if otherLetters > 0 { return .unknown }
            return .unknown
        }

        private static func isLatinScalar(_ v: Int) -> Bool {
            // ASCII + Latin-1 Supplement + Latin Extended blocks.
            (0x0041...0x007A).contains(v)
                || (0x00C0...0x024F).contains(v)
                || (0x1E00...0x1EFF).contains(v)
        }
    }

    private static func preferredSpellcheckLanguages(for detected: DetectedLanguage) -> [String] {
        let available = Set(UITextChecker.availableLanguages)

        func pick(_ preferred: String, prefix: String) -> String? {
            if available.contains(preferred) { return preferred }
            return UITextChecker.availableLanguages.first(where: { $0.hasPrefix(prefix) })
        }

        switch detected {
        case .spanish:
            return [pick("es_ES", prefix: "es")].compactMap { $0 }
        case .english:
            return [pick("en_US", prefix: "en")].compactMap { $0 }
        default:
            // Unknown or non-Latin: try English first, then Spanish.
            return [
                pick("en_US", prefix: "en"),
                pick("es_ES", prefix: "es")
            ].compactMap { $0 }
        }
    }

    private static func bestLatinCorrection(for word: String, languages: [String]) -> String? {
        guard isLatinWordLike(word) else { return nil }
        guard word.count > 2 else { return nil }
        guard word.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }

        for language in languages {
            let checker = UITextChecker()
            let range = NSRange(location: 0, length: word.utf16.count)
            let miss = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
            guard miss.location != NSNotFound else { continue }

            guard let guesses = checker.guesses(forWordRange: miss, in: word, language: language),
                  let best = guesses.first else {
                continue
            }

            let distance = editDistance(word.lowercased(), best.lowercased())
            let maxDistance = word.count >= 6 ? 2 : 1
            // For OCR, the first character is frequently wrong ("hationalism" vs "nationalism"),
            // so don't require first-letter match on longer tokens.
            let requiresFirstMatch = (word.count <= 5)
            let firstMatches = (word.first?.lowercased() == best.first?.lowercased())
            if distance <= maxDistance, (!requiresFirstMatch || firstMatches) {
                return best
            }
        }

        return nil
    }

    private static func bestLatinSplitIfMerged(for word: String, languages: [String]) -> String? {
        guard isLatinWordLike(word) else { return nil }
        guard !word.contains(where: { $0.isWhitespace }) else { return nil }
        guard word.count >= 4 else { return nil }
        guard word.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }

        for language in languages {
            if isMisspelled(word, language: language),
               let parts = splitMergedLatinWord(word, language: language),
               parts.count >= 2 {
                return parts.joined(separator: " ")
            }
        }
        return nil
    }

    private static func isLatinWordLike(_ word: String) -> Bool {
        // Restrict to letter-ish tokens (Latin + diacritics), apostrophes and hyphens.
        // This avoids corrupting Hangul/Kana/Han scripts with Latin spellcheck.
        let chars = word
        guard chars.count >= 1 else { return false }
        return chars.allSatisfy { ch in
            ch.isLetter || ch == "'" || ch == "-" || ch == "’"
        }
    }

    private static func isMisspelled(_ word: String, language: String) -> Bool {
        let checker = UITextChecker()
        let nsRange = NSRange(location: 0, length: word.utf16.count)
        let miss = checker.rangeOfMisspelledWord(in: word, range: nsRange, startingAt: 0, wrap: false, language: language)
        return miss.location != NSNotFound
    }

    private static func splitMergedLatinWord(_ word: String, language: String) -> [String]? {
        let chars = Array(word)
        let n = chars.count
        guard n >= 4 else { return nil }

        // DP word-break: dp[i] = (start of last word, total word count) for
        // the best split of chars[0..<i] into valid dictionary words.
        // Supports any number of merged words (not just 2–3).
        var dp: [(prev: Int, count: Int)?] = Array(repeating: nil, count: n + 1)
        dp[0] = (prev: 0, count: 0)

        let maxWordLen = min(n, 20)

        for end in 2...n {
            let earliest = max(0, end - maxWordLen)
            for start in earliest...(end - 2) {
                guard let prev = dp[start] else { continue }
                let sub = String(chars[start..<end])
                if !isMisspelled(sub, language: language) {
                    let newCount = prev.count + 1
                    if dp[end] == nil || newCount < dp[end]!.count {
                        dp[end] = (prev: start, count: newCount)
                    }
                }
            }
        }

        guard let final = dp[n], final.count >= 2 else { return nil }

        var parts: [String] = []
        var pos = n
        while pos > 0 {
            guard let entry = dp[pos] else { break }
            parts.append(String(chars[entry.prev..<pos]))
            pos = entry.prev
        }
        parts.reverse()

        guard parts.count >= 2 else { return nil }
        guard parts.contains(where: { $0.count >= 3 }) else { return nil }
        return parts
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var current = Array(repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    current[j] = prev[j - 1]
                } else {
                    current[j] = min(prev[j - 1], prev[j], current[j - 1]) + 1
                }
            }
            prev = current
        }
        return prev[bChars.count]
    }

    // MARK: - Lemmatization (free-tier dictionary lookup)

    /// Return the dictionary root form of `word` when NLTagger can identify one.
    ///
    /// This is a cheaper, more focused entry point than `normalizeForLookup` for
    /// consumers that only need lemmatization (e.g. free-tier dictionary lookup).
    /// English, Korean, and other NLTagger-supported languages all route here.
    ///
    /// - Parameters:
    ///   - word: Raw word (any case, may contain whitespace; will be trimmed).
    ///   - context: Optional surrounding sentence. Improves NLTagger accuracy
    ///              for ambiguous inflections (e.g. "leaves" as verb vs noun).
    /// - Returns: Lemma if found and different from the input; otherwise the
    ///            lowercased trimmed input.
    static func lemmatize(_ word: String, in context: String? = nil) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Prefer running NLTagger over the surrounding context so part-of-speech
        // disambiguation has signal. Fall back to the word alone.
        let target: String = {
            guard let context, !context.isEmpty, context.contains(trimmed) else {
                return trimmed
            }
            return context
        }()

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = target

        // Locate the range of `trimmed` inside `target` (they may differ when
        // context was provided).
        let range: Range<String.Index>? = target.range(of: trimmed, options: [.caseInsensitive])

        let (lemma, _) = tagger.tag(
            at: range?.lowerBound ?? target.startIndex,
            unit: .word,
            scheme: .lemma
        )
        if let lemmaValue = lemma?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !lemmaValue.isEmpty {
            return lemmaValue.lowercased()
        }
        return trimmed.lowercased()
    }

    /// Return every plausible base-form candidate for an inflected or attached
    /// word, in try-first order (most-likely hit first). Language-aware:
    /// English runs NLTagger + suffix rules + irregular tables; Korean runs
    /// particle stripping.
    ///
    /// The returned list always starts with the pre-normalized input (trimmed,
    /// smart-quote-folded, NFC, lowercased), followed by language-specific
    /// candidates. Duplicates are removed preserving order; cap at 6 so the
    /// server's bounded IN-clause stays healthy.
    ///
    /// - Parameters:
    ///   - word: Raw token from user tap.
    ///   - language: ISO 639-1 code of the source language. Drives which
    ///               candidate rules run. "en"/"ko" are supported; others fall
    ///               back to just the pre-normalized input.
    ///   - context: Surrounding sentence (improves NLTagger disambiguation).
    static func lemmaCandidates(
        _ word: String,
        language: String = "en",
        in context: String? = nil
    ) -> [String] {
        let pre = preNormalize(word)
        guard !pre.isEmpty else { return [] }

        var ordered: [String] = [pre]
        var seen: Set<String> = [pre]

        let append: (String) -> Void = { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count >= 2, !seen.contains(trimmed) else { return }
            ordered.append(trimmed)
            seen.insert(trimmed)
        }

        switch language.prefix(2).lowercased() {
        case "en":
            appendEnglishCandidates(pre, context: context, append: append)
        case "ko":
            appendKoreanCandidates(pre, append: append)
        default:
            break
        }

        return Array(ordered.prefix(6))
    }

    // Kept for backward compatibility with callers that don't know the source
    // language. Assumes English because that is the only language for which
    // Phase 1 free-tier dictionary is currently seeded.
    static func lemmaCandidates(_ word: String, in context: String? = nil) -> [String] {
        lemmaCandidates(word, language: "en", in: context)
    }

    // MARK: - Pre-normalization (shared across languages)

    /// Trim whitespace, fold smart quotes, strip surrounding punctuation,
    /// NFC-normalize, and lowercase. Internal apostrophes (e.g. in `don't`)
    /// are preserved so contraction lookup works.
    private static func preNormalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fold typographic quotes/apostrophes to ASCII so contraction table
        // keys match verbatim.
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")  // right single
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")  // left single
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"") // left double
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"") // right double
        // Strip leading/trailing punctuation. Internal apostrophes and
        // hyphens are left alone (mother-in-law stays intact).
        let punct = CharacterSet(charactersIn: ".,;:!?\"“”‘’«»()[]{}…—–-")
        s = s.trimmingCharacters(in: punct)
        return s.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - English candidate rules

    private static func appendEnglishCandidates(
        _ word: String,
        context: String?,
        append: (String) -> Void
    ) {
        // 1. Possessive stripping — "cat's" → "cat", "cats'" → "cats" (then
        //    lemma/suffix rules peel further).
        if word.hasSuffix("'s") && word.count > 2 {
            append(String(word.dropLast(2)))
        } else if word.hasSuffix("s'") && word.count > 2 {
            append(String(word.dropLast(1)))
        }

        // 2. Contraction expansion — ship both halves of "don't" etc.
        if let expansions = englishContractions[word] {
            for exp in expansions { append(exp) }
        }

        // 3. Irregular plurals (NLTagger often misses foreign-rooted ones).
        if let singular = englishIrregularPlurals[word] {
            append(singular)
        }

        // 4. Irregular verb past / past-participle.
        if let base = englishIrregularVerbs[word] {
            append(base)
        }

        // 5. NLTagger lemma (best-guess, handles regular + some irregular).
        let lemma = lemmatize(word, in: context)
        if lemma != word {
            append(lemma)
        }

        // 6. Rule-based suffix peeling — catches cases NLTagger returns the
        //    input unchanged. Ordered longest/most-specific first so `ies`
        //    doesn't get clipped by `s`.
        let rules: [(String, String)] = [
            ("ies", "y"),      // babies → baby
            ("ied", "y"),      // tried → try
            ("ying", "ie"),    // lying → lie
            ("ing", "e"),      // writing → write
            ("ing", ""),       // running → run
            ("es", ""),        // boxes → box
            ("ed", "e"),       // liked → like
            ("ed", ""),        // walked → walk
            ("est", ""),       // fastest → fast
            ("er", ""),        // faster → fast
            ("s", ""),         // books → book
        ]
        for (suffix, replacement) in rules {
            guard word.hasSuffix(suffix), word.count > suffix.count + 1 else { continue }
            let stripped = String(word.dropLast(suffix.count)) + replacement
            append(stripped)
        }
    }

    // MARK: - Korean candidate rules

    private static func appendKoreanCandidates(
        _ word: String,
        append: (String) -> Void
    ) {
        // Particle stripping — Korean particles attach directly to the noun
        // without a space. Try the longest match first so 에서는 doesn't get
        // clipped by 는. One strip is enough; the dict / krdict will match
        // the bare noun.
        for particle in koreanParticles {
            guard word.hasSuffix(particle), word.count > particle.count else { continue }
            append(String(word.dropLast(particle.count)))
            break
        }
    }

    // MARK: - English contractions

    /// Map from lowercased contraction to expansion candidates (best-first).
    /// We include both the content word and common variants so any of them
    /// can match the dictionary.
    private static let englishContractions: [String: [String]] = [
        "don't": ["do", "not"],
        "doesn't": ["does", "do", "not"],
        "didn't": ["did", "do", "not"],
        "can't": ["can", "cannot", "not"],
        "cannot": ["can", "not"],
        "couldn't": ["could", "can", "not"],
        "won't": ["will", "not"],
        "wouldn't": ["would", "will", "not"],
        "shouldn't": ["should", "not"],
        "mustn't": ["must", "not"],
        "mightn't": ["might", "not"],
        "isn't": ["is", "be", "not"],
        "aren't": ["are", "be", "not"],
        "wasn't": ["was", "be", "not"],
        "weren't": ["were", "be", "not"],
        "haven't": ["have", "not"],
        "hasn't": ["has", "have", "not"],
        "hadn't": ["had", "have", "not"],
        "i'm": ["am", "be"],
        "i'll": ["will"],
        "i've": ["have"],
        "i'd": ["would", "had"],
        "you're": ["you", "are", "be"],
        "you'll": ["you", "will"],
        "you've": ["you", "have"],
        "you'd": ["you", "would", "had"],
        "he's": ["he", "is", "be", "has"],
        "she's": ["she", "is", "be", "has"],
        "it's": ["it", "is", "be", "has"],
        "we're": ["we", "are", "be"],
        "we'll": ["we", "will"],
        "we've": ["we", "have"],
        "we'd": ["we", "would", "had"],
        "they're": ["they", "are", "be"],
        "they'll": ["they", "will"],
        "they've": ["they", "have"],
        "they'd": ["they", "would", "had"],
        "that's": ["that", "is", "be"],
        "that'll": ["that", "will"],
        "what's": ["what", "is", "be"],
        "what're": ["what", "are"],
        "who's": ["who", "is", "be"],
        "where's": ["where", "is", "be"],
        "when's": ["when", "is", "be"],
        "how's": ["how", "is", "be"],
        "let's": ["let", "us"],
        "here's": ["here", "is", "be"],
        "there's": ["there", "is", "be"],
        "gonna": ["going", "go"],
        "wanna": ["want"],
        "gotta": ["got", "get", "have"],
        "kinda": ["kind"],
        "sorta": ["sort"],
    ]

    // MARK: - English irregular plurals

    /// Map from plural → singular for forms NLTagger may miss, especially
    /// Latin/Greek academic vocabulary (common in textbooks).
    private static let englishIrregularPlurals: [String: String] = [
        "children": "child",
        "men": "man",
        "women": "woman",
        "people": "person",
        "feet": "foot",
        "teeth": "tooth",
        "mice": "mouse",
        "geese": "goose",
        "oxen": "ox",
        "lice": "louse",
        "dice": "die",
        // Latin/Greek -> singular
        "analyses": "analysis",
        "axes": "axis",
        "bases": "basis",
        "crises": "crisis",
        "diagnoses": "diagnosis",
        "ellipses": "ellipsis",
        "hypotheses": "hypothesis",
        "oases": "oasis",
        "parentheses": "parenthesis",
        "syntheses": "synthesis",
        "theses": "thesis",
        "bacteria": "bacterium",
        "curricula": "curriculum",
        "data": "datum",
        "media": "medium",
        "memoranda": "memorandum",
        "millennia": "millennium",
        "phenomena": "phenomenon",
        "criteria": "criterion",
        "cacti": "cactus",
        "fungi": "fungus",
        "nuclei": "nucleus",
        "radii": "radius",
        "stimuli": "stimulus",
        "syllabi": "syllabus",
        "alumni": "alumnus",
        "emeriti": "emeritus",
        "formulae": "formula",
        "antennae": "antenna",
        "larvae": "larva",
        "vertebrae": "vertebra",
        "appendices": "appendix",
        "indices": "index",
        "matrices": "matrix",
        "vertices": "vertex",
        "vortices": "vortex",
        "apices": "apex",
        "codices": "codex",
    ]

    // MARK: - English irregular verbs

    /// Map from inflected form → infinitive. Covers forms NLTagger sometimes
    /// returns unchanged on iOS 17+ simulator and edge cases in academic
    /// English. Present-tense inflections (am/is/are/has/does) also included
    /// so the dict's `be` / `have` / `do` entries match on any form.
    private static let englishIrregularVerbs: [String: String] = [
        // be
        "am": "be", "is": "be", "are": "be", "was": "be", "were": "be", "been": "be",
        // have / do
        "has": "have", "had": "have",
        "does": "do", "did": "do", "done": "do",
        // Common strong verbs (past / past-participle)
        "ran": "run",
        "went": "go", "gone": "go",
        "ate": "eat", "eaten": "eat",
        "took": "take", "taken": "take",
        "gave": "give", "given": "give",
        "saw": "see", "seen": "see",
        "knew": "know", "known": "know",
        "grew": "grow", "grown": "grow",
        "flew": "fly", "flown": "fly",
        "drew": "draw", "drawn": "draw",
        "threw": "throw", "thrown": "throw",
        "blew": "blow", "blown": "blow",
        "broke": "break", "broken": "break",
        "chose": "choose", "chosen": "choose",
        "froze": "freeze", "frozen": "freeze",
        "stole": "steal", "stolen": "steal",
        "spoke": "speak", "spoken": "speak",
        "woke": "wake", "woken": "wake",
        "wore": "wear", "worn": "wear",
        "tore": "tear", "torn": "tear",
        "drove": "drive", "driven": "drive",
        "rode": "ride", "ridden": "ride",
        "wrote": "write", "written": "write",
        "rose": "rise", "risen": "rise",
        "fell": "fall", "fallen": "fall",
        "came": "come",
        "became": "become", "become": "become",
        "swam": "swim", "swum": "swim",
        "sang": "sing", "sung": "sing",
        "rang": "ring", "rung": "ring",
        "drank": "drink", "drunk": "drink",
        "sank": "sink", "sunk": "sink",
        "began": "begin", "begun": "begin",
        // -ought / -aught
        "bought": "buy",
        "brought": "bring",
        "thought": "think",
        "taught": "teach",
        "caught": "catch",
        "fought": "fight",
        "sought": "seek",
        // -t endings
        "left": "leave",
        "lost": "lose",
        "meant": "mean",
        "kept": "keep",
        "slept": "sleep",
        "felt": "feel",
        "told": "tell",
        "sold": "sell",
        "held": "hold",
        "built": "build",
        "bent": "bend",
        "sent": "send",
        "spent": "spend",
        "lent": "lend",
        "dealt": "deal",
        "dreamt": "dream",
        "leapt": "leap",
        "burnt": "burn",
        "learnt": "learn",
        "spelt": "spell",
        // Same-form past
        "hit": "hit", "cut": "cut", "put": "put", "set": "set", "let": "let",
        "shut": "shut", "split": "split", "spread": "spread", "burst": "burst",
        "cost": "cost", "quit": "quit", "bet": "bet", "bid": "bid",
        // Others
        "got": "get", "gotten": "get",
        "hid": "hide", "hidden": "hide",
        "hung": "hang",
        "dug": "dig",
        "lit": "light",
        "shone": "shine",
        "struck": "strike",
        "stuck": "stick",
        "said": "say",
        "made": "make",
        "paid": "pay",
        "laid": "lay",
        "sat": "sit",
        "stood": "stand",
        "met": "meet",
        "read": "read",
        "led": "lead",
        "fed": "feed",
        "bred": "breed",
        "fled": "flee",
        "sped": "speed",
        "bound": "bind",
        "found": "find",
        "ground": "grind",
        "wound": "wind",
        "shook": "shake", "shaken": "shake",
    ]

    // MARK: - Korean particles

    /// Korean particles (조사) that attach to the end of nouns. Listed longest
    /// first so 에서는 is matched before 는, 으로부터 before 부터, etc.
    /// Note: single-jamo particles (은/는/이/가/을/를/의) only strip when the
    /// remaining stem is ≥ 1 syllable — this is handled by the caller's
    /// `count > particle.count` guard.
    private static let koreanParticles: [String] = [
        "으로부터", "에서부터", "에게서", "으로서",
        "에서는", "에서도", "에게는", "에게도", "으로는", "으로도",
        "에서", "에게", "으로", "로부터", "부터", "까지", "처럼", "같이",
        "보다", "마저", "조차", "만큼", "로서", "로써",
        "이나", "이든", "이야", "이라", "이랑",
        "은", "는", "이", "가", "을", "를", "의",
        "에", "와", "과", "도", "만", "로", "랑",
        "께", "야", "아", "여",
    ]
}
