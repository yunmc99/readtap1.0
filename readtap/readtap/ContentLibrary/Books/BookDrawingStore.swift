//
//  BookDrawingStore.swift
//  readtap
//
//  Created by 윤민채 on 2/6/26.
//

import Foundation

final class BookDrawingStore {
  static let shared = BookDrawingStore()

  private let queue = DispatchQueue(label: "BookDrawingStore.queue", qos: .utility)
  private var inMemoryCache: [String: [Int: Data]] = [:]
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private struct DrawingEntry: Codable {
    let pageIndex: Int
    let data: Data
  }

  private struct DrawingPayload: Codable {
    let entries: [DrawingEntry]
  }

  private init() {}

  func load(bookId: String) -> [Int: Data] {
    guard !bookId.isEmpty else { return [:] }
    return queue.sync {
      if let cached = inMemoryCache[bookId] {
        return cached
      }
      let loaded = readFromDisk(bookId: bookId)
      inMemoryCache[bookId] = loaded
      return loaded
    }
  }

  func save(bookId: String, pageIndex: Int, drawingData: Data?) {
    guard !bookId.isEmpty else { return }
    guard pageIndex >= 0 else { return }

    queue.async {
      var map = self.inMemoryCache[bookId] ?? self.readFromDisk(bookId: bookId)
      if let drawingData, !drawingData.isEmpty {
        map[pageIndex] = drawingData
      } else {
        map.removeValue(forKey: pageIndex)
      }
      self.inMemoryCache[bookId] = map
      self.writeToDisk(map, bookId: bookId)
    }
  }

  func deleteBook(bookId: String) {
    guard !bookId.isEmpty else { return }
    queue.async {
      self.inMemoryCache.removeValue(forKey: bookId)
      let url = self.fileURL(for: bookId)
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func drawingsDirectory() -> URL {
    let fm = FileManager.default
    let base =
      fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = base.appendingPathComponent("Drawings", isDirectory: true)
    if !fm.fileExists(atPath: dir.path) {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  private func fileURL(for bookId: String) -> URL {
    drawingsDirectory().appendingPathComponent("\(bookId).json")
  }

  private func readFromDisk(bookId: String) -> [Int: Data] {
    let url = fileURL(for: bookId)
    guard let data = try? Data(contentsOf: url) else { return [:] }
    guard let payload = try? decoder.decode(DrawingPayload.self, from: data) else { return [:] }
    var map: [Int: Data] = [:]
    payload.entries.forEach { map[$0.pageIndex] = $0.data }
    return map
  }

  private func writeToDisk(_ map: [Int: Data], bookId: String) {
    let entries = map.keys.sorted().compactMap { index -> DrawingEntry? in
      guard let data = map[index] else { return nil }
      return DrawingEntry(pageIndex: index, data: data)
    }
    let payload = DrawingPayload(entries: entries)
    guard let encoded = try? encoder.encode(payload) else { return }
    try? encoded.write(to: fileURL(for: bookId), options: [.atomic])
  }
}
