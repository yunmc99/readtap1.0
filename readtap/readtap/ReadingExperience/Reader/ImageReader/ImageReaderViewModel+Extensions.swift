import Foundation

extension ImageReaderViewModel {
  static func boundedLookupText(_ text: String, maxWordCount: Int) -> (
    text: String, wasLimited: Bool
  ) {
    let tokens =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    let boundedByWords: String
    if tokens.count <= maxWordCount {
      boundedByWords = tokens.joined(separator: " ")
    } else {
      boundedByWords = tokens.prefix(maxWordCount).joined(separator: " ")
    }
    let trimmed = boundedByWords.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > ImageLookupLimits.maxLookupContextCharacterCount else {
      return (trimmed, tokens.count > maxWordCount)
    }
    let truncated = String(trimmed.prefix(ImageLookupLimits.maxLookupContextCharacterCount))
    return (truncated.trimmingCharacters(in: .whitespacesAndNewlines), true)
  }

  static func boundedContextText(
    _ text: String, maxWordCount: Int, maxCharacterCount: Int
  ) -> String {
    let tokens =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    let boundedByWords: String
    if tokens.count <= maxWordCount {
      boundedByWords = tokens.joined(separator: " ")
    } else {
      boundedByWords = tokens.prefix(maxWordCount).joined(separator: " ")
    }
    let trimmed = boundedByWords.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= maxCharacterCount else {
      return String(trimmed.prefix(maxCharacterCount)).trimmingCharacters(
        in: .whitespacesAndNewlines)
    }
    return trimmed
  }
}
