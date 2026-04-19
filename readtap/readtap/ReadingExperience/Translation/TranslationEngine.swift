import Foundation

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
