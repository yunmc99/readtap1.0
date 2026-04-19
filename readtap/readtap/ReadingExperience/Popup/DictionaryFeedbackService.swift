import CommonCrypto
import CryptoKit
import Foundation

struct DictionaryFeedbackPayload: Encodable {
    let word: String
    let fromLang: String
    let toLang: String
    let currentMeaning: String
    let userSuggestion: String?
    let sentenceHash: String?
}

/// Fire-and-forget client for `/dictionary-feedback`. Free tier only.
final class DictionaryFeedbackService {
    static let shared = DictionaryFeedbackService()
    private init() {}

    private static let path = "/dictionary-feedback"
    private static let timeout: TimeInterval = 5

    /// Compute a stable SHA256 hex string for the given sentence so the server
    /// can cluster reports without storing user text.
    static func hashSentence(_ sentence: String?) -> String? {
        guard let s = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Submit a report. Never surfaces errors to the caller.
    func submit(
        word: String,
        from: String,
        to: String,
        currentMeaning: String,
        userSuggestion: String?,
        sentence: String?
    ) async {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return }

        let payload = DictionaryFeedbackPayload(
            word: trimmedWord,
            fromLang: from.lowercased(),
            toLang: to.lowercased(),
            currentMeaning: currentMeaning,
            userSuggestion: userSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyFeedback,
            sentenceHash: Self.hashSentence(sentence)
        )
        guard let body = try? JSONEncoder().encode(payload) else { return }
        guard let url = URL(string: resolvedBaseURL() + Self.path) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("readtap-client/ios", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        attachAuth(&request, payload: body)

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Auth (identical to DictionaryLookupService)

    private func resolvedBaseURL() -> String {
        if let url = UserDefaults.standard.string(forKey: "contextServerURL"), !url.isEmpty {
            return ensureScheme(url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let url = Bundle.main.object(forInfoDictionaryKey: "ContextServerBaseURL") as? String, !url.isEmpty {
            return ensureScheme(url)
        }
        return "https://readtap-translation-worker.ymcyun99.workers.dev"
    }

    private func ensureScheme(_ url: String) -> String {
        (url.hasPrefix("https://") || url.hasPrefix("http://")) ? url : "https://\(url)"
    }

    private func attachAuth(_ request: inout URLRequest, payload: Data) {
        if let token = ContextServerTokenStore.currentToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let clientId = UserDefaults.standard.string(forKey: "contextServerClientId"), !clientId.isEmpty {
            request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
        } else if let clientId = Bundle.main.object(forInfoDictionaryKey: "ContextServerClientId") as? String {
            request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
        }
        let requestId = UUID().uuidString
        let timestamp = String(Int(Date().timeIntervalSince1970))
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")

        if let signingSecret = ContextServerSigningSecretStore.currentSecret(), !signingSecret.isEmpty {
            let bodyBase64 = payload.base64EncodedString()
            let message = "POST\n\(Self.path)\n\(timestamp)\n\(requestId)\n\(bodyBase64)"
            var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let keyData = Data(signingSecret.utf8)
            let messageData = Data(message.utf8)
            keyData.withUnsafeBytes { keyBytes in
                messageData.withUnsafeBytes { messageBytes in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                           keyBytes.baseAddress, keyData.count,
                           messageBytes.baseAddress, messageData.count,
                           &hmac)
                }
            }
            let signature = Data(hmac).base64EncodedString()
            request.setValue("HMAC-SHA256 \(signature)", forHTTPHeaderField: "X-ReadTap-Signature")
        }
    }
}

private extension String {
    var nilIfEmptyFeedback: String? { isEmpty ? nil : self }
}
