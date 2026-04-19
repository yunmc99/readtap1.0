import Foundation
import CryptoKit

/// Shared cache key normalization utilities used by TranslationLookupCache and MeaningCandidateCacheStore.
enum CacheNormalizer {

    /// SHA-256 hex digest of the given string.
    static func sha256Hex(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Normalizes a word/text string for use as a cache key.
    /// Strips zero-width/soft characters, curly quotes, dashes → ASCII equivalents,
    /// collapses whitespace, and lowercases.
    static func normalizeCacheText(_ text: String) -> String {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "")   // zero-width space
            .replacingOccurrences(of: "\u{00AD}", with: "")   // soft hyphen
            .replacingOccurrences(of: "\u{00A0}", with: " ")  // non-breaking space → space
            .replacingOccurrences(of: "\u{2019}", with: "'")  // right single quotation → apostrophe
            .replacingOccurrences(of: "\u{2018}", with: "'")  // left single quotation → apostrophe
            .replacingOccurrences(of: "\u{201C}", with: "\"") // left double quotation
            .replacingOccurrences(of: "\u{201D}", with: "\"") // right double quotation
        normalized = normalized
            .replacingOccurrences(of: "\u{2013}", with: "-")  // en-dash → hyphen
            .replacingOccurrences(of: "\u{2014}", with: "-")  // em-dash → hyphen
        return normalized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// Normalizes a context string for cache key generation.
    /// Takes the first `wordLimit` whitespace-separated tokens and lowercases them.
    static func normalizeCacheContext(_ context: String?, wordLimit: Int = 20) -> String {
        guard let raw = context?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else { return "" }
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{00AD}", with: "")
        return cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(wordLimit)
            .map { $0.lowercased() }
            .joined(separator: " ")
    }

    /// Normalizes a BCP-47 language code to its base language tag (e.g. "en-US" → "en").
    static func normalizeLangCode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.split(separator: "-").first.map(String.init) ?? trimmed
    }
}
