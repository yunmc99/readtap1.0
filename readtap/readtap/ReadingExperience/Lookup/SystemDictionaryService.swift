import Foundation

#if canImport(UIKit)
import UIKit
#endif

final class SystemDictionaryService {
  static let shared = SystemDictionaryService()

  private init() {}

  func hasDefinition(for term: String) -> Bool {
    let normalized = term
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard normalized.isEmpty == false else { return false }

    #if canImport(UIKit)
    return UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: normalized)
    #else
    return false
    #endif
  }

  func fallbackNotice(for term: String) -> String {
    let normalized = term
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false else {
      return "사전 조회를 완료하지 못했어요."
    }

    #if canImport(UIKit)
    if hasDefinition(for: normalized) {
      return "이 단어는 iOS 내장 사전에 정의되어 있습니다. 시스템 사전에서 확인해 보세요."
    }
    #endif

    return "사전 조회를 완료하지 못했어요. 영문 단어를 정확히 다시 선택해 보세요."
  }
}
