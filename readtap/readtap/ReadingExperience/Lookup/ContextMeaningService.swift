import Foundation
import Security
import CryptoKit

struct ContextMeaningCandidate: Decodable, Equatable {
    let word: String
    let meaningKo: String
    let synonymsEn: [String]?
}

struct ContextMeaningResponse: Decodable, Equatable {
    let selected: ContextMeaningCandidate?
    let candidates: [ContextMeaningCandidate]?
    let correctedSentence: String?
    let sentenceTranslationKo: String?

    func resolvedCandidates() -> [ContextMeaningCandidate] {
        if let candidates, candidates.isEmpty == false { return candidates }
        if let selected { return [selected] }
        return []
    }
}

struct ContextMeaningRequest: Decodable, Encodable, Equatable {
    let word: String
    let sentence: String
    let source: String
    let target: String
    let candidates: [String]
    let maxCandidates: Int
    let provider: String?
    let apiKey: String?
}

struct ContextTranslateRequest: Encodable {
    let text: String
    let source: String
    let target: String
    let context: String?
    let candidates: [String]
    let maxCandidates: Int
    let task: String
    let provider: String?
    let apiKey: String?
}

struct ContextKoreanDictionaryRequest: Encodable {
    let word: String
}

private struct ContextKoreanDictionaryResponse: Decodable {
    let entries: [KoreanDictionaryEntry]?
}

private struct ServerTranslationResponse: Decodable {
    let translatedText: String?
    let translation: String?
    let result: String?
    let output: String?
    let text: String?
    let data: ServerTranslationPayload?
    let selected: ContextMeaningCandidate?
    let candidates: [ContextMeaningCandidate]?
}

private struct ServerTranslationPayload: Decodable {
    let translatedText: String?
    let translation: String?
    let result: String?
    let output: String?
    let text: String?
}

private struct ServerErrorPayload: Decodable {
    let error: String?
    let message: String?
    let status: String?
    let ok: Bool?
}

private struct ContextServerHealthResponse: Decodable {
    let status: String?
    let ok: Bool?
    let healthy: Bool?
    let data: String?
}

enum ContextMeaningError: Error {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int, String?)
}

private enum ContextServerDefaults {
    static let serverURL = "contextServerURL"
    static let clientId = "contextServerClientId"
    static let certificatePin = "contextServerCertificatePinSHA256"
}

private enum ContextServerEmbeddedDefaults {
    static let serverURL = "ContextServerBaseURL"
    static let token = "ContextServerToken"
    static let clientId = "ContextServerClientId"
    static let certificatePin = "ContextServerCertificatePinSHA256"
    static let signingSecret = "ContextServerSigningSecret"
    static let allowUserOverrides = "ContextServerAllowUserOverrides"
}

private struct ContextServerRuntimeConfig {
    let baseURL: URL
    let clientId: String?
    let token: String?
    let certificatePin: String?
    let signingSecret: String?
}

enum ContextServerTokenStore {
    private static let service = "readtap.contextserver"
    private static let account = "token"

    static func currentToken() -> String? { load() }

    static func isConfigured() -> Bool {
        (currentToken()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status != errSecItemNotFound {
            return false
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ContextServerSigningSecretStore {
    private static let service = "readtap.contextserver.signing"
    private static let account = "requestSigningSecret"

    static func currentSecret() -> String? { load() }

    @discardableResult
    static func save(_ secret: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status != errSecItemNotFound {
            return false
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class ContextMeaningService {
    static let shared = ContextMeaningService()

    private static let fallbackServerBaseURL = "https://readtap-translation-worker.ymcyun99.workers.dev"
    private static let defaultContextMeaningPath = "/meaning"
    private static let defaultContextTranslatePath = "/translate"
    private static let defaultKoreanDictionaryPath = "/krdict"
    private static let legacyContextMeaningPath = "/v1/context-meaning"

    private static let requestTimeout = 10.0
    private static let maxResponseBytes = 1_200_000
    private let requestCoordinator = InFlightContextRequestCoordinator()

    // Cache URLSession instances by certificate pin so TCP connections are reused
    // across calls (including from AppWarmup prewarming → first real request).
    private var sessionCache: [String: URLSession] = [:]
    private let sessionCacheLock = NSLock()

    private init() {}

    private final actor InFlightContextRequestCoordinator {
        private var meaningRequests: [String: Task<ContextMeaningResponse, Error>] = [:]
        private var translateRequests: [String: Task<String, Error>] = [:]

        func runMeaning(
            _ key: String,
            _ operation: @escaping () async throws -> ContextMeaningResponse
        ) async throws -> ContextMeaningResponse {
            if let existing = meaningRequests[key] {
                return try await existing.value
            }

            let task = Task {
                try await operation()
            }
            meaningRequests[key] = task
            defer { meaningRequests[key] = nil }
            return try await task.value
        }

        func runTranslate(
            _ key: String,
            _ operation: @escaping () async throws -> String
        ) async throws -> String {
            if let existing = translateRequests[key] {
                return try await existing.value
            }

            let task = Task {
                try await operation()
            }
            translateRequests[key] = task
            defer { translateRequests[key] = nil }
            return try await task.value
        }
    }

    private func requestCacheKey(
        word: String,
        sentence: String,
        source: String,
        target: String,
        candidates: [String],
        maxCandidates: Int,
        provider: String?,
        apiKey: String?
    ) -> String {
        var hasher = Hasher()
        hasher.combine("meaning")
        hasher.combine(word.lowercased())
        hasher.combine(sentence.lowercased())
        hasher.combine(source.lowercased())
        hasher.combine(target.lowercased())
        hasher.combine(maxCandidates)
        hasher.combine(provider?.lowercased() ?? "")
        hasher.combine(self.normalizedAPIKeyHint(apiKey)?.lowercased() ?? "")
        for candidate in candidates {
            hasher.combine(candidate.lowercased())
        }
        return String(hasher.finalize())
    }

    private func requestCacheKeyForTranslate(
        text: String,
        source: String,
        target: String,
        context: String?,
        candidates: [String],
        provider: String?,
        apiKey: String?
    ) -> String {
        var hasher = Hasher()
        hasher.combine("translate")
        hasher.combine(text.lowercased())
        hasher.combine(source.lowercased())
        hasher.combine(target.lowercased())
        hasher.combine(context?.lowercased() ?? "")
        hasher.combine(provider?.lowercased() ?? "")
        hasher.combine(self.normalizedAPIKeyHint(apiKey)?.lowercased() ?? "")
        for candidate in candidates {
            hasher.combine(candidate.lowercased())
        }
        return String(hasher.finalize())
    }

    func isConfigured(defaults: UserDefaults = .standard) -> Bool {
        do {
            let config = try serverConfig(defaults: defaults)
            logServerConfigState(
                baseURL: config.baseURL,
                token: config.token,
                clientId: config.clientId,
                signingSecret: config.signingSecret,
                certificatePin: config.certificatePin
            )
            return true
        } catch {
            return false
        }
    }

    func hasAuthenticatedServer(defaults: UserDefaults = .standard) -> Bool {
        do {
            let config = try serverConfig(defaults: defaults)
            return config.token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } catch {
            return false
        }
    }

    func fetchMeaning(
        word: String,
        sentence: String,
        source: String,
        target: String,
        candidates: [String],
        maxCandidates: Int = 3,
        provider: String? = nil,
        apiKey: String? = nil,
        defaults: UserDefaults = .standard
    ) async throws -> ContextMeaningResponse {
        let config = try serverConfig(defaults: defaults)
        logServerConfigState(
            baseURL: config.baseURL,
            token: config.token,
            clientId: config.clientId,
            signingSecret: config.signingSecret,
            certificatePin: config.certificatePin
        )
        // Config-state warnings removed to avoid leaking server configuration
        // hints in device logs.
        let urls = resolvedContextEndpoints(from: config.baseURL)
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedWord.isEmpty == false else { throw ContextMeaningError.invalidResponse }
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidates = normalizeCandidates(candidates, primary: trimmedWord, maxCandidates: maxCandidates)
        let normalizedProvider = normalizedContextProvider(provider)
        let normalizedAPIKey = normalizedAPIKey(apiKey)

        let payload = ContextMeaningRequest(
            word: trimmedWord,
            sentence: trimmedSentence,
            source: source.trimmingCharacters(in: .whitespacesAndNewlines),
            target: target.trimmingCharacters(in: .whitespacesAndNewlines),
            candidates: normalizedCandidates,
            maxCandidates: max(1, min(3, maxCandidates)),
            provider: normalizedProvider,
            apiKey: normalizedAPIKey
        )
        let cacheKey = requestCacheKey(
            word: trimmedWord,
            sentence: trimmedSentence,
            source: source.trimmingCharacters(in: .whitespacesAndNewlines),
            target: target.trimmingCharacters(in: .whitespacesAndNewlines),
            candidates: normalizedCandidates,
            maxCandidates: max(1, min(3, maxCandidates)),
            provider: normalizedProvider,
            apiKey: normalizedAPIKey
        )

        return try await requestCoordinator.runMeaning(cacheKey) {
            try await self.postJSON(
                endpoints: urls,
                payload: payload,
                responseType: ContextMeaningResponse.self,
                config: config
            )
        }
    }

    func translate(
        text: String,
        source: String,
        target: String,
        context: String?,
        candidates: [String],
        provider: String? = nil,
        apiKey: String? = nil,
        defaults: UserDefaults = .standard
    ) async throws -> String {
        let requestText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestText.isEmpty == false else { throw ContextMeaningError.invalidResponse }

        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedProvider = normalizedContextProvider(provider)
        let normalizedAPIKey = normalizedAPIKey(apiKey)
        let normalizedCandidates = candidates.isEmpty ? [requestText] : Array(Set(candidates))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        let payload = ContextTranslateRequest(
            text: requestText,
            source: normalizedSource,
            target: normalizedTarget,
            context: context?.trimmingCharacters(in: .whitespacesAndNewlines),
            candidates: normalizedCandidates,
            maxCandidates: max(1, min(3, normalizedCandidates.count)),
            task: "translate",
            provider: normalizedProvider,
            apiKey: normalizedAPIKey
        )

        do {
            let config = try serverConfig(defaults: defaults)
            logServerConfigState(
                baseURL: config.baseURL,
                token: config.token,
                clientId: config.clientId,
                signingSecret: config.signingSecret,
                certificatePin: config.certificatePin
            )
            // Config-state warnings removed to avoid leaking server configuration
            // hints in device logs.
            let cacheKey = requestCacheKeyForTranslate(
                text: requestText,
                source: normalizedSource,
                target: normalizedTarget,
                context: context?.trimmingCharacters(in: .whitespacesAndNewlines),
                candidates: normalizedCandidates,
                provider: normalizedProvider,
                apiKey: normalizedAPIKey
            )
            let translated = try await requestCoordinator.runTranslate(cacheKey) {
                let response = try await self.postJSON(
                    endpoints: self.resolvedTranslateEndpoints(from: config.baseURL),
                    payload: payload,
                    responseType: ServerTranslationResponse.self,
                    config: config
                )
                guard let translated = self.translatedText(from: response),
                      translated.isEmpty == false else {
                    throw ContextMeaningError.invalidResponse
                }
                return translated
            }
            return translated
        } catch {
            // Keep compatibility with servers that only expose the old meaning endpoint.
        }

        guard let contextPayload = context?.trimmingCharacters(in: .whitespacesAndNewlines), contextPayload.isEmpty == false else {
            throw ContextMeaningError.invalidResponse
        }

        do {
            let fallback = try await fetchMeaning(
                word: requestText,
                sentence: contextPayload,
                source: normalizedSource,
                target: normalizedTarget,
                candidates: payload.candidates,
                provider: normalizedProvider,
                apiKey: normalizedAPIKey,
                defaults: defaults
            )
            if let fallbackText = fallback.resolvedCandidates().first?.meaningKo,
               fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return fallbackText
            }
        } catch {
            throw error
        }

        throw ContextMeaningError.invalidResponse
    }

    func fetchKoreanDictionaryEntries(
        word: String,
        defaults: UserDefaults = .standard
    ) async throws -> [KoreanDictionaryEntry] {
        let config = try serverConfig(defaults: defaults)
        logServerConfigState(
            baseURL: config.baseURL,
            token: config.token,
            clientId: config.clientId,
            signingSecret: config.signingSecret,
            certificatePin: config.certificatePin
        )

        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedWord.isEmpty == false else { throw ContextMeaningError.invalidResponse }

        let payload = ContextKoreanDictionaryRequest(word: trimmedWord)
        let response = try await postJSON(
            endpoints: resolvedKoreanDictionaryEndpoints(from: config.baseURL),
            payload: payload,
            responseType: ContextKoreanDictionaryResponse.self,
            config: config
        )
        let entries = response.entries ?? []
        guard entries.isEmpty == false else {
            throw ContextMeaningError.invalidResponse
        }
        return entries
    }

    func testConnection(
        rawServerURL: String?,
        rawToken: String? = nil,
        rawClientId: String? = nil,
        rawPinSHA256: String? = nil,
        rawSigningSecret: String? = nil,
        defaults: UserDefaults = .standard
    ) async throws -> Bool {
        let config = try serverConfig(
            rawServerURL: rawServerURL,
            rawToken: rawToken,
            rawClientId: rawClientId,
            rawPinSHA256: rawPinSHA256,
            rawSigningSecret: rawSigningSecret,
            defaults: defaults
        )
        logServerConfigState(
            baseURL: config.baseURL,
            token: config.token,
            clientId: config.clientId,
            signingSecret: config.signingSecret,
            certificatePin: config.certificatePin
        )
        let url = resolvedHealthEndpoint(from: config.baseURL)
        let request = try buildRequest(
            url: url,
            payloadData: nil,
            config: config,
            method: "GET"
        )
        let session = makeURLSession(pinnedSHA256: config.certificatePin)
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maxResponseBytes else { throw ContextMeaningError.invalidResponse }
        guard let http = response as? HTTPURLResponse else {
            throw ContextMeaningError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = parseContextServerErrorMessage(from: data)
            if http.statusCode == 401 {
                if isNotConfiguredResponse(message: message) {
                    throw ContextMeaningError.notConfigured
                }
            }
            #if DEBUG
            debugContextServerFailure(
                url: url,
                token: config.token,
                statusCode: http.statusCode,
                message: message
            )
            #endif
            throw ContextMeaningError.httpError(http.statusCode, message)
        }
        guard let health = try? JSONDecoder().decode(ContextServerHealthResponse.self, from: data) else {
            let normalized = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let normalized, ["ok", "true", "healthy", "up", "ready"].contains(normalized) {
                return true
            }
            return false
        }
        return isHealthy(health)
    }

    private func serverConfig(
        rawServerURL: String?,
        rawToken: String? = nil,
        rawClientId: String? = nil,
        rawPinSHA256: String? = nil,
        rawSigningSecret: String? = nil,
        defaults: UserDefaults = .standard
    ) throws -> ContextServerRuntimeConfig {
        let embedded = readEmbeddedConfig()
        // If the project config does not declare an override flag (common in local builds),
        // keep user-provided values enabled so keychain/API overrides remain usable.
        let allowUserOverrides = embedded.allowUserOverrides ?? true

        let baseURL = try ensureValidServerURL(
            rawServerURL?.trimmingCharacters(in: .whitespacesAndNewlines) ??
            (allowUserOverrides ? defaults.string(forKey: ContextServerDefaults.serverURL) : nil) ??
            resolveServerEnvValue([
                "CONTEXT_SERVER_BASE_URL",
                "CONTEXT_SERVER_PROD_BASE_URL",
                "CONTEXT_SERVER_BASE_URL_PROD",
                "CONTEXT_SERVER_STAGING_BASE_URL",
                "CONTEXT_SERVER_BASE_URL_STAGING",
                "CONTEXT_SERVER_URL",
                "READTAP_SERVER_BASE_URL",
                "READTAP_SERVER_BASE_URL_PROD",
                "READTAP_SERVER_BASE_URL_STAGING",
                "READTAP_SERVER_URL",
            ]) ??
            embedded.baseURL ??
            Self.fallbackServerBaseURL
        )
        let storedClientId = defaults.string(forKey: ContextServerDefaults.clientId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let envClientId = resolveServerEnvValue([
                "CONTEXT_SERVER_CLIENT_ID",
                "CONTEXT_SERVER_PROD_CLIENT_ID",
                "CONTEXT_SERVER_CLIENT_ID_PROD",
                "CONTEXT_SERVER_STAGING_CLIENT_ID",
                "CONTEXT_SERVER_CLIENT_ID_STAGING",
                "READTAP_SERVER_CLIENT_ID",
                "READTAP_SERVER_CLIENT_ID_PROD",
                "READTAP_SERVER_CLIENT_ID_STAGING",
            ])
        // Client identity is part of the worker auth path now, so prefer the
        // shipped build value over any previously saved override to avoid stale
        // local settings causing 401 unauthorized_client errors.
        let clientId = resolveServerValue(rawClientId)
            ?? envClientId
            ?? embedded.clientId
            ?? (storedClientId?.isEmpty == false ? storedClientId : nil)
        let pinValue = resolveServerValue(rawPinSHA256)
        let storedPin = defaults.string(forKey: ContextServerDefaults.certificatePin)
            .map { normalizePinValue($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let certificatePin = pinValue.flatMap { normalizePinValue($0).isEmpty ? nil : normalizePinValue($0) }
            ?? storedPin
            ?? resolveServerEnvValue([
                "CONTEXT_SERVER_CERTIFICATE_PIN",
                "CONTEXT_SERVER_CERTIFICATE_PIN_SHA256",
                "CONTEXT_SERVER_CERTIFICATE_PIN_SHA256_PROD",
                "CONTEXT_SERVER_PROD_CERTIFICATE_PIN_SHA256",
                "CONTEXT_SERVER_CERTIFICATE_PIN_PROD",
                "CONTEXT_SERVER_STAGING_CERTIFICATE_PIN_SHA256",
                "CONTEXT_SERVER_STAGING_CERTIFICATE_PIN",
                "CONTEXT_SERVER_PROD_CERTIFICATE_PIN",
                "READTAP_SERVER_CERTIFICATE_PIN",
                "READTAP_SERVER_CERTIFICATE_PIN_SHA256",
                "READTAP_SERVER_CERTIFICATE_PIN_SHA256_PROD",
                "READTAP_SERVER_PROD_CERTIFICATE_PIN_SHA256",
                "READTAP_SERVER_CERTIFICATE_PIN_PROD",
                "READTAP_SERVER_STAGING_CERTIFICATE_PIN",
                "READTAP_SERVER_STAGING_CERTIFICATE_PIN_SHA256"
            ]).flatMap(normalizePinValue)
            ?? embedded.certificatePin
        let envToken = resolveServerEnvValue([
                "CONTEXT_SERVER_TOKEN",
                "CONTEXT_SERVER_PROD_TOKEN",
                "CONTEXT_SERVER_TOKEN_PROD",
                "CONTEXT_SERVER_STAGING_TOKEN",
                "CONTEXT_SERVER_TOKEN_STAGING",
                "READTAP_SERVER_TOKEN",
                "READTAP_SERVER_PROD_TOKEN",
                "READTAP_SERVER_TOKEN_PROD",
                "READTAP_SERVER_STAGING_TOKEN",
                "READTAP_SERVER_TOKEN_STAGING"
            ])
        let keychainToken = allowUserOverrides
            ? ContextServerTokenStore.currentToken()?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let embeddedToken = resolveServerValue(embedded.token)

        var token: String?
        var tokenSource = "missing"
        if let raw = resolveServerValue(rawToken) {
            token = raw
            tokenSource = "arg"
        } else if let resolved = envToken {
            token = resolved
            tokenSource = "env"
        } else if let resolved = keychainToken, resolved.isEmpty == false {
            token = resolved
            tokenSource = "keychain"
        } else if let resolved = embeddedToken, resolved.isEmpty == false {
            token = resolved
            tokenSource = "embedded"
        }

        let envSigningSecret = resolveServerEnvValue([
                "CONTEXT_SERVER_SIGNING_SECRET",
                "CONTEXT_SERVER_SIGNING_SECRET_PROD",
                "CONTEXT_SERVER_PROD_SIGNING_SECRET",
                "CONTEXT_SERVER_SIGNING_SECRET_STAGING",
                "CONTEXT_SERVER_STAGING_SIGNING_SECRET",
                "REQUEST_SIGNING_SECRET",
                "READTAP_SERVER_SIGNING_SECRET",
                "READTAP_SERVER_SIGNING_SECRET_PROD",
                "READTAP_SERVER_SIGNING_SECRET_STAGING",
                "READTAP_SERVER_REQUEST_SIGNING_SECRET"
            ])
        let keychainSigningSecret = allowUserOverrides
            ? ContextServerSigningSecretStore.currentSecret()?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let embeddedSigningSecret = resolveServerValue(embedded.signingSecret)
        let signingSecret = resolveServerValue(rawSigningSecret)
            ?? envSigningSecret
            ?? keychainSigningSecret
            ?? embeddedSigningSecret
        if requiresAuthenticatedRemoteServer(baseURL) {
            guard let resolvedToken = resolveServerValue(token), resolvedToken.isEmpty == false else {
                throw ContextMeaningError.notConfigured
            }
            guard let resolvedSigningSecret = resolveServerValue(signingSecret), resolvedSigningSecret.isEmpty == false else {
                throw ContextMeaningError.notConfigured
            }
        }
        return ContextServerRuntimeConfig(
            baseURL: baseURL,
            clientId: clientId,
            token: token,
            certificatePin: certificatePin,
            signingSecret: signingSecret
        )
    }

    private func readEmbeddedConfig() -> (baseURL: String?, token: String?, clientId: String?, certificatePin: String?, signingSecret: String?, allowUserOverrides: Bool?) {
        let info = Bundle.main.infoDictionary
        let embeddedServerURL = resolveServerValue(info?[ContextServerEmbeddedDefaults.serverURL] as? String)
        let embeddedToken = resolveServerValue(info?[ContextServerEmbeddedDefaults.token] as? String)
        let embeddedClientId = resolveServerValue(info?[ContextServerEmbeddedDefaults.clientId] as? String)
        let embeddedPin = resolveServerValue(info?[ContextServerEmbeddedDefaults.certificatePin] as? String)
            .flatMap { normalizePinValue($0).isEmpty ? nil : normalizePinValue($0) }
        let embeddedSigningSecret = resolveServerValue(info?[ContextServerEmbeddedDefaults.signingSecret] as? String)
        let allowUserOverrides = boolValue(from: info?[ContextServerEmbeddedDefaults.allowUserOverrides])
        return (embeddedServerURL, embeddedToken, embeddedClientId, embeddedPin, embeddedSigningSecret, allowUserOverrides)
    }

    private func boolValue(from raw: Any?) -> Bool? {
        if let boolValue = raw as? Bool {
            return boolValue
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        if let string = raw as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "y"].contains(normalized) {
                return true
            }
            if ["0", "false", "no", "n"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    private func serverConfig(defaults: UserDefaults = .standard) throws -> ContextServerRuntimeConfig {
        return try serverConfig(rawServerURL: nil, defaults: defaults)
    }

    private func logContextEnvironmentProbeIfNeeded() {
    }

    private func resolveServerValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else {
            return nil
        }

        if let resolved = resolveServerEnvPlaceholder(trimmed) {
            return resolved
        }

        if trimmed.contains("$(") || trimmed.contains("${") {
            return nil
        }
        if trimmed.contains("${") && trimmed.contains("}") {
            return nil
        }
        return trimmed
    }

    private func resolveServerEnvPlaceholder(_ value: String) -> String? {
        guard let singleMacroName = resolveSingleMacroName(from: value),
              let envValue = ProcessInfo.processInfo.environment[singleMacroName] else {
            return nil
        }
        let resolved = envValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }

    private func resolveSingleMacroName(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$(") && trimmed.hasSuffix(")") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
            let macro = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return macro.isEmpty ? nil : macro
        }
        if trimmed.hasPrefix("${") && trimmed.hasSuffix("}") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
            let macro = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return macro.isEmpty ? nil : macro
        }
        return nil
    }

    private func logServerConfigState(
        baseURL: URL,
        token: String?,
        clientId: String?,
        signingSecret: String?,
        certificatePin: String?
    ) {
        // Intentionally no-op: previously logged baseURL / token-status / clientId
        // / signing-status / pin-status. Removed to avoid leaking server config in
        // device logs / Console.app captures.
    }

    private func resolveServerEnvValue(_ keys: [String]) -> String? {
        for key in keys {
            if let value = resolveServerValue(ProcessInfo.processInfo.environment[key]) {
                return value
            }
        }
        return nil
    }

    private func resolvedContextEndpoint(from baseURL: URL) -> URL {
        guard let first = resolvedContextEndpoints(from: baseURL).first else {
            return baseURL
        }
        return first
    }

    private func resolvedTranslateEndpoint(from baseURL: URL) -> URL {
        guard let first = resolvedTranslateEndpoints(from: baseURL).first else {
            return baseURL
        }
        return first
    }

    private func resolvedContextEndpoints(from baseURL: URL) -> [URL] {
        return resolvedEndpointCandidates(
            from: baseURL,
            primaryPath: Self.defaultContextMeaningPath,
            fallbackPath: Self.defaultContextMeaningPath
        )
    }

    private func resolvedTranslateEndpoints(from baseURL: URL) -> [URL] {
        return resolvedEndpointCandidates(
            from: baseURL,
            primaryPath: Self.defaultContextTranslatePath,
            fallbackPath: Self.defaultContextMeaningPath
        )
    }

    private func resolvedKoreanDictionaryEndpoints(from baseURL: URL) -> [URL] {
        let rawPath = baseURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lowerPath = normalizedPath.lowercased()
        var pathCandidates: [String] = []
        var seen = Set<String>()

        func appendPath(_ path: String) {
            var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { return }
            if normalized != "/" && normalized.hasPrefix("/") == false {
                normalized = "/\(normalized)"
            }
            normalized = normalized.replacingOccurrences(of: "//+", with: "/", options: .regularExpression)
            if seen.insert(normalized.lowercased()).inserted {
                pathCandidates.append(normalized)
            }
        }

        func appendReplacedPath(for marker: String) {
            guard let range = lowerPath.range(of: marker) else { return }
            let prefix = normalizedPath[..<range.lowerBound]
            appendPath("/\(prefix)\(Self.defaultKoreanDictionaryPath)")
        }

        if lowerPath.isEmpty || lowerPath == "v1" {
            appendPath(Self.defaultKoreanDictionaryPath)
        } else if lowerPath.contains("/krdict") {
            appendPath("/\(normalizedPath)")
            appendPath(Self.defaultKoreanDictionaryPath)
        } else if lowerPath.contains("/meaning") {
            appendReplacedPath(for: "/meaning")
            appendPath(Self.defaultKoreanDictionaryPath)
        } else if lowerPath.contains("/translate") {
            appendReplacedPath(for: "/translate")
            appendPath(Self.defaultKoreanDictionaryPath)
        } else if lowerPath.contains("/v1/context-meaning") {
            appendReplacedPath(for: "/v1/context-meaning")
            appendPath(Self.defaultKoreanDictionaryPath)
        } else {
            appendPath("/\(normalizedPath)\(Self.defaultKoreanDictionaryPath)")
            appendPath(Self.defaultKoreanDictionaryPath)
        }

        var endpoints: [URL] = []
        for path in pathCandidates {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { continue }
            components.path = path
            if let resolved = components.url {
                endpoints.append(resolved)
            }
        }
        return endpoints
    }

    private func resolvedEndpointCandidates(
        from baseURL: URL,
        primaryPath: String,
        fallbackPath: String
    ) -> [URL] {
        let rawPath = baseURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lowerPath = normalizedPath.lowercased()
        var pathCandidates: [String] = []
        var seen = Set<String>()

        func appendPath(_ path: String) {
            var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { return }
            if normalized != "/" && normalized.hasPrefix("/") == false {
                normalized = "/\(normalized)"
            }
            normalized = normalized.replacingOccurrences(of: "//+", with: "/", options: .regularExpression)
            if seen.insert(normalized.lowercased()).inserted {
                pathCandidates.append(normalized)
            }
        }

        if lowerPath.isEmpty || lowerPath == "v1" {
            appendPath(primaryPath)
            if primaryPath == Self.defaultContextTranslatePath {
                appendPath(fallbackPath)
            }
            appendPath(Self.legacyContextMeaningPath)
        } else if lowerPath.contains("/meaning") {
            appendPath("/\(normalizedPath)")
            if primaryPath == Self.defaultContextTranslatePath {
                if let range = lowerPath.range(of: "/meaning") {
                    let start = normalizedPath[..<range.lowerBound]
                    appendPath("/\(start)\(Self.defaultContextTranslatePath)")
                }
            } else {
                appendPath(Self.defaultContextMeaningPath)
            }
            appendPath(Self.legacyContextMeaningPath)
        } else if lowerPath.contains("/translate") {
            appendPath("/\(normalizedPath)")
            if primaryPath == Self.defaultContextMeaningPath {
                if let range = lowerPath.range(of: "/translate") {
                    let start = normalizedPath[..<range.lowerBound]
                    appendPath("/\(start)\(Self.defaultContextMeaningPath)")
                }
            }
            appendPath(Self.legacyContextMeaningPath)
        } else {
            appendPath("/\(normalizedPath)\(primaryPath)")
            if primaryPath == Self.defaultContextMeaningPath {
                appendPath("/\(normalizedPath)/v1/context-meaning")
            } else {
                appendPath("/\(normalizedPath)\(Self.defaultContextMeaningPath)")
            }
        }

        appendPath(primaryPath)
        appendPath(fallbackPath)
        appendPath(Self.defaultContextMeaningPath)

        var endpoints: [URL] = []
        for path in pathCandidates {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { continue }
            components.path = path
            if let resolved = components.url {
                endpoints.append(resolved)
            }
        }
        return endpoints
    }

    private func resolvedHealthEndpoint(from baseURL: URL) -> URL {
        guard let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        var components = baseComponents
        let currentPath = baseComponents.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentPath.isEmpty || currentPath == "/" {
            components.path = "/health"
        } else if currentPath.lowercased().contains("/health") {
            // keep explicit health path as-is
        } else if currentPath.hasSuffix("/") {
            components.path = "\(currentPath)health"
        } else {
            components.path = "\(currentPath)/health"
        }
        return components.url ?? baseURL
    }

    func requiresAuthenticatedContextServer(rawServerURL: String?) -> Bool {
        guard let rawServerURL,
              let serverURL = try? ensureValidServerURL(rawServerURL) else {
            return false
        }
        return requiresAuthenticatedRemoteServer(serverURL)
    }

    private func ensureValidServerURL(_ rawURL: String) throws -> URL {
        var trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw ContextMeaningError.notConfigured }

        // xcconfig files treat // as comments, so embedded URLs may arrive without a scheme.
        // Auto-prepend https:// when the scheme is missing.
        if !trimmed.contains("://") {
            // Strip any partial scheme remnants like "https:" or "https:/"
            let partialSchemes = ["https:/", "https:", "http:/", "http:"]
            for partial in partialSchemes {
                if trimmed.hasPrefix(partial) {
                    trimmed = String(trimmed.dropFirst(partial.count))
                    break
                }
            }
            trimmed = "https://\(trimmed)"
        }

        guard let url = URL(string: trimmed) else { throw ContextMeaningError.invalidURL }
        guard let scheme = url.scheme?.lowercased(), isAllowedScheme(scheme, host: url.host) else {
            throw ContextMeaningError.invalidURL
        }
        return url
    }

    private func requiresAuthenticatedRemoteServer(_ serverURL: URL) -> Bool {
        guard let host = serverURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              host.isEmpty == false else {
            return true
        }
        #if DEBUG
        if ["localhost", "127.0.0.1", "::1"].contains(host) {
            return false
        }
        #endif
        return true
    }

    private func isAllowedScheme(_ scheme: String, host: String?) -> Bool {
        if scheme == "https" {
            return true
        }
        #if DEBUG
        let localhost = ["localhost", "127.0.0.1", "::1"]
        if scheme == "http", let host = host, localhost.contains(host) {
            return true
        }
        #endif
        return false
    }

    private func buildRequest(
        url: URL,
        payloadData: Data?,
        config: ContextServerRuntimeConfig,
        method: String = "POST"
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("readtap-client/ios", forHTTPHeaderField: "User-Agent")

        let requestId = UUID().uuidString
        let timestamp = String(Int(Date().timeIntervalSince1970))
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")
        if let token = config.token, token.isEmpty == false {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let customClientId = config.clientId, customClientId.isEmpty == false {
            request.setValue(customClientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
        }
        if let signingSecret = config.signingSecret, signingSecret.isEmpty == false {
            let signingPayload = payloadData ?? Data()
            if let signature = requestSignature(
                method: request.httpMethod ?? "POST",
                requestURL: url,
                requestId: requestId,
                timestamp: timestamp,
                payload: signingPayload,
                secret: signingSecret
            ) {
                request.setValue("HMAC-SHA256 \(signature)", forHTTPHeaderField: "X-ReadTap-Signature")
            }
        }
        request.httpBody = payloadData
        return request
    }

    private func postJSON<Response: Decodable, Request: Encodable>(
        endpoints: [URL],
        payload: Request,
        responseType: Response.Type,
        config: ContextServerRuntimeConfig
    ) async throws -> Response {
        var lastError: Error?
        for endpoint in endpoints {
            debugContextLog("🚀 ContextMeaningService: POST endpoint=\(endpoint.absoluteString)")
            do {
                return try await postJSON(
                    url: endpoint,
                    payload: payload,
                    responseType: responseType,
                    config: config
                )
            } catch {
                lastError = error
                if shouldRetryWithAlternateEndpoint(error) == false {
                    throw error
                }
                debugContextLog("🚀 ContextMeaningService: fallback endpoint due to error=\(error)")
            }
        }
        throw lastError ?? ContextMeaningError.invalidResponse
    }

    private func shouldRetryWithAlternateEndpoint(_ error: Error) -> Bool {
        guard let contextError = error as? ContextMeaningError else { return false }
        switch contextError {
        case .httpError(let code, let message):
            let normalizedMessage = message?.lowercased() ?? ""
            return code == 404 || code == 405 ||
                normalizedMessage.contains("not_found") ||
                normalizedMessage.contains("method_not_allowed")
        default:
            return false
        }
    }

    private func postJSON<Response: Decodable, Request: Encodable>(
        url: URL,
        payload: Request,
        responseType: Response.Type,
        config: ContextServerRuntimeConfig
    ) async throws -> Response {
        let payloadData = try JSONEncoder().encode(payload)
        let request = try buildRequest(url: url, payloadData: payloadData, config: config)
        let session = makeURLSession(pinnedSHA256: config.certificatePin)
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maxResponseBytes else { 
            debugContextLog("🚀 ContextMeaningService: ERROR data size \(data.count) bytes > max")
            throw ContextMeaningError.invalidResponse 
        }
        guard let http = response as? HTTPURLResponse else {
            debugContextLog("🚀 ContextMeaningService: ERROR not HTTP response")
            throw ContextMeaningError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = parseContextServerErrorMessage(from: data)
            debugContextLog("🚀 ContextMeaningService HTTP ERROR \(http.statusCode)")
            debugContextLog("🚀 Raw Response: \(String(data: data, encoding: .utf8) ?? "N/A")")
            debugContextLog("🚀 Request Config Token present? \((config.token?.isEmpty == false))")
            if http.statusCode == 401 {
                if isNotConfiguredResponse(message: message) {
                    throw ContextMeaningError.notConfigured
                }
            }
            #if DEBUG
            debugContextServerFailure(
                url: url,
                token: config.token,
                statusCode: http.statusCode,
                message: message
            )
            #endif
            throw ContextMeaningError.httpError(http.statusCode, message)
        }
        do {
            debugContextLog("🚀 ContextMeaningService HTTP \(http.statusCode) ok bodyPreview=\((String(data: data, encoding: .utf8) ?? "N/A").prefix(260))")
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            debugContextLog("🚀 ContextMeaningService DECODE ERROR: \(error)")
            debugContextLog("🚀 Raw Response: \(String(data: data, encoding: .utf8) ?? "N/A")")
            throw ContextMeaningError.invalidResponse
        }
    }

    private func isHealthy(_ response: ContextServerHealthResponse) -> Bool {
        if let ok = response.ok {
            return ok
        }
        if let healthy = response.healthy {
            return healthy
        }
        let normalized = response.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "ok" || normalized == "healthy" || normalized == "up" || normalized == "ready" {
            return true
        }
        if response.data?.isEmpty == false {
            return true
        }
        return false
    }

    private func parseContextServerErrorMessage(from data: Data) -> String {
        let fallback = String(data: data, encoding: .utf8) ?? ""
        guard let payload = try? JSONDecoder().decode(ServerErrorPayload.self, from: data) else {
            return fallback
        }
        var parts: [String] = []
        if let error = payload.error?.trimmingCharacters(in: .whitespacesAndNewlines), error.isEmpty == false {
            parts.append("error=\(error)")
        }
        if let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines), message.isEmpty == false {
            parts.append("message=\(message)")
        }
        if let status = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines), status.isEmpty == false {
            parts.append("status=\(status)")
        }
        if let ok = payload.ok {
            parts.append("ok=\(ok)")
        }
        return parts.isEmpty ? fallback : parts.joined(separator: ", ")
    }

    private func isNotConfiguredResponse(message: String) -> Bool {
        let normalized = message.lowercased()
        if normalized.contains("server_auth_not_configured") || normalized.contains("missing_context_token") || normalized.contains("missing_request_signing_secret") {
            return true
        }
        if normalized.contains("missing_token") || normalized.contains("invalid_signature") {
            return true
        }
        if normalized.contains("missing api key") || normalized.contains("missingapikey") || normalized.contains("missing key") {
            return true
        }
        if normalized.contains("missing token") || normalized.contains("token is missing") || normalized.contains("token required") || normalized.contains("missing client") {
            return true
        }
        if normalized.contains("authorization failed") || normalized.contains("invalid token") {
            return true
        }
        if normalized.contains("api key") && normalized.contains("missing") {
            return true
        }
        if normalized.contains("unauthorized") {
            return true
        }
        return false
    }

    private func secretStatus(_ value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return "missing"
        }
        return "set"
    }

    private func debugContextServerFailure(url: URL, token: String?, statusCode: Int, message: String) {
        #if DEBUG
        // Only the status code is logged. URL, token status, and server-returned
        // message body are deliberately omitted to avoid leaking server details.
        print("[ContextServer] HTTP error: \(statusCode)")
        #endif
    }

    private func debugContextLog(_ message: @autoclosure () -> String) {
        // Intentionally no-op. Previously emitted DEBUG prints from many call
        // sites that logged endpoint URLs, raw response bodies, decode errors,
        // and token-presence hints. The `@autoclosure` parameter is never
        // evaluated here, so the surrounding string interpolations also never
        // run — zero perf cost and zero leak.
    }

    private func requestSignature(
        method: String,
        requestURL: URL,
        requestId: String,
        timestamp: String,
        payload: Data,
        secret: String
    ) -> String? {
        guard let secretData = secret.data(using: .utf8), !secretData.isEmpty else { return nil }
        let path = requestURL.path.isEmpty ? "/" : requestURL.path
        let message = [method, path, timestamp, requestId, payload.base64EncodedString()].joined(separator: "\n")
        guard let messageData = message.data(using: .utf8) else { return nil }
        let key = SymmetricKey(data: secretData)
        let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
        return Data(mac).base64EncodedString()
    }

    private func makeURLSession(pinnedSHA256: String?) -> URLSession {
        let cacheKey = pinnedSHA256 ?? ""
        sessionCacheLock.lock()
        if let cached = sessionCache[cacheKey] {
            sessionCacheLock.unlock()
            return cached
        }
        sessionCacheLock.unlock()

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = false
        sessionConfig.timeoutIntervalForRequest = Self.requestTimeout
        sessionConfig.timeoutIntervalForResource = Self.requestTimeout + 2
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfig.urlCache = nil
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never

        let session: URLSession
        if let pin = pinnedSHA256, pin.isEmpty == false {
            session = URLSession(
                configuration: sessionConfig,
                delegate: ContextServerTrustEvaluator(pinnedSHA256: pin),
                delegateQueue: nil
            )
        } else {
            session = URLSession(configuration: sessionConfig)
        }

        sessionCacheLock.lock()
        sessionCache[cacheKey] = session
        sessionCacheLock.unlock()
        return session
    }

    private func translatedText(from response: ServerTranslationResponse) -> String? {
        if let value = response.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
            return value
        }
        if let value = response.translation?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
            return value
        }
        if let value = response.result?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
            return value
        }
        if let value = response.output?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
            return value
        }
        if let value = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
            return value
        }
        if let payload = response.data {
            if let value = payload.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
                return value
            }
            if let value = payload.translation?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
                return value
            }
            if let value = payload.result?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
                return value
            }
            if let value = payload.output?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
                return value
            }
            if let value = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false {
                return value
            }
        }
        if let selectedMeaning = response.selected?.meaningKo,
           selectedMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return selectedMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let candidateMeaning = response.candidates?.first(where: { $0.meaningKo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })?.meaningKo {
            return candidateMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func normalizePinValue(_ raw: String) -> String {
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
    }

    private func normalizeCandidates(_ candidates: [String], primary: String, maxCandidates: Int) -> [String] {
        let requestedLimit = max(1, min(6, max(1, maxCandidates)))
        let baseCandidates = candidates.isEmpty ? [primary] : candidates
        let fallbackPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        var normalized: [String] = []

        for candidate in baseCandidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                let lowered = trimmed.lowercased()
                if seen.insert(lowered).inserted {
                    normalized.append(trimmed)
                }
                if normalized.count >= requestedLimit { break }
            }
        }

        if normalized.isEmpty && fallbackPrimary.isEmpty == false {
            normalized.append(fallbackPrimary)
        }
        return normalized
    }

    private func normalizedContextProvider(_ provider: String?) -> String? {
        let normalized = provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let normalized, normalized.isEmpty == false else { return nil }
        if normalized == "deepl" || normalized == "mock" {
            return normalized
        }
        if ["openai", "server", "context", "contextserver"].contains(normalized) {
            return nil
        }
        return nil
    }

    private func normalizedAPIKey(_ apiKey: String?) -> String? {
        let trimmed = apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func normalizedAPIKeyHint(_ apiKey: String?) -> String? {
        let trimmed = apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        if trimmed.count <= 8 { return "\(trimmed.count)chars" }
        return "\(trimmed.count)-\(trimmed.prefix(4))...\(trimmed.suffix(4))"
    }
}

private final class ContextServerTrustEvaluator: NSObject, URLSessionDelegate {
    private let pinnedSHA256: String

    init(pinnedSHA256: String) {
        self.pinnedSHA256 = pinnedSHA256.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &trustError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard #available(iOS 15.0, *),
              let certChain = SecTrustCopyCertificateChain(serverTrust),
              let certs = certChain as? [SecCertificate],
              let cert = certs.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let certData = Data(SecCertificateCopyData(cert) as Data)
        let actualBase64 = sha256Base64(certData)
        let actualHex = sha256Hex(certData)
        if actualBase64.lowercased() == pinnedSHA256 || actualHex.lowercased() == pinnedSHA256 {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    private func sha256Base64(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
