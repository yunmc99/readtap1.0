import Foundation
import Security
import UIKit

protocol TranslationServicing {
    /// - Parameters:
    ///   - text: the word or phrase to translate
    ///   - source: BCP-47 code (e.g. "en")
    ///   - target: BCP-47 code (e.g. "ko")
    ///   - context: optional surrounding sentence to improve accuracy
    func translate(text: String, source: String, target: String, context: String?) async throws -> String
}

extension TranslationServicing {
    func translate(
        text: String,
        source: String,
        target: String,
        context: String?,
        preferredEngine: TranslationEngine?
    ) async throws -> String {
        try await translate(text: text, source: source, target: target, context: context)
    }

    func translate(
        text: String,
        source: String,
        target: String,
        context: String?,
        preferredEngine: TranslationEngine?,
        ignoreUserDefined: Bool = false,
        forceSingleEngine: Bool = false
    ) async throws -> String {
        if let composite = self as? CompositeTranslator {
            return try await composite.translate(
                text: text,
                source: source,
                target: target,
                context: context,
                preferredEngine: preferredEngine,
                ignoreUserDefined: ignoreUserDefined,
                forceSingleEngine: forceSingleEngine
            )
        }

        return try await translate(
            text: text,
            source: source,
            target: target,
            context: context,
            preferredEngine: preferredEngine
        )
    }
}

enum TranslationEngine: String, CaseIterable, Identifiable {
    case deepl
    case server

    static let deepL: TranslationEngine = .deepl

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .deepl: return AppText.t(.translationEngineDeepL)
        case .server: return AppText.t(.translationEngineServer)
        }
    }

    static func resolved(from storedValue: String?) -> TranslationEngine {
        let raw = (storedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return .deepl }
        // Migrate legacy "google"/"openai" selections to deepl
        if raw == "openai" || raw == "google" { return .deepl }
        return TranslationEngine(rawValue: raw) ?? .deepl
    }

    static func current(from defaults: UserDefaults = .standard) -> TranslationEngine {
        resolved(from: defaults.string(forKey: "translationEngine"))
    }

    static func migrateIfNeeded(from defaults: UserDefaults = .standard) {
        let raw = defaults.string(forKey: "translationEngine") ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(TranslationEngine.deepl.rawValue, forKey: "translationEngine")
        }
    }

    static func isConfigured(_ engine: TranslationEngine) -> Bool {
        switch engine {
        case .deepl:
            return ContextMeaningService.shared.isConfigured()
        case .server: return ContextMeaningService.shared.isConfigured()
        }
    }

    static func isAnyConfigured() -> Bool {
        // API-key engines or Apple on-device Translation (always available, no key needed)
        return true
    }

    static func isContextServerConfigured() -> Bool {
        ContextMeaningService.shared.isConfigured()
    }

    static func effectivePreferredEngine(from requested: TranslationEngine) -> TranslationEngine {
        if requested == .server {
            return isConfigured(.server) ? .deepl : requested
        }
        if isConfigured(.server) == false {
            return requested
        }
        return requested
    }
}

private actor SourceLanguageCache {
    private let maxItems = 512
    private var cache: [String: String] = [:]
    private var orderedKeys: [String] = []

    func load(_ key: String) -> String? {
        guard let value = cache[key] else { return nil }
        orderedKeys.removeAll(where: { $0 == key })
        orderedKeys.append(key)
        return value
    }

    func store(_ key: String, value: String) {
        if cache[key] == nil {
            orderedKeys.append(key)
        } else {
            orderedKeys.removeAll(where: { $0 == key })
            orderedKeys.append(key)
        }

        cache[key] = value

        if cache.count > maxItems {
            let overflow = cache.count - maxItems
            if overflow > 0 {
                let removeKeys = orderedKeys.prefix(overflow)
                orderedKeys.removeFirst(overflow)
                for removeKey in removeKeys {
                    cache.removeValue(forKey: removeKey)
                }
            }
        }
    }
}

enum TranslationError: Error {
    case missingAPIKey
    case invalidResponse
    case httpError(Int, String?)
    case timeout
}

// MARK: - Context Server

struct ContextServerTranslator: TranslationServicing {
    private let preferredProvider: String?
    private let apiKeyProvider: (() -> String?)?

    init(preferredProvider: String? = nil, apiKeyProvider: (() -> String?)? = nil) {
        self.preferredProvider = preferredProvider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.apiKeyProvider = apiKeyProvider
    }

    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.isEmpty == false else {
            throw TranslationError.invalidResponse
        }

        let targetCode = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceCode = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceCode.isEmpty == false, targetCode.isEmpty == false else {
            throw TranslationError.invalidResponse
        }

        do {
            let response = try await ContextMeaningService.shared.translate(
                text: word,
                source: sourceCode,
                target: target,
                context: context,
                candidates: [word],
                provider: preferredProvider,
                apiKey: apiKeyProvider?(),
                defaults: .standard
            )
            return response
        } catch let error as ContextMeaningError {
            switch error {
            case .httpError(let code, let message):
                throw TranslationError.httpError(code, message)
            case .notConfigured:
                throw TranslationError.missingAPIKey
            default:
                throw TranslationError.invalidResponse
            }
        } catch {
            throw TranslationError.invalidResponse
        }
    }
}

// MARK: - MyMemory Translation API (no API key needed)

/// Fallback translator using MyMemory API (mymemory.translated.net).
/// No API key required. Supports en↔ko, en↔ja, en↔es, en↔zh and many more.
/// Free tier: 5,000 chars/day (anonymous), enough for casual word lookups.
struct MyMemoryTranslator: TranslationServicing {

    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw TranslationError.invalidResponse }

        let src = preferredSourceLanguage(for: source, text: word)
        let tgt = langCode(from: target)
        guard src != tgt else { throw TranslationError.invalidResponse }

        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: word),
            URLQueryItem(name: "langpair", value: "\(src)|\(tgt)")
        ]
        guard let url = components.url else { throw TranslationError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw TranslationError.httpError(http.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(MyMemoryResponse.self, from: data)
        let translated = decoded.responseData.translatedText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // MyMemory returns the original text when it can't translate — treat as failure.
        guard !translated.isEmpty,
              translated.lowercased() != word.lowercased() else {
            throw TranslationError.invalidResponse
        }

        return translated
    }

    private func langCode(from bcp47: String) -> String {
        let raw = bcp47.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw.split(separator: "-").first.map(String.init) ?? raw
    }

    private func preferredSourceLanguage(for source: String, text: String) -> String {
        let candidate = langCode(from: source)
        if candidate != "und", !candidate.isEmpty { return candidate }

        let detected = LanguageDetector.detect(text)
        let fallback = langCode(from: detected.code)
        if fallback != "und", !fallback.isEmpty { return fallback }

        return "en"
    }
}

private struct MyMemoryResponse: Decodable {
    struct ResponseData: Decodable {
        let translatedText: String
    }
    let responseData: ResponseData
}

// MARK: - Korean Monolingual Dictionary (국립국어원 한국어기초사전)

struct KoreanDictionaryTranslator: TranslationServicing {
    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw TranslationError.invalidResponse }

        let entries = try await KoreanDictionaryService.shared.lookup(word)
        guard let first = entries.first, !first.definition.isEmpty else {
            throw TranslationError.invalidResponse
        }

        // Format: [품사] 뜻풀이
        if !first.pos.isEmpty {
            return "[\(first.pos)] \(first.definition)"
        }
        return first.definition
    }
}

/// Composite router: tries configured API engines first, then falls back to system dictionary.
final class CompositeTranslator: TranslationServicing {
    static let shared = CompositeTranslator()
    private let myMemory: TranslationServicing = MyMemoryTranslator()
    private let koreanDict: TranslationServicing = KoreanDictionaryTranslator()
    private let contextServer: TranslationServicing = ContextServerTranslator(preferredProvider: "deepl")
    private let contextDeeplServer: TranslationServicing = ContextServerTranslator(
        preferredProvider: "deepl"
    )
    private let inFlightTranslationRequests = InFlightTranslationCoordinator()
    private let inMemoryTranslationCache = InMemoryTranslationCache()
    private let sourceLanguageCache = SourceLanguageCache()
    private let translationEngineBackoff = TranslationEngineBackoffGate()

    private struct InFlightTranslationRequestKey: Hashable {
        let text: String
        let source: String
        let target: String
        let context: String?
        let preferredEngine: TranslationEngine?
    }

    private actor InFlightTranslationCoordinator {
        private var requests: [InFlightTranslationRequestKey: Task<String, Error>] = [:]

        func run(_ key: InFlightTranslationRequestKey, _ operation: @escaping () async throws -> String) async throws -> String {
            if let running = requests[key] {
                return try await running.value
            }

            let task = Task<String, Error> {
                try await operation()
            }
            requests[key] = task

            defer {
                requests[key] = nil
            }

            return try await task.value
        }
    }

    private actor TranslationEngineBackoffGate {
        private struct State {
            var consecutiveFailures: Int = 0
            var blockedUntil: TimeInterval = 0
        }

        private static let maxConsecutiveFailures = 7
        private static let maxBackoffSeconds: TimeInterval = 50

        private var states: [String: State] = [:]

        func canAttempt(_ key: String) -> Bool {
            let now = Date().timeIntervalSince1970
            guard let state = states[key] else {
                return true
            }
            return state.blockedUntil <= now
        }

        func markSuccess(_ key: String) {
            states[key] = State()
        }

        func recordFailure(_ key: String, isRecoverable: Bool) {
            guard isRecoverable else {
                states[key] = State(consecutiveFailures: 0, blockedUntil: 0)
                return
            }

            var state = states[key] ?? State()
            state.consecutiveFailures = min(state.consecutiveFailures + 1, Self.maxConsecutiveFailures)
            let delayBase = Double(1 << min(state.consecutiveFailures, 6))
            let jitter = Double.random(in: 0...0.25) * delayBase
            let cooldown = min(delayBase + jitter, Self.maxBackoffSeconds)
            state.blockedUntil = Date().timeIntervalSince1970 + cooldown
            states[key] = state
        }
    }

    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
        try await translate(
            text: text,
            source: source,
            target: target,
            context: context,
            preferredEngine: nil
        )
    }

    func translate(
        text: String,
        source: String,
        target: String,
        context: String?,
        preferredEngine: TranslationEngine?,
        ignoreUserDefined: Bool = false,
        forceSingleEngine: Bool = false
    ) async throws -> String {
        let resolvedPreferredEngine = forceSingleEngine
            ? (preferredEngine ?? TranslationEngine.current())
            : preferredTranslationEngine(preferredEngine)
        let cleanedText = normalizeTranslationInput(text)
        guard !cleanedText.isEmpty else { throw TranslationError.invalidResponse }

        let normalizedSource = await resolvedSourceLanguage(
            source: source,
            text: cleanedText
        )
        let normalizedTarget = normalizedTranslationLanguage(target)
        let requestContext = normalizedTranslationContext(context)
        let inMemoryCacheKey = inMemoryTranslationCacheKey(
            text: cleanedText,
            source: normalizedSource,
            target: normalizedTarget,
            context: requestContext,
            preferredEngine: resolvedPreferredEngine
        )
        let requestKey = InFlightTranslationRequestKey(
            text: cleanedText,
            source: normalizedSource,
            target: normalizedTarget,
            context: requestContext,
            preferredEngine: resolvedPreferredEngine
        )

        return try await inFlightTranslationRequests.run(requestKey) { [self] in
            if let cached = await inMemoryTranslationCache.load(
                key: inMemoryCacheKey
            ) {
                return cached
            }

        return try await self.translateSingleShot(
            text: cleanedText,
            source: normalizedSource,
            target: normalizedTarget,
            context: context,
            allowChunking: true,
            preferredEngine: resolvedPreferredEngine,
            ignoreUserDefined: ignoreUserDefined,
            forceSingleEngine: forceSingleEngine
        )
        }
    }

    private func preferredTranslationEngine(_ preferredEngine: TranslationEngine?) -> TranslationEngine {
        guard ContextMeaningService.shared.isConfigured() else {
            return preferredEngine ?? TranslationEngine.current()
        }
        return TranslationEngine.effectivePreferredEngine(from: preferredEngine ?? .current())
    }

    private func translateSingleShot(
        text: String,
        source: String,
        target: String,
        context: String?,
        allowChunking: Bool,
        preferredEngine: TranslationEngine? = nil,
        ignoreUserDefined: Bool = false,
        forceSingleEngine: Bool = false
    ) async throws -> String {
        let src = normalizedTranslationLanguage(source)
        let tgt = normalizedTranslationLanguage(target)
        let cleanedText = normalizeTranslationInput(text)
        guard !cleanedText.isEmpty else { throw TranslationError.invalidResponse }
        let requestContext = normalizedTranslationContext(context)
        let resolvedPreferredEngine = forceSingleEngine
            ? (preferredEngine ?? TranslationEngine.current())
            : preferredTranslationEngine(preferredEngine)
        let inMemoryCacheKey = inMemoryTranslationCacheKey(
            text: cleanedText,
            source: src,
            target: tgt,
            context: requestContext,
            preferredEngine: resolvedPreferredEngine
        )
        if ignoreUserDefined == false,
           let userDefined = loadUserDefinedTranslation(
            text: cleanedText,
            source: src,
            target: tgt
        ) {
            return userDefined
        }
        if allowChunking {
            let chunks = splitTextForTranslation(cleanedText)
            if chunks.count > 1 {
                if requestContext == nil {
                    return try await translateChunksConcurrently(
                        chunks: chunks,
                        source: source,
                        target: target,
                        fallbackText: cleanedText,
                        preferredEngine: preferredEngine,
                        ignoreUserDefined: ignoreUserDefined
                    )
                }

                var translatedParts: [String] = []
                var rollingChunkContext: String?

                for chunk in chunks {
                    let chunkText = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if chunkText.isEmpty { continue }
                    let chunkContext = chunkTranslationContext(
                        requestContext: requestContext,
                        rollingContext: rollingChunkContext
                    )
                    do {
                        let translated = try await translateSingleShot(
                            text: chunkText,
                            source: source,
                            target: target,
                            context: chunkContext,
                            allowChunking: false,
                            preferredEngine: preferredEngine,
                            ignoreUserDefined: ignoreUserDefined,
                            forceSingleEngine: forceSingleEngine
                        )
                        translatedParts.append(translated)
                    } catch {
                        let translated = try await translateSingleShot(
                            text: chunkText,
                            source: source,
                            target: target,
                            context: nil,
                            allowChunking: false,
                            preferredEngine: preferredEngine,
                            ignoreUserDefined: ignoreUserDefined,
                            forceSingleEngine: forceSingleEngine
                        )
                        translatedParts.append(translated)
                    }
                    rollingChunkContext = combineChunkContext(current: rollingChunkContext, with: chunkText)
                }
                if translatedParts.isEmpty {
                    throw TranslationError.invalidResponse
                }
                return translatedParts.joined(separator: "\n\n")
            }
        }

        let normalizedSource = await resolvedSourceLanguage(source: src, text: cleanedText)
        let normalizedTarget = normalizedLangCode(tgt)
        let inputLength = cleanedText.count
        let contextLength = requestContext?.count ?? 0
        let shouldTryContextServer = forceSingleEngine ? false : canUseContextServer(
            source: normalizedSource,
            target: normalizedTarget,
            context: requestContext
        )
        let supportsDeepL = isSupportedByDeepL(source: normalizedSource, target: normalizedTarget)
        let textBucket = translationTextBucket(for: cleanedText)

        if normalizedSource == normalizedTarget && !(src == "ko" && tgt == "ko") {
            return cleanedText
        }

        func loadCachedTranslation(_ engine: TranslationAttemptEngine, contextKey: String?) -> String? {
            guard let cached = TranslationLookupCache.shared.load(
                text: cleanedText,
                source: normalizedSource,
                target: normalizedTarget,
                engine: engine.rawValue,
                context: contextKey
            ) else {
                return nil
            }

            logAttemptTelemetry(
                source: normalizedSource,
                target: normalizedTarget,
                engine: engine,
                inputLength: inputLength,
                contextLength: contextLength,
                success: true,
                isNoop: false,
                isCached: true,
                latencyMs: 0,
                errorCode: nil,
                text: cleanedText
            )

            return cached
        }

        func performTranslateWithMetrics(
                engine: TranslationAttemptEngine,
                service: TranslationServicing,
                requestContext: String?,
                backoffKey: String
            ) async throws -> String {
                let maxAttempts = translationRetryAttempts(
                    for: engine,
                    inputLength: cleanedText.count,
                    hasContext: requestContext != nil
                )

                for attempt in 0..<maxAttempts {
                    let startTime = CFAbsoluteTimeGetCurrent()
                    do {
                        let output = try await service.translate(
                            text: cleanedText,
                            source: normalizedSource,
                            target: tgt,
                            context: requestContext
                        )
                        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                        let translated = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !translated.isEmpty else { throw TranslationError.invalidResponse }
                        if shouldRejectTranslationOutput(
                            source: cleanedText,
                            output: translated,
                            sourceLang: normalizedSource,
                            targetLang: normalizedTarget
                        ) {
                            throw TranslationError.invalidResponse
                        }
                        if hasMeaningfulCharacters(translated) == false {
                            throw TranslationError.invalidResponse
                        }
                        if isLikelyLowQualityTranslation(
                            input: cleanedText,
                            output: translated,
                            sourceLang: normalizedSource,
                            targetLang: normalizedTarget
                        ) {
                            throw TranslationError.invalidResponse
                        }

                        let isNoop = shouldRetryNoopTranslation(
                            input: cleanedText,
                            output: translated,
                            source: normalizedSource,
                            target: tgt
                        )
                        if isNoop && engine == .deepl {
                            logAttemptTelemetry(
                                source: normalizedSource,
                                target: normalizedTarget,
                                engine: engine,
                                inputLength: inputLength,
                                contextLength: contextLength,
                                success: false,
                                isNoop: true,
                                isCached: false,
                                latencyMs: latencyMs,
                                errorCode: nil,
                                text: cleanedText
                            )
                            throw TranslationError.invalidResponse
                        }

                        TranslationLookupCache.shared.save(
                            text: cleanedText,
                            source: normalizedSource,
                            target: normalizedTarget,
                            engine: engine.rawValue,
                            context: requestContext,
                            translated: translated,
                            at: Date()
                        )

                        logAttemptTelemetry(
                            source: normalizedSource,
                            target: normalizedTarget,
                            engine: engine,
                            inputLength: inputLength,
                            contextLength: contextLength,
                            success: true,
                            isNoop: isNoop,
                            isCached: false,
                            latencyMs: latencyMs,
                            errorCode: nil,
                            text: cleanedText
                        )

                        await translationEngineBackoff.markSuccess(backoffKey)
                        return translated
                    } catch {
                        let mappedError = mapToTranslationError(error)
                        let shouldRetryAttempt = shouldRetryTranslationError(
                            mappedError,
                            engine: engine,
                            attempt: attempt,
                            maxAttempts: maxAttempts
                        )

                        await translationEngineBackoff.recordFailure(
                            backoffKey,
                            isRecoverable: shouldRetryAttempt
                        )

                        if shouldRetryAttempt {
                            let delayMs = translationRetryDelayMs(
                                error: mappedError,
                                attempt: attempt,
                                engine: engine
                            )
                            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                            continue
                        }

                        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                        logAttemptTelemetry(
                            source: normalizedSource,
                            target: normalizedTarget,
                            engine: engine,
                            inputLength: inputLength,
                            contextLength: contextLength,
                            success: false,
                            isNoop: false,
                            isCached: false,
                            latencyMs: latencyMs,
                            errorCode: translationErrorCode(from: mappedError),
                            text: cleanedText
                        )
                        throw mappedError
                    }
                }

                throw TranslationError.invalidResponse
            }

        // 0) Korean→Korean monolingual dictionary
        if src == "ko" && tgt == "ko" {
            if let cached = loadCachedTranslation(.koreanDict, contextKey: nil) {
                return cached
            }
            do {
                let translated = try await performTranslateWithMetrics(
                    engine: .koreanDict,
                    service: koreanDict,
                    requestContext: nil,
                    backoffKey: translationBackoffKey(
                        engine: .koreanDict,
                        source: normalizedSource,
                        target: normalizedTarget,
                        textBucket: textBucket
                    )
                )
                await inMemoryTranslationCache.store(
                    key: inMemoryCacheKey,
                    value: translated
                )
                return translated
            } catch {
                // Dictionary unavailable — no further engines support ko→ko
                throw TranslationError.invalidResponse
            }
        }

        let preferDeepLFirst = (TranslationTelemetryStore.shared.shouldPrioritizeDeepL(
            source: normalizedSource,
            target: normalizedTarget,
            text: cleanedText
        ) ?? shouldPrioritizeDeepL(for: cleanedText, source: normalizedSource, target: normalizedTarget))
        && supportsDeepL

        let preferred = resolvedPreferredEngine

        let enginesToTry: [TranslationEngine] = {
            func add(_ list: inout [TranslationEngine], _ engine: TranslationEngine) {
                if list.contains(engine) == false {
                    list.append(engine)
                }
            }

        if preferDeepLFirst {
                var ordered: [TranslationEngine] = []
                if shouldTryContextServer {
                    add(&ordered, .deepl)
                    add(&ordered, preferred)
                }
                if TranslationEngine.isConfigured(.deepl) && supportsDeepL {
                    add(&ordered, .deepl)
                }
                if preferred != .server && preferred != .deepl && TranslationEngine.isConfigured(preferred) {
                    add(&ordered, preferred)
                }
                return ordered
            }
            var ordered: [TranslationEngine] = []
            if shouldTryContextServer {
                add(&ordered, .deepl)
            }
            add(&ordered, preferred)
            if TranslationEngine.isConfigured(.deepl) && supportsDeepL {
                add(&ordered, .deepl)
            }
            return ordered
        }()

        if forceSingleEngine {
            guard TranslationEngine.isConfigured(preferred) else {
                throw TranslationError.missingAPIKey
            }
            let strictEngine = attemptEngine(for: preferred)
            let strictContext = (preferred == .deepl || preferred == .server) ? requestContext : nil
            if let cached = loadCachedTranslation(strictEngine, contextKey: strictContext) {
                return cached
            }
            let strictBackoffKey = translationBackoffKey(
                engine: strictEngine,
                source: normalizedSource,
                target: normalizedTarget,
                textBucket: textBucket
            )
            guard await translationEngineBackoff.canAttempt(strictBackoffKey) else {
                throw TranslationError.timeout
            }
            let translated = try await performTranslateWithMetrics(
                engine: strictEngine,
                service: translator(for: preferred),
                requestContext: strictContext,
                backoffKey: strictBackoffKey
            )
            await inMemoryTranslationCache.store(
                key: inMemoryCacheKey,
                value: translated
            )
            return translated
        }

        var lastError: TranslationError?

        for engine in enginesToTry {
            guard TranslationEngine.isConfigured(engine) else { continue }
            let engineContext = (engine == .deepl || engine == .server) ? requestContext : nil
            let attemptEngine = attemptEngine(for: engine)
            if let cached = loadCachedTranslation(attemptEngine, contextKey: engineContext) {
                return cached
            }
            let attemptBackoffKey = translationBackoffKey(
                engine: attemptEngine,
                source: normalizedSource,
                target: normalizedTarget,
                textBucket: textBucket
            )
            if await translationEngineBackoff.canAttempt(attemptBackoffKey) == false {
                continue
            }
            let translator = translator(for: engine)
            do {
                let translated = try await performTranslateWithMetrics(
                    engine: attemptEngine,
                    service: translator,
                    requestContext: engineContext,
                    backoffKey: attemptBackoffKey
                )
                await inMemoryTranslationCache.store(
                    key: inMemoryCacheKey,
                    value: translated
                )
                return translated
            } catch let error as TranslationError {
                lastError = error
                if forceSingleEngine {
                    throw error
                }
                if shouldFallbackToSecondary(after: error) {
                    continue
                }
                throw error
            }
        }

        if let lastError {
            throw lastError
        }
        throw TranslationError.missingAPIKey
    }

    private func translationBackoffKey(
        engine: TranslationAttemptEngine,
        source: String,
        target: String,
        textBucket: Int
    ) -> String {
        "\(engine.rawValue)|\(source.lowercased())|\(target.lowercased())|\(textBucket)"
    }

    private func translationRetryAttempts(for engine: TranslationAttemptEngine, inputLength: Int, hasContext: Bool) -> Int {
        if engine == .koreanDict || engine == .myMemory {
            return 1
        }
        if engine == .contextServer {
            return inputLength >= 12 || hasContext ? 2 : 1
        }
        // DeepL usually gives good quality but benefits from one retry on transient faults,
        // especially for longer payloads.
        return inputLength >= 220 ? 3 : 2
    }

    private func shouldRetryTranslationError(
        _ error: TranslationError,
        engine: TranslationAttemptEngine,
        attempt: Int,
        maxAttempts: Int
    ) -> Bool {
        guard attempt + 1 < maxAttempts else { return false }
        switch engine {
        case .koreanDict, .myMemory, .googleTranslate:
            return false
        case .contextServer:
            switch error {
            case .timeout:
                return true
            case .httpError(let code, _):
                return code == 408 || code == 429
            case .invalidResponse, .missingAPIKey:
                return false
            }
        case .deepl:
            return shouldRetryTranslationError(error)
        }
    }

    private func translationRetryDelayMs(error: TranslationError, attempt: Int, engine: TranslationAttemptEngine) -> UInt64 {
        let base: UInt64
        switch error {
        case .timeout:
            base = 120
        case .httpError:
            base = 240
        case .invalidResponse, .missingAPIKey:
            base = 0
        }

        let engineFactor: UInt64
        switch engine {
        case .contextServer:
            engineFactor = 1
        case .deepl:
            engineFactor = 2
        case .myMemory, .koreanDict, .googleTranslate:
            engineFactor = 0
        }

        guard engineFactor > 0 else { return 0 }
        let cappedAttempt = min(attempt, 3)
        let exponentialDelay = min(base * (1 << cappedAttempt) * engineFactor, 2200)
        let jitter = UInt64.random(in: 0...max(40, exponentialDelay / 5))
        return exponentialDelay + jitter
    }

    private func loadUserDefinedTranslation(
        text: String,
        source: String,
        target: String
    ) -> String? {
        func normalizedLanguageKey(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.isEmpty == false, trimmed != "auto" else { return nil }
            return trimmed.split(separator: "-").first.map(String.init)
        }

        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
        if normalizedText.isEmpty { return nil }

        let sourceDetection = LanguageDetector.detect(normalizedText)
        let sourceLanguage = normalizedLanguageKey(sourceDetection.code == "und" ? source : sourceDetection.code)
        let targetLanguage = normalizedLanguageKey(target)
        let normalizedForLookup = LookupNormalizer.normalizeForLookup(
            text: normalizedText,
            detectedLanguage: sourceDetection
        ).selected
        let compact = normalizedForLookup.replacingOccurrences(of: " ", with: "")

        let tokenCount = normalizedText.split(whereSeparator: { $0.isWhitespace }).count
        if tokenCount > 4 || normalizedText.count > 64 {
            return nil
        }

        let candidates = compact.isEmpty ? [normalizedText, normalizedForLookup] : [normalizedText, normalizedForLookup, compact]
        for candidate in candidates where candidate.isEmpty == false {
            let entries = [
                candidate,
                candidate.lowercased()
            ]
            for entryKey in entries where entryKey.isEmpty == false {
                if let cached = VocabularyStore.shared.existingEntry(
                    word: entryKey,
                    bookId: nil,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                ) {
                    let meaning = cached.meaning
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if meaning.isEmpty { continue }
                    if isLikelyPlaceholderMeaning(meaning, inputText: text) { continue }
                    if hasExpectedScript(for: meaning, target: target) == false { continue }
                    return meaning
                }
            }
        }

        return nil
    }

    private func isLikelyPlaceholderMeaning(
        _ meaning: String,
        inputText: String
    ) -> Bool {
        let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("[translate]") { return true }
        if trimmed.hasPrefix("[en→") || trimmed.hasPrefix("[ko→") { return true }
        let normalizedInput = normalizedTextForTranslationComparison(normalizedText: inputText)
        let normalizedMeaning = normalizedTextForTranslationComparison(normalizedText: trimmed)
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { return true }
        return normalizedInput.isEmpty == false && normalizedInput == normalizedMeaning
    }

    private func shouldRejectTranslationOutput(
        source: String,
        output: String,
        sourceLang: String,
        targetLang: String
    ) -> Bool {
        guard source.isEmpty == false, output.isEmpty == false else { return true }
        if sourceLang == targetLang { return false }
        if sourceLang == "ko" && targetLang == "en" {
            if outputContainsLatin(output) == false { return true }
        } else if sourceLang == "en" && targetLang == "ko" {
            if outputContainsHangul(output) == false { return true }
        } else if targetLang.hasPrefix("ja") {
            if (outputContainsJapanese(output) == false && outputContainsHan(output) == false) { return true }
        } else if targetLang.hasPrefix("zh") {
            if outputContainsHan(output) == false { return true }
        }

        if hasEnoughMeaning(output) == false {
            return true
        }

        return false
    }

    private func normalizedTextForTranslationComparison(normalizedText: String) -> String {
        let sanitized = normalizedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: " ", with: "")
        let filteredScalars = sanitized.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar) &&
            !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    private func hasExpectedScript(for output: String, target: String) -> Bool {
        let normalizedTarget = normalizedLangCode(target)
        if normalizedTarget.isEmpty { return true }
        if normalizedTarget.hasPrefix("en") { return outputContainsLatin(output) }
        if normalizedTarget.hasPrefix("ko") { return outputContainsHangul(output) }
        if normalizedTarget.hasPrefix("ja") { return outputContainsJapanese(output) || outputContainsHan(output) }
        if normalizedTarget.hasPrefix("zh") { return outputContainsHan(output) }
        return true
    }

    private func outputContainsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7AF).contains(scalar.value) ||
            (0x1100...0x11FF).contains(scalar.value) ||
            (0x3130...0x318F).contains(scalar.value)
        }
    }

    private func outputContainsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x0041...0x007A).contains(value) ||
                (0x00C0...0x024F).contains(value) ||
                (0x1E00...0x1EFF).contains(value)
        }
    }

    private func outputContainsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x20000...0x2A6DF).contains(scalar.value)
        }
    }

    private func outputContainsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value) ||
            (0x31F0...0x31FF).contains(scalar.value)
        }
    }

    private func translateChunksConcurrently(
        chunks: [String],
        source: String,
        target: String,
        fallbackText: String,
        preferredEngine: TranslationEngine?,
        ignoreUserDefined: Bool = false
    ) async throws -> String {
        let sanitizedChunks = chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        if sanitizedChunks.isEmpty {
            throw TranslationError.invalidResponse
        }

        let chunkArray = Array(sanitizedChunks)
        let maxConcurrentChunks = 3
        var translatedChunks = Array<String?>(repeating: nil, count: chunkArray.count)
        var nextIndex = 0
        var runningTasks = 0
        var shouldFallback = false

        await withTaskGroup(of: (Int, String?).self) { group in
            func addNextTask() {
                guard nextIndex < chunkArray.count else { return }
                let index = nextIndex
                let chunkText = chunkArray[index]
                nextIndex += 1
                runningTasks += 1
                group.addTask { [source, target, preferredEngine] in
                    do {
                    let translated = try await self.translateSingleShot(
                        text: chunkText,
                        source: source,
                        target: target,
                        context: nil,
                        allowChunking: false,
                        preferredEngine: preferredEngine,
                        ignoreUserDefined: ignoreUserDefined
                    )
                    return (index, translated)
                } catch {
                    return (index, nil)
                }
                }
            }

            while nextIndex < chunkArray.count && runningTasks < maxConcurrentChunks {
                addNextTask()
            }

            while runningTasks > 0 {
                guard let result = await group.next() else { break }
                translatedChunks[result.0] = result.1
                runningTasks -= 1

                if result.1 == nil {
                    shouldFallback = true
                    group.cancelAll()
                    break
                }

                if nextIndex < chunkArray.count {
                    addNextTask()
                }
            }
        }

        if shouldFallback || translatedChunks.contains(where: { $0 == nil }) {
            let fallback = try await translateSingleShot(
                text: fallbackText,
                source: source,
                target: target,
                context: nil,
                allowChunking: false,
                preferredEngine: preferredEngine,
                ignoreUserDefined: ignoreUserDefined
            )
            if fallback.isEmpty == false {
                return fallback
            }
            throw TranslationError.invalidResponse
        }
        return translatedChunks.compactMap { $0 }.joined(separator: "\n\n")
    }

    private func normalizedLangCode(_ value: String) -> String {
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }

    private func normalizedTranslationLanguage(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if trimmed.hasPrefix("zh-hant") {
            return "zh-hant"
        }
        if trimmed.hasPrefix("zh-hans") {
            return "zh-hans"
        }
        return trimmed.split(separator: "-").first.map(String.init) ?? trimmed
    }

    private func hasMixedScripts(_ text: String) -> Bool {
        let families = Set(text.unicodeScalars.compactMap { scalar -> String? in
            switch scalar.value {
            case 0x0041...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
                return "latin"
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                return "ja"
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF:
                return "zh"
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                return "ko"
            default:
                return nil
            }
        })
        return families.count >= 2
    }

    private func resolvedSourceLanguage(source: String, text: String) async -> String {
        let normalized = normalizedTranslationLanguage(source)
        if normalized.isEmpty || normalized == "und" || normalized == "auto" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cacheKey = sourceLanguageCacheKey(source: normalized, text: trimmed)
            if let cached = await sourceLanguageCache.load(cacheKey) {
                return cached
            }

            if let hint = quickSourceLanguageHint(for: trimmed), hint != "en" {
                await sourceLanguageCache.store(cacheKey, value: hint)
                return hint
            }

            let detected = LanguageDetector.detectResult(trimmed)
            let detectedCode = normalizedTranslationLanguage(detected.language.code)
            let adjusted = LanguageConfidenceThreshold.adjusted(
                forLength: trimmed.count,
                confidence: detected.confidence
            )
            let resolved = if adjusted >= 0.56,
               detectedCode.isEmpty == false,
               detectedCode != "und" {
                detectedCode
            } else if let heuristic = quickSourceLanguageHint(for: trimmed) {
                heuristic
            } else if detectedCode.isEmpty == false && detectedCode != "und" {
                detectedCode
            } else if detected.confidence >= 0.35 && detectedCode.isEmpty == false {
                detectedCode
            } else {
                "en"
            }

            await sourceLanguageCache.store(cacheKey, value: resolved)
            return resolved
        }
        return normalized
    }

    private func sourceLanguageCacheKey(source: String, text: String) -> String {
        let normalizedText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let keyText = normalizedText.count > 160 ? String(normalizedText.prefix(160)) : normalizedText
        return "\(source):\(keyText)"
    }

    private func quickSourceLanguageHint(for text: String) -> String? {
        guard text.isEmpty == false else { return nil }

        var latinCount = 0
        var koreanCount = 0
        var japaneseKanaCount = 0
        var hanCount = 0
        var totalText = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            totalText += 1

            if (0x0041...0x007A).contains(value) || (0x00C0...0x024F).contains(value) || (0x1E00...0x1EFF).contains(value) {
                latinCount += 1
            }
            if (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value) {
                koreanCount += 1
            }
            if (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) {
                japaneseKanaCount += 1
            }
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x20000...0x2A6DF).contains(value) {
                hanCount += 1
            }
        }

        guard totalText > 0 else { return nil }

        let latinRatio = Double(latinCount) / Double(totalText)
        let koreanRatio = Double(koreanCount) / Double(totalText)
        let japaneseRatio = Double(japaneseKanaCount) / Double(totalText)
        let hanRatio = Double(hanCount) / Double(totalText)

        if koreanCount > 0 && (koreanRatio >= 0.04 || totalText <= 10) {
            return "ko"
        }
        if koreanCount > 0,
           totalText <= 12,
           japaneseRatio <= 0.08,
           hanRatio <= 0.25,
           latinRatio < 0.9 {
            return "ko"
        }
        if japaneseRatio > 0.2 {
            return "ja"
        }
        if hanRatio > 0.4 && japaneseRatio < 0.15 {
            let detectedChinese = LanguageDetector.detectResult(text).language
            switch detectedChinese {
            case .traditionalChinese:
                return "zh-hant"
            case .simplifiedChinese:
                return "zh-hans"
            default:
                return "zh"
            }
        }
        if latinRatio > 0.7 {
            return "en"
        }
        return nil
    }

    private func normalizedTranslationContext(_ context: String?) -> String? {
        guard var text = context?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if text.isEmpty { return nil }

        text = text
            .lowercased()
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(32)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : text
    }

    private func normalizeTranslationInput(_ text: String) -> String {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "-\n", with: "")

        normalized = normalized
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " )", with: ")")
            .replacingOccurrences(of: " (", with: "(")
            .replacingOccurrences(of: " : ", with: ": ")

        return normalized
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitTextForTranslation(_ text: String) -> [String] {
        let tokenCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let hasWhitespace = text.contains(where: { $0.isWhitespace || $0.isNewline })
        let tokenThreshold = hasWhitespace ? 36 : 80
        let characterThreshold = hasWhitespace ? 260 : 380

        if tokenCount <= tokenThreshold && text.count <= characterThreshold {
            return [text]
        }

        let maxChunkLength = hasWhitespace ? 220 : 160
        let sentenceBoundaries: Set<Character> = [".", "。", "!", "！", "?", "？", ";", "；", "\n"]
        let minChunkLengthBeforeBoundary = hasWhitespace ? 24 : 18

        var chunks: [String] = []
        var current = String()

        for character in text {
            current.append(character)

            if sentenceBoundaries.contains(character), current.count >= minChunkLengthBeforeBoundary {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    chunks.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
                continue
            }

            if current.count >= maxChunkLength,
               let splitIndex = current.lastIndex(where: { $0.isWhitespace }) {
                if splitIndex == current.index(before: current.endIndex) {
                    continue
                }
                let head = String(current[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tailStart = current.index(after: splitIndex)
                let tail = String(current[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

                if head.isEmpty == false {
                    chunks.append(head)
                    current = tail
                    continue
                }
            } else if current.count >= maxChunkLength {
                let splitIndex = current.index(current.startIndex, offsetBy: maxChunkLength)
                let head = String(current[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(current[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if head.isEmpty == false {
                    chunks.append(head)
                    current = tail
                }
            }
        }

        let trimmedTail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTail.isEmpty == false {
            chunks.append(trimmedTail)
        }

        return chunks.isEmpty ? [text] : chunks
    }

    private func chunkTranslationContext(
        requestContext: String?,
        rollingContext: String?
    ) -> String? {
        return compactChunkContext(for: [requestContext, rollingContext].compactMap { $0 })
    }

    private func combineChunkContext(current: String?, with chunkText: String) -> String? {
        return compactChunkContext(for: [current, chunkText].compactMap { $0 })
    }

    private func compactChunkContext(for pieces: [String]) -> String? {
        guard pieces.isEmpty == false else { return nil }
        let text = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .suffix(24)
            .joined(separator: " ")

        guard text.isEmpty == false else { return nil }
        return String(text.suffix(240))
    }

    private func translationTextBucket(for text: String) -> Int {
        let tokenCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let length = text.count
        if tokenCount <= 2 && length <= 12 { return 0 }
        if tokenCount <= 5 && length <= 48 { return 1 }
        if tokenCount <= 12 && length <= 160 { return 2 }
        return 3
    }

    private func translationErrorCode(from error: Error) -> Int? {
        guard let error = error as? TranslationError else { return nil }
        if case .httpError(let code, _) = error { return code }
        return nil
    }

    private func mapToTranslationError(_ error: Error) -> TranslationError {
        if let translationError = error as? TranslationError {
            return translationError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .cannotFindHost, .cannotLoadFromNetwork, .resourceUnavailable:
                return .timeout
            default:
                return .invalidResponse
            }
        }
        return .invalidResponse
    }

    private func shouldRetryTranslationError(_ error: TranslationError) -> Bool {
        switch error {
        case .timeout:
            return true
        case .httpError(let code, _):
            if code == 408 || code == 429 { return true }
            if (500..<600).contains(code) { return true }
            return false
        case .invalidResponse, .missingAPIKey:
            return false
        }
    }

    private func logAttemptTelemetry(
        source: String,
        target: String,
        engine: TranslationAttemptEngine,
        inputLength: Int,
        contextLength: Int,
        success: Bool,
        isNoop: Bool,
        isCached: Bool,
        latencyMs: Int,
        errorCode: Int?,
        text: String
    ) {
        let event = TranslationAttemptTelemetry(
            source: source,
            target: target,
            engine: engine,
            inputLength: inputLength,
            contextLength: contextLength,
            success: success,
            isNoop: isNoop,
            isCached: isCached,
            latencyMs: latencyMs,
            errorCode: errorCode,
            textBucket: translationTextBucket(for: text),
            recordedAt: Date().timeIntervalSince1970
        )
        Task {
            await TranslationTelemetryStore.shared.record(event)
        }
    }

    private func translator(for engine: TranslationEngine) -> TranslationServicing {
        switch engine {
        case .deepl:
            return contextDeeplServer
        case .server:
            return contextServer
        }
    }

    private func shouldPrioritizeDeepL(for text: String, source: String, target: String) -> Bool {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tgt = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !src.isEmpty, !tgt.isEmpty else { return false }
        guard src != tgt else { return false }
        guard DeepLLanguage.deeplCode(from: src) != nil,
              DeepLLanguage.deeplCode(from: tgt) != nil else { return false }

        let prioritizedLanguages: Set<String> = ["en", "ko", "ja", "zh", "es"]
        let srcSupported = prioritizedLanguages.contains { prefix in src.hasPrefix(prefix) }
        let tgtSupported = prioritizedLanguages.contains { prefix in tgt.hasPrefix(prefix) }
        let hasRelevantPair = srcSupported && tgtSupported
        guard hasRelevantPair else { return false }

        let tokenCount = text.split(whereSeparator: { $0.isWhitespace }).count
        return tokenCount >= 2 || text.count >= 28
    }

    private func canUseContextServer(
        source: String,
        target: String,
        context: String?
    ) -> Bool {
        guard ContextMeaningService.shared.isConfigured() else { return false }
        let normalizedSource = source.lowercased()
        guard normalizedSource.isEmpty == false else { return false }
        let normalizedTarget = target.lowercased()
        _ = context
        guard normalizedTarget.isEmpty == false else { return false }
        return true
    }

    private func isSupportedByDeepL(source: String, target: String) -> Bool {
        guard source.isEmpty == false, target.isEmpty == false else { return false }
        return DeepLLanguage.deeplCode(from: source) != nil &&
        DeepLLanguage.deeplCode(from: target) != nil
    }

    private func attemptEngine(for engine: TranslationEngine) -> TranslationAttemptEngine {
        switch engine {
        case .deepl: return .deepl
        case .server: return .contextServer
        }
    }
}

private actor InMemoryTranslationCache {
    private let maxItems = 500
    private var orderedKeys: [String] = []
    private var cache: [String: String] = [:]

    func load(key: String) async -> String? {
        guard let value = cache[key] else { return nil }
        promote(key)
        return value
    }

    func store(key: String, value: String) async {
        cache[key] = value
        promote(key)
        if cache.count > maxItems {
            let overflow = cache.count - maxItems
            if overflow > 0 {
                let removeKeys = orderedKeys.prefix(overflow)
                orderedKeys.removeFirst(overflow)
                for removeKey in removeKeys {
                    cache.removeValue(forKey: removeKey)
                }
            }
        }
    }

    private func promote(_ key: String) {
        orderedKeys.removeAll(where: { $0 == key })
        orderedKeys.append(key)
    }
}

private func inMemoryTranslationCacheKey(
    text: String,
    source: String,
    target: String,
    context: String?,
    preferredEngine: TranslationEngine?
) -> String {
    // text 정규화: 구두점·zero-width·하이픈 계열 통일 후 소문자
    let normalizedText = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\u{200B}", with: "")
        .replacingOccurrences(of: "\u{00AD}", with: "")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2013}", with: "-")
        .replacingOccurrences(of: "\u{2014}", with: "-")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()

    // context는 앞 20단어만 사용 (뒤쪽 문맥이 달라도 같은 단어 lookup 캐시 히트)
    let normalizedContext: String
    if let ctx = context?.trimmingCharacters(in: .whitespacesAndNewlines), ctx.isEmpty == false {
        let words = ctx
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(20)
            .map { $0.lowercased() }
        normalizedContext = words.joined(separator: " ")
    } else {
        normalizedContext = ""
    }

    var hasher = Hasher()
    hasher.combine(normalizedText)
    hasher.combine(source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    hasher.combine(target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    hasher.combine(normalizedContext)
    hasher.combine(preferredEngine?.rawValue ?? "auto")
    return String(hasher.finalize())
}

private func shouldFallbackToSecondary(after error: TranslationError) -> Bool {
    switch error {
    case .missingAPIKey:
        return true
    case .invalidResponse:
        return true
    case .timeout:
        return true
    case .httpError(let code, _):
        // Common cases during internal testing: quota/rate limits or transient server/network problems.
        if code == 401 || code == 403 || code == 408 || code == 429 { return true }
        if (500..<600).contains(code) { return true }
        return false
    }
}

private enum DeepLLanguage {
    static func deeplCode(from bcp47: String) -> String? {
        let raw = bcp47.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return nil }

        let lowered = raw.lowercased()
        let primary = lowered.split(separator: "-").first.map(String.init) ?? lowered
        let hasHant = lowered.contains("hant")
        let hasHans = lowered.contains("hans")

        switch primary {
        case "en": return "EN"
        case "ko": return "KO"
        case "ja": return "JA"
        case "es": return "ES"
        case "zh":
            if hasHant { return "ZH-HANT" }
            if hasHans { return "ZH-HANS" }
            return "ZH-HANS"
        default:
            // Extend as more languages are enabled in Settings.
            return nil
        }
    }
}

private enum FormURLEncoder {
    static func encode(_ params: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let pairs = params
            .sorted(by: { $0.key < $1.key })
            .map { key, value -> String in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(pairs.utf8)
    }
}

private struct DeepLTranslateResponse: Decodable {
    struct Translation: Decodable {
        let text: String
    }
    let translations: [Translation]
}

private struct DeepLErrorResponse: Decodable {
    let message: String?
}

private func shouldRetryNoopTranslation(input: String, output: String, source: String, target: String) -> Bool {
    let s = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let t = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s == t { return false }

    let a = normalizeNoopCompare(input)
    let b = normalizeNoopCompare(output)
    guard !a.isEmpty, !b.isEmpty else { return false }
    if areNumericContentOnly(a) && areNumericContentOnly(b) {
        return false
    }
    return a == b
}

private func normalizeNoopCompare(_ text: String) -> String {
    let cleaned = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "\u{00AD}", with: "")
        .replacingOccurrences(of: "\u{200B}", with: "")
    let filtered = cleaned.unicodeScalars.filter { scalar in
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        if CharacterSet.punctuationCharacters.contains(scalar) { return false }
        if CharacterSet.symbols.contains(scalar) { return false }
        if CharacterSet.controlCharacters.contains(scalar) { return false }
        return true
    }
    return String(String.UnicodeScalarView(filtered))
}

private func hasMeaningfulCharacters(_ text: String) -> Bool {
    var meaningfulCount = 0
    for scalar in text.unicodeScalars {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
            continue
        }
        if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
            continue
        }
        meaningfulCount += 1
        if meaningfulCount >= 2 { return true }
    }
    return meaningfulCount > 0
}

private func hasEnoughMeaning(_ text: String) -> Bool {
    let normalized = normalizeNoopCompare(text)
    if normalized.isEmpty { return false }
    if normalized.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
        return true
    }
    if normalized.count >= 2 { return true }
    guard normalized.count == 1,
          let scalar = normalized.unicodeScalars.first else { return false }
    let v = scalar.value
    return (0x4E00...0x9FFF).contains(v) ||
           (0x3400...0x4DBF).contains(v) ||
           (0x20000...0x2A6DF).contains(v) ||
           (0x3040...0x309F).contains(v) ||
           (0x30A0...0x30FF).contains(v) ||
           (0x31F0...0x31FF).contains(v) ||
           (0xAC00...0xD7AF).contains(v) ||
           (0x1100...0x11FF).contains(v) ||
           (0x3130...0x318F).contains(v) ||
           (0x0041...0x007A).contains(v) ||
           (0x00C0...0x024F).contains(v) ||
           (0x1E00...0x1EFF).contains(v)
}

private func areNumericContentOnly(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return false }
    return trimmed.unicodeScalars.allSatisfy { scalar in
        CharacterSet.decimalDigits.contains(scalar) ||
        CharacterSet.whitespacesAndNewlines.contains(scalar) ||
        CharacterSet.symbols.contains(scalar) ||
        CharacterSet.punctuationCharacters.contains(scalar)
    }
}

private func outputContainsHangul(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0xAC00...0xD7AF).contains(scalar.value) ||
        (0x1100...0x11FF).contains(scalar.value) ||
        (0x3130...0x318F).contains(scalar.value)
    }
}

private func outputContainsLatin(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        let value = scalar.value
        return (0x0041...0x007A).contains(value) ||
            (0x00C0...0x024F).contains(value) ||
            (0x1E00...0x1EFF).contains(value)
    }
}

private func outputContainsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x4E00...0x9FFF).contains(scalar.value) ||
        (0x3400...0x4DBF).contains(scalar.value) ||
        (0x20000...0x2A6DF).contains(scalar.value)
    }
}

private func outputContainsJapanese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3040...0x309F).contains(scalar.value) ||
        (0x30A0...0x30FF).contains(scalar.value) ||
        (0x31F0...0x31FF).contains(scalar.value)
    }
}

private func isLikelyLowQualityTranslation(
    input: String,
    output: String,
    sourceLang: String,
    targetLang: String
) -> Bool {
    if sourceLang == targetLang {
        return false
    }

    let normalizedInput = normalizeNoopCompare(input)
    let normalizedOutput = normalizeNoopCompare(output)

    guard normalizedInput.isEmpty == false,
          normalizedOutput.isEmpty == false else {
        return false
    }

    if normalizedInput.count >= 5 && normalizedOutput.count == 1 {
        return true
    }

    let ratio = Double(normalizedOutput.count) / Double(max(1, normalizedInput.count))
    if ratio < 0.12 || ratio > 16.0 {
        return true
    }

    if normalizedInput == normalizedOutput {
        return true
    }

    let dominantRatio = maxCharacterShare(normalizedOutput)
    if dominantRatio >= 0.74 && normalizedOutput.count >= 3 {
        return true
    }

    if sourceLang.hasPrefix("en") && targetLang.hasPrefix("ko") {
        if outputContainsLatin(output) && hasEnoughMeaning(output) == false {
            return true
        }
    }
    if sourceLang.hasPrefix("en") && targetLang.hasPrefix("es") && outputContainsLatin(output) == false {
        return true
    }
    if sourceLang.hasPrefix("zh") && targetLang.hasPrefix("en") && outputContainsLatin(output) == false {
        return true
    }
    if targetLang.hasPrefix("zh") && outputContainsHan(output) == false && outputContainsJapanese(output) == false {
        return true
    }
    if targetLang.hasPrefix("ja") && outputContainsJapanese(output) == false && outputContainsHan(output) == false {
        return true
    }

    let punctuationOnly = output.unicodeScalars.allSatisfy {
        CharacterSet.punctuationCharacters.contains($0) ||
        CharacterSet.symbols.contains($0) ||
        CharacterSet.whitespacesAndNewlines.contains($0)
    }
    if punctuationOnly {
        return true
    }

    let hasNonWhitespace = output.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) == false }
    if hasNonWhitespace == false {
        return true
    }

    if hasEnoughMeaning(output) == false && (targetLang.hasPrefix("zh") || targetLang.hasPrefix("ja") || targetLang.hasPrefix("ko")) {
        return true
    }

    return false
}

private func maxCharacterShare(_ text: String) -> Double {
    var counts: [UnicodeScalar: Int] = [:]
    for scalar in text.unicodeScalars {
        counts[scalar, default: 0] += 1
    }
    let totalScalars = text.unicodeScalars.count
    guard let maxCount = counts.values.max(), totalScalars > 0 else { return 0 }
    return Double(maxCount) / Double(totalScalars)
}

private enum LanguageConfidenceThreshold {
    static func adjusted(forLength length: Int, confidence: Double) -> Double {
        switch length {
        case 0..<5:
            return confidence * 0.65
        case 5..<10:
            return confidence * 0.78
        case 10..<24:
            return confidence * 0.9
        default:
            return confidence
        }
    }
}
