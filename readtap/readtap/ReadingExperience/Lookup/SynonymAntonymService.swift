//
//  SynonymAntonymService.swift
//  readtap
//
//  Lazy-loaded synonym & antonym lookup via /synonym-antonym endpoint.
//  Only called when the user explicitly swipes to the synonym/antonym page.
//

import CommonCrypto
import Foundation
import Supabase

// MARK: - Request / Response

struct SynonymAntonymRequest: Encodable {
    let word: String
    let sentence: String
    let sourceLang: String
    let targetLang: String
}

struct SynonymAntonymResponse: Decodable {
    let synonyms: [String]
    let antonyms: [String]
    let cached: Bool?
}

// MARK: - Service

final class SynonymAntonymService {
    static let shared = SynonymAntonymService()
    private init() {}

    private static let endpointPath = "/synonym-antonym"
    private static let requestTimeout: TimeInterval = 8

    /// In-memory cache keyed by "word|sourceLang|targetLang".
    /// Prevents duplicate network calls for the same word within a session.
    private var memoryCache: [String: SynonymAntonymResponse] = [:]
    private let cacheLock = NSLock()
    private static let maxCacheSize = 64

    func fetch(
        word: String,
        sentence: String,
        sourceLang: String,
        targetLang: String
    ) async -> SynonymAntonymResponse? {
        guard SubscriptionManager.shared.isEffectivelyPremium else { return nil }
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return nil }

        // Check memory cache first
        let cacheKey = "\(trimmedWord.lowercased())|\(sourceLang.lowercased())|\(targetLang.lowercased())"
        cacheLock.lock()
        if let cached = memoryCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let baseURL = resolvedBaseURL()
        guard let url = URL(string: baseURL + Self.endpointPath) else {
            return nil
        }

        let payload = SynonymAntonymRequest(
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

        // Auth: Client ID
        if let clientId = resolvedClientId(), !clientId.isEmpty {
            request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
        }

        // Auth: Supabase user token
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
            let message = "POST\n\(Self.endpointPath)\n\(timestamp)\n\(requestId)\n\(bodyBase64)"
            if let signature = hmacSHA256(message: message, secret: signingSecret) {
                request.setValue("HMAC-SHA256 \(signature)", forHTTPHeaderField: "X-ReadTap-Signature")
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                #if DEBUG
                if let http = response as? HTTPURLResponse {
                    print("[SynonymAntonym] HTTP error: \(http.statusCode)")
                }
                #endif
                return nil
            }
            guard let result = try? JSONDecoder().decode(SynonymAntonymResponse.self, from: data) else {
                #if DEBUG
                print("[SynonymAntonym] decode failed")
                #endif
                return nil
            }
            #if DEBUG
            print("[SynonymAntonym] OK: synonyms=\(result.synonyms.count) antonyms=\(result.antonyms.count)")
            #endif

            // Store in memory cache
            cacheLock.lock()
            if memoryCache.count >= Self.maxCacheSize {
                // Evict oldest entries (simple strategy: clear half)
                let keys = Array(memoryCache.keys)
                for key in keys.prefix(Self.maxCacheSize / 2) {
                    memoryCache.removeValue(forKey: key)
                }
            }
            memoryCache[cacheKey] = result
            cacheLock.unlock()

            return result
        } catch {
            #if DEBUG
            let nsError = error as NSError
            print("[SynonymAntonym] Network error: code=\(nsError.code) domain=\(nsError.domain)")
            #endif
            return nil
        }
    }

    // MARK: - Config resolution (mirrors PremiumLookupService)

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
}
