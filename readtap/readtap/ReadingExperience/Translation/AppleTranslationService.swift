import Foundation
import Translation

/// On-device translation using Apple's Translation framework (iOS 18.0+).
@available(iOS 18.0, *)
final class AppleTranslationService {
  static let shared = AppleTranslationService()
  private init() {}

  /// Posted when a translation model needs to be downloaded.
  /// `userInfo` contains "source" and "target" language codes.
  static let modelDownloadNeeded = Notification.Name("AppleTranslationModelDownloadNeeded")

  /// Translate a word/phrase using Apple's on-device translation engine.
  func translate(
    text: String,
    source: String,
    target: String
  ) async throws -> String {
    #if DEBUG
    print("[AppleTranslation] start wordLen=\(text.count) source=\(source) target=\(target)")
    #endif
    let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else {
      #if DEBUG
      print("[AppleTranslation] failed: word is empty")
      #endif
      throw TranslationError.invalidResponse
    }

    let srcLocale = resolveLocale(source)
    let tgtLocale = resolveLocale(target)
    guard srcLocale.language.languageCode != tgtLocale.language.languageCode else {
      #if DEBUG
      print("[AppleTranslation] same language requested; return baseline word")
      #endif
      return word
    }

    let availability = LanguageAvailability()
    let status = await availability.status(
      from: srcLocale.language,
      to: tgtLocale.language
    )
    #if DEBUG
    print("[AppleTranslation] limit status: \(status)")
    #endif

    #if targetEnvironment(simulator)
    // In the Simulator, Apple Translation models are often not installed/supported.
    // We'll bypass the strict check here to allow network-based or mocked translations to attempt anyway.
    if status == .unsupported {
        #if DEBUG
        print("[AppleTranslation] Bypassing unsupported status check in Simulator")
        #endif
    } else {
        guard status == .installed || status == .supported else {
          #if DEBUG
          print("[AppleTranslation] failed: status is not installed or supported. status=\(status)")
          #endif
          throw TranslationError.invalidResponse
        }
    }
    #else
    guard status == .installed || status == .supported else {
      #if DEBUG
      print("[AppleTranslation] failed: status is not installed or supported. status=\(status)")
      #endif
      throw TranslationError.invalidResponse
    }
    #endif

    do {
      guard #available(iOS 26.0, *) else { throw TranslationError.invalidResponse }
      let session = TranslationSession(
        installedSource: srcLocale.language,
        target: tgtLocale.language
      )
      let response = try await session.translate(word)
      let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
      
      guard !translated.isEmpty else {
        #if DEBUG
        print("[AppleTranslation] failed: translated result is empty")
        #endif
        throw TranslationError.invalidResponse
      }
      return translated
    } catch {
      #if DEBUG
      print("[AppleTranslation] system error: \(error)")
      #endif
      // If model not installed, notify so the reader can show download prompt
      if "\(error)".contains("notInstalled") {
        await MainActor.run {
          NotificationCenter.default.post(
            name: AppleTranslationService.modelDownloadNeeded,
            object: nil,
            userInfo: ["source": source, "target": target]
          )
        }
      }
      throw error
    }
  }

  /// Prevents the first translation attempt from freezing the main thread by initializing a dummy TranslationSession.
  func prime() async {
    let srcLocale = resolveLocale("en")
    let tgtLocale = resolveLocale("ko")
    if #available(iOS 17.4, *) {
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: srcLocale.language,
            to: tgtLocale.language
        )
        if status == .installed || status == .supported {
            if #available(iOS 26.0, *) {
                _ = TranslationSession(
                    installedSource: srcLocale.language,
                    target: tgtLocale.language
                )
            }
        }
    }
  }

  /// Check if Apple Translation supports the given language pair.
  func isAvailable(source: String, target: String) async -> Bool {
    let srcLocale = resolveLocale(source)
    let tgtLocale = resolveLocale(target)
    guard srcLocale.language.languageCode != tgtLocale.language.languageCode else {
      return false
    }

    let availability = LanguageAvailability()
    let status = await availability.status(
      from: srcLocale.language,
      to: tgtLocale.language
    )
    return status == .installed || status == .supported
  }

  private func resolveLocale(_ langCode: String) -> Locale {
    let normalized = langCode
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    switch normalized {
    case "ko": return Locale(identifier: "ko-KR")
    case "en": return Locale(identifier: "en-US")
    case "ja": return Locale(identifier: "ja-JP")
    case "zh", "zh-hans": return Locale(identifier: "zh-Hans")
    case "zh-hant": return Locale(identifier: "zh-Hant")
    case "es": return Locale(identifier: "es-ES")
    default:
      if normalized.isEmpty || normalized == "und" || normalized == "auto" {
        return Locale(identifier: "en-US")
      }
      return Locale(identifier: normalized)
    }
  }
}
