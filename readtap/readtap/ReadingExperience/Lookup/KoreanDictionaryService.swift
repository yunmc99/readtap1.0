import Foundation
import Security

// MARK: - Data Model

struct KoreanDictionaryEntry: Decodable {
    let word: String
    let pos: String
    let definition: String
    let targetCode: Int
    /// All sense definitions for this item (includes `definition` as first element).
    let allDefinitions: [String]

    init(word: String, pos: String, definition: String, targetCode: Int, allDefinitions: [String] = []) {
        self.word = word
        self.pos = pos
        self.definition = definition
        self.targetCode = targetCode
        self.allDefinitions = allDefinitions.isEmpty ? [definition] : allDefinitions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        pos = try container.decode(String.self, forKey: .pos)
        definition = try container.decode(String.self, forKey: .definition)
        targetCode = try container.decode(Int.self, forKey: .targetCode)
        let decoded = try container.decodeIfPresent([String].self, forKey: .allDefinitions) ?? []
        allDefinitions = decoded.isEmpty ? [definition] : decoded
    }

    private enum CodingKeys: String, CodingKey {
        case word, pos, definition, targetCode, allDefinitions
    }
}

// MARK: - Keychain Store

enum KoreanDictKeyStore {
    private static let service = "readtap.krdict"
    private static let account = "apiKey"
    private static let embeddedInfoKey = "KoreanDictionaryAPIKey"

    static func currentKey() -> String? {
        load() ?? embeddedKey()
    }

    static func isConfigured() -> Bool {
        (currentKey()?.isEmpty == false)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { return false }

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

    private static func embeddedKey() -> String? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: embeddedInfoKey) as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Dictionary Service

final class KoreanDictionaryService {
    static let shared = KoreanDictionaryService()
    private init() {}

    static func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        ContextMeaningService.shared.isConfigured(defaults: defaults) || KoreanDictKeyStore.isConfigured()
    }

    enum DictError: Error, LocalizedError {
        case noAPIKey
        case invalidResponse
        case networkError(Error)
        case noResults
        case apiError(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "API key not configured"
            case .invalidResponse: return "Invalid response"
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .noResults: return "No results found"
            case .apiError(let code, let message): return "API error (\(code)): \(message)"
            }
        }
    }

    func lookup(_ word: String) async throws -> [KoreanDictionaryEntry] {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictError.invalidResponse }

        if ContextMeaningService.shared.isConfigured() {
            do {
                let entries = try await ContextMeaningService.shared.fetchKoreanDictionaryEntries(word: trimmed)
                guard entries.isEmpty == false else { throw DictError.noResults }
                return entries
            } catch let error as ContextMeaningError {
                if KoreanDictKeyStore.isConfigured() == false {
                    throw mapContextError(error)
                }
            } catch {
                if KoreanDictKeyStore.isConfigured() == false {
                    throw DictError.networkError(error)
                }
            }
        }

        guard let apiKey = KoreanDictKeyStore.currentKey(), !apiKey.isEmpty else {
            throw DictError.noAPIKey
        }

        return try await lookupDirect(trimmed, apiKey: apiKey)
    }

    private func lookupDirect(_ word: String, apiKey: String) async throws -> [KoreanDictionaryEntry] {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictError.invalidResponse }

        var components = URLComponents(string: "https://krdict.korean.go.kr/api/search")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "num", value: "10"),
            URLQueryItem(name: "sort", value: "popular"),
            URLQueryItem(name: "part", value: "word"),
            URLQueryItem(name: "method", value: "exact")
        ]
        guard let url = components.url else { throw DictError.invalidResponse }

        let data = try await fetchData(from: url)

        let entries = KRDictXMLParser.parse(data: data)
        guard !entries.isEmpty else {
            // Retry with prefix match if exact match found nothing.
            return try await lookupPrefix(trimmed, apiKey: apiKey)
        }
        return entries
    }

    private func lookupPrefix(_ word: String, apiKey: String) async throws -> [KoreanDictionaryEntry] {
        var components = URLComponents(string: "https://krdict.korean.go.kr/api/search")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "q", value: word),
            URLQueryItem(name: "num", value: "10"),
            URLQueryItem(name: "sort", value: "popular"),
            URLQueryItem(name: "part", value: "word"),
            URLQueryItem(name: "method", value: "include")
        ]
        guard let url = components.url else { throw DictError.invalidResponse }

        let data = try await fetchData(from: url)

        let entries = KRDictXMLParser.parse(data: data)
        guard !entries.isEmpty else { throw DictError.noResults }
        return entries
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (compatible; ReadTap/1.0; +https://readtap.app)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml,text/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DictError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DictError.invalidResponse
        }

        // Check for API error XML (returns HTTP 200 with <error> body)
        if let apiError = KRDictErrorParser.parse(data: data) {
            throw DictError.apiError(code: apiError.code, message: apiError.message)
        }

        return data
    }

    // MARK: - Subword Suggestions (복합어 분해)

    /// When the full word has no results, try progressively shorter substrings
    /// from the front and back to find the closest dictionary matches.
    /// Returns up to `limit` unique entries, ordered by longest match first.
    func lookupSubwordSuggestions(_ word: String, limit: Int = 4) async -> [KoreanDictionaryEntry] {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let chars = Array(trimmed)
        var seen = Set<String>()
        var results: [KoreanDictionaryEntry] = []

        // Generate substrings: front-shrink + back-shrink, longest first
        // e.g. "농어촌학생" → front: "농어촌학", "농어촌", "농어"
        //                    back: "어촌학생", "촌학생", "학생"
        var candidates: [(String, Int)] = []  // (substring, length for sorting)
        for len in stride(from: chars.count - 1, through: 2, by: -1) {
            let front = String(chars.prefix(len))
            candidates.append((front, len))
            let back = String(chars.suffix(len))
            if back != front {
                candidates.append((back, len))
            }
        }
        // Sort by length descending (longer = more specific = better match)
        candidates.sort { $0.1 > $1.1 }

        // Run lookups concurrently in small batches for speed
        await withTaskGroup(of: (String, [KoreanDictionaryEntry]).self) { group in
            for (sub, _) in candidates {
                guard !seen.contains(sub) else { continue }
                seen.insert(sub)
                group.addTask { [weak self] in
                    guard let self else { return (sub, []) }
                    do {
                        let entries = try await self.lookup(sub)
                        // Only keep entries where the headword exactly matches the substring
                        let exact = entries.filter { $0.word == sub }
                        return (sub, exact.isEmpty ? [] : Array(exact.prefix(1)))
                    } catch {
                        return (sub, [])
                    }
                }
            }
            // Collect results preserving candidate order
            var resultMap: [String: [KoreanDictionaryEntry]] = [:]
            for await (sub, entries) in group {
                if !entries.isEmpty {
                    resultMap[sub] = entries
                }
            }
            // Re-order by original candidate ordering
            var addedWords = Set<String>()
            for (sub, _) in candidates {
                if let entries = resultMap[sub] {
                    for entry in entries where !addedWords.contains(entry.word) {
                        results.append(entry)
                        addedWords.insert(entry.word)
                        if results.count >= limit { return }
                    }
                }
            }
        }

        return results
    }

    private func mapContextError(_ error: ContextMeaningError) -> DictError {
        switch error {
        case .notConfigured:
            return .noAPIKey
        case .invalidURL, .invalidResponse:
            return .invalidResponse
        case .httpError(_, let message):
            return .apiError(code: "server", message: message ?? "server error")
        }
    }
}

// MARK: - Error XML Parser

private final class KRDictErrorParser: NSObject, XMLParserDelegate {
    struct APIError {
        let code: String
        let message: String
    }

    private var inError = false
    private var currentElement = ""
    private var buffer = ""
    private var errorCode = ""
    private var errorMessage = ""

    static func parse(data: Data) -> APIError? {
        let delegate = KRDictErrorParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard !delegate.errorCode.isEmpty else { return nil }
        return APIError(code: delegate.errorCode, message: delegate.errorMessage)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        buffer = ""
        if elementName == "error" { inError = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if inError {
            switch elementName {
            case "error_code": errorCode = text
            case "message": errorMessage = text
            case "error": inError = false
            default: break
            }
        }
    }
}

// MARK: - XML Parser

private final class KRDictXMLParser: NSObject, XMLParserDelegate {

    private var entries: [KoreanDictionaryEntry] = []

    // Current item state
    private var inItem = false
    private var inSense = false
    private var currentElement = ""
    private var currentWord = ""
    private var currentPos = ""
    private var currentDefinition = ""
    private var currentAllDefinitions: [String] = []
    private var currentTargetCode = 0
    private var buffer = ""

    static func parse(data: Data) -> [KoreanDictionaryEntry] {
        let delegate = KRDictXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName
        buffer = ""

        if elementName == "item" {
            inItem = true
            currentWord = ""
            currentPos = ""
            currentDefinition = ""
            currentAllDefinitions = []
            currentTargetCode = 0
        } else if elementName == "sense" && inItem {
            inSense = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "item" {
            if !currentWord.isEmpty, !currentDefinition.isEmpty {
                entries.append(KoreanDictionaryEntry(
                    word: currentWord,
                    pos: currentPos,
                    definition: currentDefinition,
                    targetCode: currentTargetCode,
                    allDefinitions: currentAllDefinitions
                ))
            }
            inItem = false
        } else if elementName == "sense" {
            inSense = false
        } else if inItem {
            switch elementName {
            case "word":
                currentWord = text.replacingOccurrences(of: "-", with: "")
            case "pos":
                currentPos = text
            case "target_code":
                currentTargetCode = Int(text) ?? 0
            case "definition":
                if inSense, !text.isEmpty {
                    currentAllDefinitions.append(text)
                    if currentDefinition.isEmpty {
                        currentDefinition = text
                    }
                }
            default:
                break
            }
        }

        currentElement = ""
    }
}
