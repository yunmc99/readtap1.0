import Foundation

struct WordnikDefinition: Decodable {
  let text: String
  let partOfSpeech: String?
}

private struct WordnikDictionaryResponse: Decodable {
  let text: String
  let partOfSpeech: String?
}

final class WordnikDictionaryService {
  static let shared = WordnikDictionaryService()

  private let endpointBase = "https://api.wordnik.com/v4/word.json"
  private let requestTimeout: TimeInterval = 8
  private let session: URLSession
  
  init(session: URLSession = .shared) {
    self.session = session
  }

  func lookupDefinitions(word: String, maxCandidates: Int = 3) async -> [WordnikDefinition] {
    let normalizedWord = word
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if normalizedWord.isEmpty { return [] }

    guard let apiKey = resolveApiKey(), apiKey.isEmpty == false else {
      debugLog("[wordnik] api key missing")
      return []
    }

    let encodedWord = normalizedWord.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedWord
    let limit = max(1, min(3, maxCandidates))
    guard var components = URLComponents(string: "\(endpointBase)/\(encodedWord)/definitions") else {
      debugLog("[wordnik] invalid URL for word=\(normalizedWord)")
      return []
    }

    components.queryItems = [
      URLQueryItem(name: "api_key", value: apiKey),
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "includeRelated", value: "false"),
      URLQueryItem(name: "sourceDictionaries", value: "all"),
      URLQueryItem(name: "useCanonical", value: "true"),
      URLQueryItem(name: "includeTags", value: "false")
    ]

    guard let url = components.url else {
      debugLog("[wordnik] url missing components word=\(normalizedWord)")
      return []
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = requestTimeout

    let start = Date()
    do {
      let (data, response) = try await session.data(for: request)
      let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
      guard let http = response as? HTTPURLResponse else {
        debugLog("[wordnik] non-http response word=\(normalizedWord) latencyMs=\(latencyMs)")
        return []
      }

      guard (200...299).contains(http.statusCode) else {
        let message = String(data: data, encoding: .utf8) ?? "-"
        debugLog(
          "[wordnik] error status=\(http.statusCode) word=\(normalizedWord) message=\(message.prefix(140))"
        )
        return []
      }

      let raw = try JSONDecoder().decode([WordnikDictionaryResponse].self, from: data)
      let trimmed = raw.compactMap { (response: WordnikDictionaryResponse) -> WordnikDefinition? in
        let text = response.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return WordnikDefinition(text: text, partOfSpeech: response.partOfSpeech)
      }
      var unique: [WordnikDefinition] = []
      var seen: Set<String> = []
      for definition in trimmed {
        let key = definition.text
          .lowercased()
          .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
          .replacingOccurrences(of: " ", with: "")
        if key.isEmpty || seen.contains(key) { continue }
        seen.insert(key)
        unique.append(definition)
        if unique.count >= limit { break }
      }
      debugLog(
        "[wordnik] ok word=\(normalizedWord) candidates=\(unique.count) latencyMs=\(latencyMs)"
      )
      return unique
    } catch {
      let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
      debugLog("[wordnik] request failed word=\(normalizedWord) latencyMs=\(latencyMs) error=\(error)")
      return []
    }
  }

  func hasUsableApiKey() -> Bool {
    if let candidate = resolveApiKey() {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty == false
    }
    return false
  }

  private func resolveApiKey() -> String? {
    #if DEBUG
    if let fromInfo = Bundle.main.object(forInfoDictionaryKey: "WordnikApiKey") as? String {
      let trimmed = fromInfo.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      if trimmed.isEmpty == false { return trimmed }
    }

    let candidates = [
      "WORDNIK_API_KEY",
      "WORDNIK_PROD_API_KEY",
      "WORDNIK_STAGING_API_KEY",
      "WORDNIK_API_KEY_PROD",
      "WORDNIK_API_KEY_STAGING"
    ]
    for key in candidates {
      if let value = ProcessInfo.processInfo.environment[key] {
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if trimmed.isEmpty == false {
          return trimmed
        }
      }
    }
    #endif
    return nil
  }

  private func debugLog(_ message: String) {
    #if DEBUG
    print("[Wordnik] \(message)")
    #endif
  }
}
