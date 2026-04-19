import CommonCrypto
import Foundation

// MARK: - Request / Response

struct DictionaryLookupRequest: Encodable {
    /// Server accepts either a single string or an array of candidates.
    /// We always send an array so the server can try inflection variants
    /// (e.g. ["contacting", "contact"]) in a single round-trip.
    let word: [String]
    let from: String
    let to: String
}

struct DictionaryLookupResponse: Decodable {
    let hit: Bool
    let word: String?
    var meanings: [String]?
    let source: String?
    let reason: String?
}

// MARK: - Service

/// Client for the `/dictionary` endpoint.
///
/// Free-tier primary lookup path; also used as a fallback by
/// `PremiumLookupService` consumers when the premium LLM call fails.
final class DictionaryLookupService {
    static let shared = DictionaryLookupService()
    private init() {}

    private static let path = "/dictionary"
    private static let timeout: TimeInterval = 6

    func fetch(
        word: String,
        from: String,
        to: String,
        context: String? = nil
    ) async -> DictionaryLookupResponse? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            #if DEBUG
            print("[DictLookup] SKIP empty word")
            #endif
            return nil
        }

        // Generate inflection + particle candidates. Server tries each in
        // order and returns the first D1 hit, so "contacting" → ["contacting",
        // "contact", ...] or Korean "책을" → ["책을", "책"] resolves in one
        // round-trip. Candidate rules are language-specific.
        let candidates = LookupNormalizer.lemmaCandidates(trimmed, language: from, in: context)
        guard !candidates.isEmpty else {
            #if DEBUG
            print("[DictLookup] SKIP empty candidates word=\(trimmed)")
            #endif
            return nil
        }

        #if DEBUG
        print("[DictLookup] REQUEST word=\(trimmed) from=\(from) to=\(to) candidates=\(candidates)")
        #endif

        guard let url = URL(string: resolvedBaseURL() + Self.path) else {
            #if DEBUG
            print("[DictLookup] SKIP invalid URL baseURL=\(resolvedBaseURL())")
            #endif
            return nil
        }

        let payload = DictionaryLookupRequest(word: candidates, from: from, to: to)
        guard let body = try? JSONEncoder().encode(payload) else {
            #if DEBUG
            print("[DictLookup] SKIP json encode failed")
            #endif
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("readtap-client/ios", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        attachAuth(&request, payload: body)

        #if DEBUG
        let hasBearer = request.value(forHTTPHeaderField: "Authorization") != nil
        let hasClient = request.value(forHTTPHeaderField: "X-ReadTap-Client-Id") != nil
        let hasSig = request.value(forHTTPHeaderField: "X-ReadTap-Signature") != nil
        print("[DictLookup] AUTH bearer=\(hasBearer) client=\(hasClient) sig=\(hasSig) url=\(url.absoluteString)")
        #endif

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                #if DEBUG
                print("[DictLookup] FAIL non-HTTP response")
                #endif
                return nil
            }
            #if DEBUG
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>"
            print("[DictLookup] RESPONSE status=\(http.statusCode) body=\(bodyPreview)")
            #endif
            guard http.statusCode == 200 else { return nil }
            guard var decoded = try? JSONDecoder().decode(DictionaryLookupResponse.self, from: data) else {
                #if DEBUG
                print("[DictLookup] FAIL decode")
                #endif
                return nil
            }
            // Strip CJK-ideograph parentheticals (e.g. "접촉(接觸)" → "접촉") that
            // came through the Wiktionary seed. Hanja are never useful to the
            // user in this UI; filter empty meanings that result from stripping.
            if let raw = decoded.meanings {
                let cleaned = raw
                    .map(Self.stripHanjaParenthetical)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                decoded.meanings = cleaned
            }
            #if DEBUG
            print("[DictLookup] DECODED hit=\(decoded.hit) word=\(decoded.word ?? "-") meanings=\(decoded.meanings ?? []) reason=\(decoded.reason ?? "-")")
            #endif
            return decoded
        } catch {
            #if DEBUG
            let ns = error as NSError
            print("[DictLookup] NETWORK ERROR domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            #endif
            return nil
        }
    }

    // Match any parenthetical that contains at least one Han ideograph.
    // Inner content is allowed to also include slashes (알터 Hanja writings
    // 序論/緖論), Hangul suffixes glued to Hanja (斷食하다), or whitespace —
    // all are etymology noise for Korean readers.
    private static let hanjaParentheticalRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\s*\\([^)]*\\p{Script=Han}[^)]*\\)",
        options: []
    )

    static func stripHanjaParenthetical(_ input: String) -> String {
        guard let regex = hanjaParentheticalRegex else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    // MARK: - Auth (mirrors PremiumLookupService)

    private func attachAuth(_ request: inout URLRequest, payload: Data) {
        if let token = resolvedToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let clientId = resolvedClientId(), !clientId.isEmpty {
            request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
        }
        let requestId = UUID().uuidString
        let timestamp = String(Int(Date().timeIntervalSince1970))
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")

        if let signingSecret = resolvedSigningSecret(), !signingSecret.isEmpty {
            let bodyBase64 = payload.base64EncodedString()
            let message = "POST\n\(Self.path)\n\(timestamp)\n\(requestId)\n\(bodyBase64)"
            if let signature = hmacSHA256(message: message, secret: signingSecret) {
                request.setValue("HMAC-SHA256 \(signature)", forHTTPHeaderField: "X-ReadTap-Signature")
            }
        }
    }

    private func resolvedBaseURL() -> String {
        if let url = UserDefaults.standard.string(forKey: "contextServerURL"), !url.isEmpty {
            return ensureScheme(url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let url = Bundle.main.object(forInfoDictionaryKey: "ContextServerBaseURL") as? String,
           !url.isEmpty {
            return ensureScheme(url)
        }
        return "https://readtap-translation-worker.ymcyun99.workers.dev"
    }

    private func ensureScheme(_ url: String) -> String {
        (url.hasPrefix("https://") || url.hasPrefix("http://")) ? url : "https://\(url)"
    }

    private func resolvedClientId() -> String? {
        if let id = UserDefaults.standard.string(forKey: "contextServerClientId"), !id.isEmpty {
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let id = Bundle.main.object(forInfoDictionaryKey: "ContextServerClientId") as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func resolvedToken() -> String? {
        if let t = ContextServerTokenStore.currentToken(), !t.isEmpty { return t }
        if let t = Bundle.main.object(forInfoDictionaryKey: "ContextServerToken") as? String, !t.isEmpty {
            return t
        }
        return nil
    }

    private func resolvedSigningSecret() -> String? {
        if let s = ContextServerSigningSecretStore.currentSecret(), !s.isEmpty { return s }
        if let s = Bundle.main.object(forInfoDictionaryKey: "ContextServerSigningSecret") as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    private func hmacSHA256(message: String, secret: String) -> String? {
        guard let keyData = secret.data(using: .utf8),
              let messageData = message.data(using: .utf8) else { return nil }
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            messageData.withUnsafeBytes { messageBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyBytes.baseAddress, keyData.count,
                       messageBytes.baseAddress, messageData.count,
                       &hmac)
            }
        }
        return Data(hmac).base64EncodedString()
    }
}
