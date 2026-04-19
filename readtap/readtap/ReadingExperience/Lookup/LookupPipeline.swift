import CoreGraphics
import Foundation

enum LookupSource: String, Equatable {
  case textLayer
  case ocrProbe
  case ocrCache
  case fallback
}

enum LookupStage: String, Equatable {
  case instantFound
  case cacheMiss
  case ocrScheduled
  case resolved
  case translated
  case persisted
  case failed
}

typealias LookupSessionID = UInt64
typealias LookupSessionGeneration = Int

struct LookupSession {
  let id: LookupSessionID
  let generation: LookupSessionGeneration
  let location: CGPoint
  let pageIndex: Int
  let requestedId: LookupSessionID
  var source: LookupSource
  var stage: LookupStage
}

@MainActor
final class LookupSessionCoordinator {
  private var nextSessionId: LookupSessionID = 0
  private var nextGeneration: LookupSessionGeneration = 0
  private var sessions: [LookupSessionID: LookupSession] = [:]

  func startSession(
    location: CGPoint,
    pageIndex: Int,
    source: LookupSource,
    requestedId: LookupSessionID
  ) -> LookupSession {
    let sessionId = requestedId != 0 ? requestedId : nextSessionIdForFallback()
    nextGeneration += 1
    let session = LookupSession(
      id: sessionId,
      generation: nextGeneration,
      location: location,
      pageIndex: pageIndex,
      requestedId: requestedId,
      source: source,
      stage: .cacheMiss
    )
    sessions[sessionId] = session
    return session
  }

  private func nextSessionIdForFallback() -> LookupSessionID {
    nextSessionId &+= 1
    if nextSessionId == 0 {
      nextSessionId = 1
    }
    return nextSessionId
  }

  func updateSession(sessionId: LookupSessionID, stage: LookupStage, source: LookupSource) {
    guard var session = sessions[sessionId] else { return }
    session.stage = stage
    session.source = source
    sessions[sessionId] = session
  }

  func isCurrent(sessionId: LookupSessionID, generation: LookupSessionGeneration) -> Bool {
    guard let session = sessions[sessionId] else { return false }
    return session.generation == generation
  }

  func endCurrentIfNeeded(sessionId: LookupSessionID, generation: LookupSessionGeneration) {
    guard let session = sessions[sessionId], session.generation == generation else { return }
    sessions.removeValue(forKey: sessionId)
  }

  func cancelAllSessions() {
    sessions.removeAll()
  }
}
