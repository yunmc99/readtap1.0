import SwiftUI
import Combine

enum SynonymPlacement: String, CaseIterable {
    case back    // 뒷면 (기본) — 뜻과 함께
    case front   // 앞면 — 힌트로 활용
    case hidden  // 숨김 — 뜻만 표시
}

enum PopupSizeMode: String, CaseIterable {
    case compact
    case normal
    case large

    var scale: CGFloat {
        switch self {
        case .compact: return 0.74
        case .normal: return 0.88
        case .large: return 1.0
        }
    }
}

enum HighlightColorPreset: String, CaseIterable, Identifiable {
    case themeDefault
    case yellow
    case peach
    case lavender
    case mint
    case skyBlue
    case coral

    var id: String { rawValue }

    var hexValue: String? {
        switch self {
        case .themeDefault: return nil
        case .yellow:   return "#FFD60A"
        case .peach:    return "#FFAC8E"
        case .lavender: return "#C4B5FD"
        case .mint:     return "#6EE7B7"
        case .skyBlue:  return "#7DD3FC"
        case .coral:    return "#FB7185"
        }
    }

    var displayColor: Color {
        guard let hex = hexValue else {
            return ReaderRefinedPalette.savedHighlightColor.opacity(0.9)
        }
        return Color(uiColor: UIColor(highlightHex: hex) ?? .systemYellow).opacity(0.9)
    }

    func localizedName(_ lang: AppLanguage) -> String {
        let isKo = lang == .korean
        switch self {
        case .themeDefault: return isKo ? "테마 기본" : "Theme"
        case .yellow:   return isKo ? "노랑"  : "Yellow"
        case .peach:    return isKo ? "피치"  : "Peach"
        case .lavender: return isKo ? "라벤더" : "Lavender"
        case .mint:     return isKo ? "민트"  : "Mint"
        case .skyBlue:  return isKo ? "하늘"  : "Sky"
        case .coral:    return isKo ? "코랄"  : "Coral"
        }
    }
}

/// Centralized app-wide settings observed by all views via @EnvironmentObject.
/// Replaces the 46+ scattered @AppStorage("libraryTheme") and 13+ @AppStorage("appLanguage") declarations.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published private(set) var theme: LibraryTheme
    @Published private(set) var language: AppLanguage
    @Published private(set) var autoSaveEnabled: Bool
    @Published private(set) var highlightOnSaveEnabled: Bool
    @Published private(set) var readerLongPressEnabled: Bool
    @Published private(set) var translationSource: String
    @Published private(set) var translationTarget: String
    @Published private(set) var secondaryTranslationTarget: String
    @Published private(set) var wordPopupSizeMode: PopupSizeMode
    @Published private(set) var readerVisualStyleMode: ReaderVisualStyleMode
    @Published private(set) var customHighlightColorHex: String?
    @Published private(set) var dailyWordGoal: Int
    @Published private(set) var dailyMinuteGoal: Int
    @Published private(set) var synonymPlacement: SynonymPlacement
    @Published private(set) var pronunciationRate: Double

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let rawTheme = UserDefaults.standard.string(forKey: "libraryTheme")
        let resolvedTheme = LibraryTheme.current(from: rawTheme)
        if rawTheme != resolvedTheme.rawValue {
            UserDefaults.standard.set(resolvedTheme.rawValue, forKey: "libraryTheme")
        }
        theme = resolvedTheme

        language = AppLanguage.current()
        autoSaveEnabled = UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true
        highlightOnSaveEnabled = UserDefaults.standard.object(forKey: "highlightOnSaveEnabled") as? Bool ?? true
        readerLongPressEnabled = UserDefaults.standard.object(forKey: "readerLongPressEnabled") as? Bool ?? true
        translationSource = TranslationSource.resolved(from: UserDefaults.standard.string(forKey: "translationSource")).rawValue
        translationTarget = UserDefaults.standard.string(forKey: "translationTarget") ?? TranslationTarget.auto.rawValue
        secondaryTranslationTarget = UserDefaults.standard.string(forKey: "secondaryTranslationTarget") ?? "en"
        let rawPopupSize = UserDefaults.standard.string(forKey: "wordPopupSizeMode") ?? PopupSizeMode.normal.rawValue
        wordPopupSizeMode = PopupSizeMode(rawValue: rawPopupSize) ?? .normal
        let rawReaderVisualStyle = UserDefaults.standard.string(forKey: ReaderVisualStyleMode.storageKey)
        let resolvedReaderVisualStyle = ReaderVisualStyleMode.resolved(from: rawReaderVisualStyle)
        if rawReaderVisualStyle != resolvedReaderVisualStyle.rawValue {
            UserDefaults.standard.set(resolvedReaderVisualStyle.rawValue, forKey: ReaderVisualStyleMode.storageKey)
        }
        readerVisualStyleMode = resolvedReaderVisualStyle
        customHighlightColorHex = UserDefaults.standard.string(forKey: "customHighlightColorHex")
        dailyWordGoal = UserDefaults.standard.object(forKey: "dailyWordGoal") as? Int ?? 30
        dailyMinuteGoal = UserDefaults.standard.object(forKey: "dailyMinuteGoal") as? Int ?? 10
        let rawSynPlacement = UserDefaults.standard.string(forKey: "synonymPlacement") ?? SynonymPlacement.back.rawValue
        synonymPlacement = SynonymPlacement(rawValue: rawSynPlacement) ?? .back
        pronunciationRate = Self.clampedPronunciationRate(
            UserDefaults.standard.object(forKey: PronunciationPlayer.rateStorageKey) as? Double
        )

        // Observe UserDefaults so external writes (e.g. SettingsView via @AppStorage) propagate here too.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let newTheme = LibraryTheme.current(from: UserDefaults.standard.string(forKey: "libraryTheme"))
                if self.theme != newTheme { self.theme = newTheme }

                let newLanguage = AppLanguage.current()
                if self.language != newLanguage { self.language = newLanguage }

                let newAutoSave = UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true
                if self.autoSaveEnabled != newAutoSave { self.autoSaveEnabled = newAutoSave }

                let newHighlightOnSave = UserDefaults.standard.object(forKey: "highlightOnSaveEnabled") as? Bool ?? true
                if self.highlightOnSaveEnabled != newHighlightOnSave { self.highlightOnSaveEnabled = newHighlightOnSave }

                let newLongPress = UserDefaults.standard.object(forKey: "readerLongPressEnabled") as? Bool ?? true
                if self.readerLongPressEnabled != newLongPress { self.readerLongPressEnabled = newLongPress }

                let newSource = TranslationSource.resolved(from: UserDefaults.standard.string(forKey: "translationSource")).rawValue
                if self.translationSource != newSource { self.translationSource = newSource }

                let newTarget = UserDefaults.standard.string(forKey: "translationTarget") ?? TranslationTarget.auto.rawValue
                if self.translationTarget != newTarget { self.translationTarget = newTarget }

                let newSecondaryTarget = UserDefaults.standard.string(forKey: "secondaryTranslationTarget") ?? "en"
                if self.secondaryTranslationTarget != newSecondaryTarget { self.secondaryTranslationTarget = newSecondaryTarget }

                let newPopupSize = UserDefaults.standard.string(forKey: "wordPopupSizeMode") ?? PopupSizeMode.normal.rawValue
                let resolvedPopupSize = PopupSizeMode(rawValue: newPopupSize) ?? .normal
                if self.wordPopupSizeMode != resolvedPopupSize { self.wordPopupSizeMode = resolvedPopupSize }

                let newReaderVisualStyle = ReaderVisualStyleMode.resolved(
                    from: UserDefaults.standard.string(forKey: ReaderVisualStyleMode.storageKey)
                )
                if self.readerVisualStyleMode != newReaderVisualStyle {
                    self.readerVisualStyleMode = newReaderVisualStyle
                }

                let newHighlightHex = UserDefaults.standard.string(forKey: "customHighlightColorHex")
                if self.customHighlightColorHex != newHighlightHex {
                    self.customHighlightColorHex = newHighlightHex
                }

                let newSynPlacement = SynonymPlacement(rawValue: UserDefaults.standard.string(forKey: "synonymPlacement") ?? "") ?? .back
                if self.synonymPlacement != newSynPlacement { self.synonymPlacement = newSynPlacement }

                let newRate = Self.clampedPronunciationRate(
                    UserDefaults.standard.object(forKey: PronunciationPlayer.rateStorageKey) as? Double
                )
                if self.pronunciationRate != newRate { self.pronunciationRate = newRate }
            }
            .store(in: &cancellables)
    }

    private static func clampedPronunciationRate(_ raw: Double?) -> Double {
        let value = raw ?? PronunciationPlayer.defaultRate
        return max(PronunciationPlayer.minRate, min(PronunciationPlayer.maxRate, value))
    }

    var wordPopupScale: CGFloat {
        wordPopupSizeMode.scale
    }

    // MARK: - Setters (write back to UserDefaults so @AppStorage stays in sync)

    func setTheme(_ newTheme: LibraryTheme) {
        UserDefaults.standard.set(newTheme.rawValue, forKey: "libraryTheme")
        theme = newTheme
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        UserDefaults.standard.set(newLanguage.rawValue, forKey: "appLanguage")
        language = newLanguage
    }

    func setAutoSave(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "autoSaveEnabled")
        autoSaveEnabled = enabled
    }

    func setHighlightOnSave(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "highlightOnSaveEnabled")
        highlightOnSaveEnabled = enabled
    }

    func setReaderLongPress(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "readerLongPressEnabled")
        readerLongPressEnabled = enabled
    }

    func setTranslationSource(_ source: String) {
        let normalized = TranslationSource.resolved(from: source).rawValue
        UserDefaults.standard.set(normalized, forKey: "translationSource")
        translationSource = normalized
    }

    func setTranslationTarget(_ target: String) {
        UserDefaults.standard.set(target, forKey: "translationTarget")
        translationTarget = target
    }

    func setSecondaryTranslationTarget(_ target: String) {
        UserDefaults.standard.set(target, forKey: "secondaryTranslationTarget")
        secondaryTranslationTarget = target
    }

    func setWordPopupSizeMode(_ mode: PopupSizeMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "wordPopupSizeMode")
        wordPopupSizeMode = mode
    }

    func setReaderVisualStyleMode(_ mode: ReaderVisualStyleMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ReaderVisualStyleMode.storageKey)
        readerVisualStyleMode = mode
    }

    func setCustomHighlightColor(_ hex: String?) {
        if let hex {
            UserDefaults.standard.set(hex, forKey: "customHighlightColorHex")
        } else {
            UserDefaults.standard.removeObject(forKey: "customHighlightColorHex")
        }
        customHighlightColorHex = hex
    }

    func setDailyWordGoal(_ goal: Int) {
        let clamped = max(5, min(200, goal))
        UserDefaults.standard.set(clamped, forKey: "dailyWordGoal")
        dailyWordGoal = clamped
    }

    func setDailyMinuteGoal(_ goal: Int) {
        let clamped = max(5, min(120, goal))
        UserDefaults.standard.set(clamped, forKey: "dailyMinuteGoal")
        dailyMinuteGoal = clamped
    }

    func setSynonymPlacement(_ placement: SynonymPlacement) {
        UserDefaults.standard.set(placement.rawValue, forKey: "synonymPlacement")
        synonymPlacement = placement
    }

    func setPronunciationRate(_ rate: Double) {
        let clamped = Self.clampedPronunciationRate(rate)
        PronunciationPlayer.setRate(clamped)
        pronunciationRate = clamped
    }

    var selectedHighlightPreset: HighlightColorPreset {
        guard let hex = customHighlightColorHex else { return .themeDefault }
        return HighlightColorPreset.allCases.first { $0.hexValue == hex } ?? .themeDefault
    }

}
