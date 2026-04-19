import CoreGraphics
import Foundation

struct MappedWord: Identifiable {
  let id: UUID
  let text: String
  let rect: CGRect
  let normalizedRect: CGRect
}

struct OCRWord: Identifiable {
  let id = UUID()
  let text: String
  let boundingBox: CGRect
  let confidence: Float

  init(text: String, boundingBox: CGRect, confidence: Float = 0.55) {
    self.text = text
    self.boundingBox = boundingBox
    self.confidence = confidence
  }
}
