import Foundation

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
