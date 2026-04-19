import Foundation

struct LookupTraceEvent: Codable {
  let traceId: String?
  let word: String
  let source: String
  let target: String
  let engineRoute: String
  let candidateCount: Int
  let elapsedMs: Int
  let errorCode: String?
  let success: Bool
  let isMonolingual: Bool
  let isForce: Bool?
  let timestamp: TimeInterval
}

final class LookupTracker {
  static let shared = LookupTracker()
  private let fileName = "lookup-traces.ndjson"

  private init() {}

  func record(
    traceId: String? = nil,
    word: String,
    source: String,
    target: String,
    engineRoute: String,
    candidateCount: Int,
    elapsedMs: Int,
    errorCode: String? = nil,
    success: Bool,
    isMonolingual: Bool,
    isForce: Bool? = nil
  ) {
    #if !DEBUG
    return
    #endif
    let safeWord = word
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let event = LookupTraceEvent(
      traceId: traceId,
      word: safeWord,
      source: source,
      target: target,
      engineRoute: engineRoute,
      candidateCount: max(0, candidateCount),
      elapsedMs: max(0, elapsedMs),
      errorCode: errorCode?.trimmingCharacters(in: .whitespacesAndNewlines),
      success: success,
      isMonolingual: isMonolingual,
      isForce: isForce,
      timestamp: Date().timeIntervalSince1970
    )
    logToConsole(event)
    appendToFile(event)
  }

  private func logToConsole(_ event: LookupTraceEvent) {
    #if DEBUG
    let forceValue = event.isForce == true ? "Y" : "N"
    print(
      "[LookupTracker] traceId=\(event.traceId ?? "-") "
        + "word=\(event.word) source=\(event.source) target=\(event.target) "
        + "route=\(event.engineRoute) candidates=\(event.candidateCount) "
        + "elapsedMs=\(event.elapsedMs) success=\(event.success) "
        + "mono=\(event.isMonolingual) isForce=\(forceValue) "
        + "error=\(event.errorCode ?? "-")"
    )
    #endif
  }

  private func appendToFile(_ event: LookupTraceEvent) {
    guard let url = logFileURL(),
          let data = try? JSONEncoder().encode(event),
          let line = String(data: data, encoding: .utf8) else { return }
    let payload = "\(line)\n"
    if FileManager.default.fileExists(atPath: url.path) == false {
      FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
    }

    do {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      if let bytes = payload.data(using: .utf8) {
        handle.write(bytes)
      }
    } catch {
      #if DEBUG
      print("[LookupTracker] failed to append file trace error=\(error)")
      #endif
    }
  }

  private func logFileURL() -> URL? {
    guard
      let cachesDir = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    else { return nil }
    return cachesDir.appendingPathComponent(fileName)
  }
}
