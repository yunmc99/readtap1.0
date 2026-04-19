import CommonCrypto
import Foundation
import Supabase

// MARK: - Request / Response

struct PremiumLookupRequest: Encodable {
  let word: String
  let sentence: String
  let sourceLang: String
  let targetLang: String
}

struct PremiumLookupResponse: Decodable {
  struct PosEntry: Decodable {
    let pos: String
    let meanings: [String]
  }

  /// "word" for dictionary-style POS results, "phrase" for translation+explanation.
  let mode: String
  let byPos: [PosEntry]?
  let translation: String?
  let explanation: String?
  let sentenceTranslation: String?

  var isPhrase: Bool { mode == "phrase" }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Backward compat: old cached responses may lack "mode"
    let rawMode = try container.decodeIfPresent(String.self, forKey: .mode)
    self.byPos = try container.decodeIfPresent([PosEntry].self, forKey: .byPos)
    self.translation = try container.decodeIfPresent(String.self, forKey: .translation)
    self.explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
    self.sentenceTranslation = try container.decodeIfPresent(String.self, forKey: .sentenceTranslation)

    if let rawMode {
      self.mode = rawMode
    } else if self.translation != nil {
      self.mode = "phrase"
    } else {
      self.mode = "word"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case mode, byPos, translation, explanation, sentenceTranslation
  }
}

extension PremiumLookupResponse {
  init(
    mode: String,
    byPos: [PosEntry]?,
    translation: String?,
    explanation: String?,
    sentenceTranslation: String?
  ) {
    self.mode = mode
    self.byPos = byPos
    self.translation = translation
    self.explanation = explanation
    self.sentenceTranslation = sentenceTranslation
  }
}

// MARK: - Service

/// Calls the `/premium-lookup` endpoint on the Cloudflare Worker.
/// The Worker uses an adaptive prompt that returns either dictionary or phrase results.
///
/// Word mode response:
/// `{ "mode": "word", "byPos": [{ "pos": "명사", "meanings": ["계약서", "약정"] }] }`
///
/// Phrase mode response:
/// `{ "mode": "phrase", "translation": "...", "explanation": "..." }`
final class PremiumLookupService {
  static let shared = PremiumLookupService()
  private init() {}

  private static let premiumLookupPath = "/premium-lookup"
  private static let requestTimeout: TimeInterval = 10

  func fetch(
    word: String,
    sentence: String,
    sourceLang: String,
    targetLang: String
  ) async -> PremiumLookupResponse? {
    guard SubscriptionManager.shared.isEffectivelyPremium else { return nil }
    let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedWord.isEmpty else {
      #if DEBUG
      print("[PremiumLookup] SKIP: empty word")
      #endif
      return nil
    }

    if let llm = await fetchFromWorker(
      trimmedWord: trimmedWord,
      sentence: sentence,
      sourceLang: sourceLang,
      targetLang: targetLang
    ) {
      return llm
    }
    // Offline / LLM failure fallback (spec: 2026-04-17 §4). Phase 1 dictionary
    // is en-ko only; other pairs will still return nil and the popup keeps its
    // loading/empty state as before.
    return await dictionaryFallback(
      word: trimmedWord,
      sentence: sentence,
      sourceLang: sourceLang,
      targetLang: targetLang
    )
  }

  private func fetchFromWorker(
    trimmedWord: String,
    sentence: String,
    sourceLang: String,
    targetLang: String
  ) async -> PremiumLookupResponse? {
    let baseURL = resolvedBaseURL()
    guard let url = URL(string: baseURL + Self.premiumLookupPath) else {
      return nil
    }

    let payload = PremiumLookupRequest(
      word: trimmedWord,
      sentence: sentence.trimmingCharacters(in: .whitespacesAndNewlines),
      sourceLang: sourceLang,
      targetLang: targetLang
    )
    guard let payloadData = try? JSONEncoder().encode(payload) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("readtap-client/ios", forHTTPHeaderField: "User-Agent")
    request.httpBody = payloadData

    // Auth: Bearer token
    if let token = resolvedToken(), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // Auth: Client ID (required by worker's allowedClientIds allowlist)
    if let clientId = resolvedClientId(), !clientId.isEmpty {
      request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
    }

    // Auth: Supabase user token for server-side subscription verification
    if let session = try? await SupabaseConfig.client.auth.session {
      request.setValue(session.accessToken, forHTTPHeaderField: "X-User-Token")
    }

    // Auth: Request signing (HMAC-SHA256)
    let requestId = UUID().uuidString
    let timestamp = String(Int(Date().timeIntervalSince1970))
    request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
    request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")

    if let signingSecret = resolvedSigningSecret(), !signingSecret.isEmpty {
      let bodyBase64 = payloadData.base64EncodedString()
      let message = "POST\n\(Self.premiumLookupPath)\n\(timestamp)\n\(requestId)\n\(bodyBase64)"
      if let signature = hmacSHA256(message: message, secret: signingSecret) {
        request.setValue("HMAC-SHA256 \(signature)", forHTTPHeaderField: "X-ReadTap-Signature")
      }
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        #if DEBUG
        if let http = response as? HTTPURLResponse {
          print("[PremiumLookup] HTTP error: \(http.statusCode)")
        }
        #endif
        return nil
      }
      return try? JSONDecoder().decode(PremiumLookupResponse.self, from: data)
    } catch {
      #if DEBUG
      let nsError = error as NSError
      print("[PremiumLookup] Network error: code=\(nsError.code) domain=\(nsError.domain)")
      #endif
      return nil
    }
  }

  private func dictionaryFallback(
    word: String,
    sentence: String,
    sourceLang: String,
    targetLang: String
  ) async -> PremiumLookupResponse? {
    let srcNorm = sourceLang.lowercased().split(separator: "-").first.map(String.init) ?? ""
    let tgtNorm = targetLang.lowercased().split(separator: "-").first.map(String.init) ?? ""
    guard srcNorm == "en", tgtNorm == "ko" else { return nil }

    // DictionaryLookupService builds inflection candidates internally.
    guard let dict = await DictionaryLookupService.shared.fetch(
      word: word, from: srcNorm, to: tgtNorm, context: sentence
    ), dict.hit, let meanings = dict.meanings, !meanings.isEmpty else {
      return nil
    }
    #if DEBUG
    let matched = dict.word ?? word
    print("[PremiumLookup] LLM failed → dictionary fallback hit word=\(word) matched=\(matched) count=\(meanings.count)")
    #endif
    return PremiumLookupResponse(
      mode: "word",
      byPos: [.init(pos: "", meanings: meanings)],
      translation: nil,
      explanation: nil,
      sentenceTranslation: nil
    )
  }

  // MARK: - Config resolution (mirrors ContextMeaningService)

  private func resolvedBaseURL() -> String {
    if let url = UserDefaults.standard.string(forKey: "contextServerURL"), !url.isEmpty {
      return ensureScheme(url.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #if DEBUG
    for key in ["CONTEXT_SERVER_BASE_URL", "CONTEXT_SERVER_PROD_BASE_URL"] {
      if let url = ProcessInfo.processInfo.environment[key], !url.isEmpty {
        return ensureScheme(url)
      }
    }
    #endif
    if let url = Bundle.main.object(forInfoDictionaryKey: "ContextServerBaseURL") as? String,
      !url.isEmpty
    {
      return ensureScheme(url)
    }
    return "https://readtap-translation-worker.ymcyun99.workers.dev"
  }

  private func ensureScheme(_ url: String) -> String {
    if url.hasPrefix("https://") || url.hasPrefix("http://") { return url }
    return "https://\(url)"
  }

  private func resolvedClientId() -> String? {
    if let id = UserDefaults.standard.string(forKey: "contextServerClientId"), !id.isEmpty {
      return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #if DEBUG
    for key in ["CONTEXT_SERVER_CLIENT_ID", "READTAP_CLIENT_ID"] {
      if let id = ProcessInfo.processInfo.environment[key], !id.isEmpty { return id }
    }
    #endif
    if let id = Bundle.main.object(forInfoDictionaryKey: "ContextServerClientId") as? String,
      !id.isEmpty
    {
      return id
    }
    return nil
  }

  private func resolvedSigningSecret() -> String? {
    if let s = ContextServerSigningSecretStore.currentSecret(), !s.isEmpty { return s }
    #if DEBUG
    for key in ["CONTEXT_SERVER_SIGNING_SECRET", "REQUEST_SIGNING_SECRET"] {
      if let s = ProcessInfo.processInfo.environment[key], !s.isEmpty { return s }
    }
    #endif
    if let s = Bundle.main.object(forInfoDictionaryKey: "ContextServerSigningSecret") as? String,
      !s.isEmpty
    {
      return s
    }
    return nil
  }

  private func hmacSHA256(message: String, secret: String) -> String? {
    guard let keyData = secret.data(using: .utf8),
          let messageData = message.data(using: .utf8)
    else { return nil }
    var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    keyData.withUnsafeBytes { keyBytes in
      messageData.withUnsafeBytes { messageBytes in
        CCHmac(
          CCHmacAlgorithm(kCCHmacAlgSHA256),
          keyBytes.baseAddress, keyData.count,
          messageBytes.baseAddress, messageData.count,
          &hmac
        )
      }
    }
    return Data(hmac).base64EncodedString()
  }

  private func resolvedToken() -> String? {
    #if DEBUG
    for key in ["CONTEXT_SERVER_TOKEN", "READTAP_SERVER_TOKEN"] {
      if let t = ProcessInfo.processInfo.environment[key], !t.isEmpty { return t }
    }
    #endif
    if let t = ContextServerTokenStore.currentToken(), !t.isEmpty { return t }
    if let t = Bundle.main.object(forInfoDictionaryKey: "ContextServerToken") as? String,
      !t.isEmpty
    {
      return t
    }
    return nil
  }
}
