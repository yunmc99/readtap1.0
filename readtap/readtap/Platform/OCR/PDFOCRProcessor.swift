//
//  PDFOCRProcessor.swift
//  readtap
//
//  Extracted from ContentView.swift
//

import Accelerate
import CoreImage
import Foundation
@preconcurrency import PDFKit
import UIKit
import Vision

struct PDFOCRWord: Identifiable, Codable {
  let id = UUID()
  let text: String
  let pageRect: CGRect
  let pageIndex: Int

  private enum CodingKeys: String, CodingKey {
    case text
    case pageRect
    case pageIndex
  }
}

enum PDFOCRProcessor {
  /// Serial queue dedicated to PDF page rasterization.
  /// Keeps rendering off the main thread so the UI stays responsive during OCR.
  fileprivate static let renderQueue = DispatchQueue(
    label: "com.readtap.pdfrenderqueue",
    qos: .userInitiated
  )

  private struct RenderedPage {
    let image: UIImage
    let scale: CGFloat
    let pageBounds: CGRect
    let quality: OCRRenderQuality
  }

  private struct OCRPageResult {
    let words: [PDFOCRWord]
    let averageConfidence: Float
  }

  enum OCRRenderQuality: Int {
    case quick = 0
    case normal = 1
    case retry = 2

    var cacheBucket: Int {
      switch self {
      case .quick: return 0
      case .normal: return 1
      case .retry: return 2
      }
    }

    var targetMinDimension: CGFloat {
      switch self {
      case .quick: return 900
      case .normal: return 1500
      case .retry: return 1900
      }
    }

    var minScale: CGFloat {
      switch self {
      case .quick: return 0.8
      case .normal: return 1.0
      case .retry: return 1.3
      }
    }

    var maxScale: CGFloat {
      switch self {
      case .quick: return 1.3
      case .normal: return 2.2
      case .retry: return 2.6
      }
    }
  }

  private final class CachedRenderedPage: NSObject {
    let image: UIImage
    let scale: CGFloat
    let pageBounds: CGRect
    let quality: OCRRenderQuality

    init(image: UIImage, scale: CGFloat, pageBounds: CGRect, quality: OCRRenderQuality) {
      self.image = image
      self.scale = scale
      self.pageBounds = pageBounds
      self.quality = quality
    }
  }

  private static let renderedPageCache: NSCache<NSString, CachedRenderedPage> = {
    let cache = NSCache<NSString, CachedRenderedPage>()
    cache.countLimit = 12
    cache.totalCostLimit = 128 * 1024 * 1024
    return cache
  }()
  static func clearRenderedPageCache() {
    renderedPageCache.removeAllObjects()
  }
  private static let ciContext = CIContext(options: nil)
  private static let inFlight = PDFOCRRecognitionCoalescer()
  private static let renderMaxScale: CGFloat = 2.6
  private static let renderGate = OCRRenderSlotGate()

  static func recognizeWords(
    page: PDFPage,
    pageIndex: Int,
    languages: [String],
    allowBinarization: Bool = true,
    allowAdaptiveRetry: Bool = true,
    quality: OCRRenderQuality = .normal
  ) async -> [PDFOCRWord] {
    let normalizedLanguages = normalizedOCRLanguages(languages)
    guard normalizedLanguages.isEmpty == false else { return [] }

    let requestKey = ocrRequestKey(page: page, pageIndex: pageIndex, languages: languages)
    return await inFlight.run(requestKey) {
      await recognizeWordsCore(
        page: page,
        pageIndex: pageIndex,
        languages: normalizedLanguages,
        allowBinarization: allowBinarization,
        allowAdaptiveRetry: allowAdaptiveRetry,
        quality: quality
      )
    }
  }

  private static func recognizeWordsCore(
    page: PDFPage,
    pageIndex: Int,
    languages: [String],
    allowBinarization: Bool,
    allowAdaptiveRetry: Bool,
    quality: OCRRenderQuality
  ) async -> [PDFOCRWord] {
    let cacheKey = renderedPageCacheKey(for: page, quality: quality)
    let thermalState = ProcessInfo.processInfo.thermalState
    let recognitionLevel: VNRequestTextRecognitionLevel =
      (thermalState == .serious || thermalState == .critical) ? .fast : .accurate

    if let cached = renderedPageCache.object(forKey: cacheKey) {
      if let cachedCI = CIImage(image: cached.image) {
        let preprocessed = preprocess(cachedCI)
        let ocrSourceRect =
          detectTextContentRect(in: preprocessed) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let (recognitionImage, effectiveSourceRect) = cropIfNeeded(
          preprocessed, sourceRect: ocrSourceRect)

        let resultA = recognize(
          on: recognitionImage,
          pageIndex: pageIndex,
          pageBounds: cached.pageBounds,
          imageSize: preprocessed.extent.size,
          sourceRect: effectiveSourceRect,
          scale: cached.scale,
          languages: languages,
          recognitionLevel: recognitionLevel
        )
        if isHighConfidence(resultA) {
          return resultA.words
        }

        guard allowBinarization else { return resultA.words }
        let binarized = binarize(recognitionImage)
        let shouldRunBinarizedPass =
          recognitionLevel == .accurate || resultA.words.isEmpty || resultA.averageConfidence < 0.6
        if shouldRunBinarizedPass {
          let resultB = recognize(
            on: binarized,
            pageIndex: pageIndex,
            pageBounds: cached.pageBounds,
            imageSize: preprocessed.extent.size,
            sourceRect: effectiveSourceRect,
            scale: cached.scale,
            languages: languages,
            recognitionLevel: recognitionLevel
          )
          return score(resultA) >= score(resultB) ? resultA.words : resultB.words
        }

        return resultA.words
      }
    }

    await renderGate.acquire(for: quality)
    defer {
      Task { await renderGate.release(for: quality) }
    }

    guard let rendered = await renderPageImage(page: page, quality: quality) else {
      return []
    }
    cacheRenderedPage(rendered, for: page, quality: quality)

    guard let baseCI = CIImage(image: rendered.image) else {
      return []
    }

    let preprocessed = preprocess(baseCI)
    let ocrSourceRect =
      detectTextContentRect(in: preprocessed) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    let (recognitionImage, effectiveSourceRect) = cropIfNeeded(
      preprocessed, sourceRect: ocrSourceRect)
    let resultA = recognize(
      on: recognitionImage,
      pageIndex: pageIndex,
      pageBounds: rendered.pageBounds,
      imageSize: preprocessed.extent.size,
      sourceRect: effectiveSourceRect,
      scale: rendered.scale,
      languages: languages,
      recognitionLevel: recognitionLevel
    )
    if isHighConfidence(resultA) {
      return resultA.words
    }

    let binarized = binarize(recognitionImage)
    let shouldRunBinarizedPass =
      recognitionLevel == .accurate || resultA.words.isEmpty || resultA.averageConfidence < 0.6
    let resultB: OCRPageResult
    if shouldRunBinarizedPass {
      resultB = recognize(
        on: binarized,
        pageIndex: pageIndex,
        pageBounds: rendered.pageBounds,
        imageSize: preprocessed.extent.size,
        sourceRect: effectiveSourceRect,
        scale: rendered.scale,
        languages: languages,
        recognitionLevel: recognitionLevel
      )
    } else {
      resultB = resultA
    }

    var best = score(resultA) >= score(resultB) ? resultA : resultB
    let preferredImage: CIImage = score(resultB) > score(resultA) ? binarized : recognitionImage
    let canRunAdaptiveRetries =
      allowAdaptiveRetry
      && (ProcessInfo.processInfo.thermalState == .nominal
        || ProcessInfo.processInfo.thermalState == .fair)
    let canRunAdaptiveRetriesForResult = best.words.count <= 1000

    // If mixed-language recognition was attempted and result is weak, retry with alternate plans.
    if canRunAdaptiveRetries && canRunAdaptiveRetriesForResult
      && shouldRetryWithAdaptiveLanguage(best, languages: languages)
    {
      let retryLanguagePlans = deduplicatedLanguagePlans(
        OCRTuning.adaptiveLanguagePlans(
          for: languages, sampleText: OCRTuningText.joinText(best.words)),
        excluding: languages
      )
      let useBinarizedSecond = best.words.count < 30
      let secondaryImage = score(resultB) > score(resultA) ? recognitionImage : binarized
      let retryImages: [CIImage] =
        useBinarizedSecond ? [preferredImage, secondaryImage] : [preferredImage]
      let maxLanguagePlans = useBinarizedSecond ? 2 : 1
      var attempts = 0

      for retryLanguages in retryLanguagePlans where attempts < maxLanguagePlans {
        attempts += 1
        for image in retryImages {
          let retryResult = recognize(
            on: image,
            pageIndex: pageIndex,
            pageBounds: rendered.pageBounds,
            imageSize: preprocessed.extent.size,
            sourceRect: effectiveSourceRect,
            scale: rendered.scale,
            languages: retryLanguages,
            recognitionLevel: .accurate
          )

          if score(retryResult) > score(best) {
            best = retryResult
          }

          if isHighQualityOCRResult(best) {
            break
          }
        }
        if isHighQualityOCRResult(best) || isHighConfidence(best) {
          break
        }
      }
    }

    return best.words
  }

  private static func ocrRequestKey(page: PDFPage, pageIndex: Int, languages: [String]) -> String {
    let normalizedLanguages = normalizeLanguagePlan(languages)
    let documentKey = ObjectIdentifier(page.document ?? page).hashValue
    return
      "doc|\(documentKey)|page|\(pageIndex)|langs|\(normalizedLanguages.joined(separator: ","))"
  }

  private static func renderedPageCacheKey(for page: PDFPage, quality: OCRRenderQuality) -> NSString
  {
    let documentKey = ObjectIdentifier(page.document ?? page).hashValue
    let pageIndex = page.document?.index(for: page) ?? -1
    let cropBox = page.bounds(for: .cropBox)
    let mediaBox = page.bounds(for: .mediaBox)
    let usedBox = (cropBox.isEmpty || cropBox == mediaBox) ? mediaBox : cropBox
    return
      "\(documentKey)|\(pageIndex)|\(Int(usedBox.width))x\(Int(usedBox.height))|\(Int(usedBox.minX)),\(Int(usedBox.minY))|\(quality.cacheBucket)"
      as NSString
  }

  private static func cacheRenderedPage(
    _ rendered: RenderedPage, for page: PDFPage, quality: OCRRenderQuality
  ) {
    let key = renderedPageCacheKey(for: page, quality: quality)
    let cost = Int(rendered.image.size.width * rendered.image.size.height * 4)
    renderedPageCache.setObject(
      CachedRenderedPage(
        image: rendered.image, scale: rendered.scale, pageBounds: rendered.pageBounds,
        quality: rendered.quality),
      forKey: key,
      cost: max(1, cost)
    )
  }

  private static func normalizeLanguagePlan(_ languages: [String]) -> [String] {
    let normalized =
      languages
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
      .sorted()
      .reduce(into: Set<String>()) { unique, lang in
        _ = unique.insert(lang)
      }
    return Array(normalized).sorted()
  }

  private static func normalizedOCRLanguages(_ languages: [String]) -> [String] {
    let normalized = normalizeLanguagePlan(languages)
    return normalized.isEmpty ? OCRTuning.currentRecognitionLanguages() : normalized
  }

  private struct OCRTuningText {
    static func joinText(_ words: [PDFOCRWord]) -> String {
      return words.map(\.text).joined(separator: " ")
    }
  }

  private static func isHighConfidence(_ result: OCRPageResult) -> Bool {
    if result.words.count >= 130 {
      return result.averageConfidence >= 0.42
    }
    if result.words.count >= 70 {
      return result.averageConfidence >= 0.58
    }
    if result.words.count >= 30 {
      return result.averageConfidence >= 0.75
    }
    return false
  }

  private static func isHighQualityOCRResult(_ result: OCRPageResult) -> Bool {
    guard !result.words.isEmpty else { return false }
    if result.words.count <= 12 {
      return result.averageConfidence >= 0.92
    }
    if result.words.count <= 30 {
      return result.averageConfidence >= 0.88
    }
    if result.words.count <= 60 {
      return result.averageConfidence >= 0.75
    }
    if result.words.count >= 220 {
      return result.averageConfidence >= 0.46
    }
    if result.words.count >= 120 {
      return result.averageConfidence >= 0.58
    }
    if result.words.count >= 60 {
      return result.averageConfidence >= 0.72
    }
    return false
  }

  private static func shouldRetryWithAdaptiveLanguage(_ result: OCRPageResult, languages: [String])
    -> Bool
  {
    guard hasAtLeastTwoScriptFamilies(languages) || result.words.isEmpty else { return false }
    guard !isHighConfidence(result) else { return false }
    if isHighQualityOCRResult(result) { return false }

    let words = result.words.count
    switch words {
    case 0...8:
      return result.averageConfidence < 0.9
    case 9...30:
      return result.averageConfidence < 0.8
    case 31...90:
      return result.averageConfidence < 0.65
    case 91...180:
      return result.averageConfidence < 0.5
    default:
      return result.averageConfidence < 0.45
    }
  }

  private static func languagePlanKey(_ languages: [String]) -> String {
    return normalizeLanguagePlan(languages).joined(separator: ",")
  }

  private static func deduplicatedLanguagePlans(
    _ plans: [[String]], excluding baseLanguages: [String]
  ) -> [[String]] {
    let baseKey = languagePlanKey(baseLanguages)
    var seen: Set<String> = [baseKey]
    var out: [[String]] = []

    for plan in plans {
      let normalized = normalizeLanguagePlan(plan)
      let key = languagePlanKey(normalized)
      if normalized.isEmpty || seen.contains(key) { continue }
      seen.insert(key)
      out.append(normalized)
    }
    return out
  }

  private static func hasAtLeastTwoScriptFamilies(_ languages: [String]) -> Bool {
    let families = Set(
      languages.compactMap { language -> String? in
        if language.hasPrefix("en") { return "en" }
        if language.hasPrefix("ko") { return "ko" }
        if language.hasPrefix("ja") { return "ja" }
        if language.hasPrefix("zh") { return "zh" }
        return nil
      })
    return families.count >= 2
  }

  private static func renderPageImage(page: PDFPage, quality: OCRRenderQuality) async
    -> RenderedPage?
  {
    // Step 1: gather geometry on main thread (PDFKit requires it).
    // Use cropBox so OCR coordinates match pdfView.convert() which uses cropBox.
    let (pageBounds, scale, cropBoxOffset): (CGRect, CGFloat, CGPoint) = await MainActor.run {
      let cropBox = page.bounds(for: .cropBox)
      let mediaBox = page.bounds(for: .mediaBox)
      let useCropBox = !cropBox.isEmpty && cropBox != mediaBox
      let bounds = useCropBox ? cropBox : mediaBox
      let offset = useCropBox ? CGPoint(x: cropBox.minX, y: cropBox.minY) : .zero
      let minDim = max(1, min(bounds.width, bounds.height))
      let thermalState = ProcessInfo.processInfo.thermalState
      let targetMin = quality.targetMinDimension
      let baseMaxScale =
        thermalState == .serious || thermalState == .critical
        ? min(renderMaxScale, 1.7) : quality.maxScale
      let maxScale = min(baseMaxScale, quality.maxScale)
      let minScale = max(quality.minScale, 0.75)
      let s = min(maxScale, max(minScale, targetMin / minDim))
      return (bounds, s, offset)
    }

    let targetSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
    guard targetSize.width > 0, targetSize.height > 0 else { return nil }

    // Step 2: render on a dedicated background queue so the main thread is free.
    // PDFPage.draw(with:to:) is thread-safe when called with a CGContext that is
    // not shared with the main thread, and UIGraphicsImageRenderer is safe off-main
    // as long as we don't touch UIKit views.
    return await withCheckedContinuation { continuation in
      PDFOCRProcessor.renderQueue.async {
        // Force 1x scale so image.size matches pixel dimensions exactly.
        // This ensures normalizedToImageRect produces correct pixel coords
        // (Vision normalizes relative to pixel dimensions, not point dimensions).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let drawBox: PDFDisplayBox = cropBoxOffset == .zero ? .mediaBox : .cropBox
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let image = renderer.image { ctx in
          UIColor.white.setFill()
          ctx.fill(CGRect(origin: .zero, size: targetSize))
          ctx.cgContext.saveGState()
          ctx.cgContext.translateBy(x: 0, y: targetSize.height)
          ctx.cgContext.scaleBy(x: scale, y: -scale)
          page.draw(with: drawBox, to: ctx.cgContext)
          ctx.cgContext.restoreGState()
        }
        continuation.resume(
          returning: RenderedPage(image: image, scale: scale, pageBounds: pageBounds, quality: quality)
        )
      }
    }
  }

  private actor OCRRenderSlotGate {
    private var inFlight: [Int: Int] = [
      OCRRenderQuality.quick.rawValue: 0,
      OCRRenderQuality.normal.rawValue: 0,
      OCRRenderQuality.retry.rawValue: 0,
    ]
    private let maxConcurrent: [Int: Int] = [
      OCRRenderQuality.quick.rawValue: 2,
      OCRRenderQuality.normal.rawValue: 2,
      OCRRenderQuality.retry.rawValue: 1,
    ]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [
      OCRRenderQuality.quick.rawValue: [],
      OCRRenderQuality.normal.rawValue: [],
      OCRRenderQuality.retry.rawValue: [],
    ]

    private func key(_ quality: OCRRenderQuality) -> Int {
      quality.rawValue
    }

    func acquire(for quality: OCRRenderQuality) async {
      let k = key(quality)
      if let current = inFlight[k], let limit = maxConcurrent[k], current < limit {
        inFlight[k] = current + 1
        return
      }

      await withCheckedContinuation { continuation in
        waiters[k, default: []].append(continuation)
      }
    }

    func release(for quality: OCRRenderQuality) {
      let k = key(quality)
      let current = max(0, (inFlight[k] ?? 0) - 1)
      inFlight[k] = current
      guard let limit = maxConcurrent[k],
        current < limit,
        var queued = waiters[k],
        queued.isEmpty == false
      else {
        return
      }
      let next = queued.removeFirst()
      waiters[k] = queued
      inFlight[k] = current + 1
      next.resume()
    }
  }

  private static func preprocess(_ image: CIImage) -> CIImage {
    var output = image
    output = output.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputSaturationKey: 0.0,
        kCIInputContrastKey: 1.15,
        kCIInputBrightnessKey: 0.02,
      ])
    output = output.applyingFilter(
      "CIHighlightShadowAdjust",
      parameters: [
        "inputShadowAmount": 1.0,
        "inputHighlightAmount": 0.2,
      ])
    output = normalizeBackground(output)
    output = output.applyingFilter(
      "CIGammaAdjust",
      parameters: [
        "inputPower": 0.9
      ])
    output = output.applyingFilter(
      "CISharpenLuminance",
      parameters: [
        "inputSharpness": 0.45
      ])
    output = output.applyingFilter(
      "CINoiseReduction",
      parameters: [
        "inputNoiseLevel": 0.01,
        "inputSharpness": 0.4,
      ])
    return output
  }

  private static func binarize(_ image: CIImage) -> CIImage {
    guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
      return image
    }
    if let thresholded = adaptiveThresholdedCGImage(from: cgImage) {
      return CIImage(cgImage: thresholded)
    }
    return image
  }

  private static func recognize(
    on image: CIImage,
    pageIndex: Int,
    pageBounds: CGRect,
    imageSize: CGSize,
    sourceRect: CGRect,
    scale: CGFloat,
    languages: [String],
    recognitionLevel: VNRequestTextRecognitionLevel = .accurate
  ) -> OCRPageResult {
    var items: [PDFOCRWord] = []
    var confidenceTotal: Float = 0
    var confidenceCount: Int = 0

    let request = VNRecognizeTextRequest { request, _ in
      guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
      for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }
        confidenceTotal += candidate.confidence
        confidenceCount += 1
        items.append(
          contentsOf: words(
            from: candidate,
            pageIndex: pageIndex,
            pageBounds: pageBounds,
            imageSize: imageSize,
            scale: scale,
            fallbackBox: observation.boundingBox,
            sourceRect: sourceRect
          ))
      }
    }

    OCRTuning.configure(
      request,
      minimumTextHeight: 0.006,
      languages: languages,
      recognitionLevel: recognitionLevel
    )

    let handler = VNImageRequestHandler(ciImage: image, options: [:])
    try? handler.perform([request])

    let averageConfidence = confidenceCount > 0 ? (confidenceTotal / Float(confidenceCount)) : 0
    let deduped = dedupe(items)
    return OCRPageResult(words: deduped, averageConfidence: averageConfidence)
  }

  private static func words(
    from candidate: VNRecognizedText,
    pageIndex: Int,
    pageBounds: CGRect,
    imageSize: CGSize,
    scale: CGFloat,
    fallbackBox: CGRect,
    sourceRect: CGRect
  ) -> [PDFOCRWord] {
    let text = candidate.string
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    guard !tokens.isEmpty else { return [] }

    var items: [PDFOCRWord] = []
    var searchStart = text.startIndex
    for token in tokens {
      guard let range = text.range(of: token, range: searchStart..<text.endIndex) else { continue }
      let cleaned = String(token).trimmingCharacters(in: ocrTrimCharacters)
      if cleaned.isEmpty {
        searchStart = range.upperBound
        continue
      }

      let normalizedBox: CGRect
      if let rectObservation = try? candidate.boundingBox(for: range) {
        normalizedBox = rectObservation.boundingBox
      } else {
        normalizedBox = fallbackBox
      }

      let mappedNormalized = mapNormalizedRect(normalizedBox, in: sourceRect)
      let imageRect = normalizedToImageRect(mappedNormalized, imageSize: imageSize)
      let pageRect = imageRectToPageRect(
        imageRect,
        imageHeight: imageSize.height,
        pageBounds: pageBounds,
        scale: scale
      )

      items.append(PDFOCRWord(text: cleaned, pageRect: pageRect, pageIndex: pageIndex))
      searchStart = range.upperBound
    }
    return items
  }

  private static let ocrTrimCharacters: CharacterSet = {
    var set = CharacterSet.punctuationCharacters
    set.formUnion(.symbols)
    set.formUnion(.whitespacesAndNewlines)
    return set
  }()

  private static func normalizedToImageRect(_ normalized: CGRect, imageSize: CGSize) -> CGRect {
    let finite =
      normalized.origin.x.isFinite
      && normalized.origin.y.isFinite
      && normalized.size.width.isFinite
      && normalized.size.height.isFinite
      && imageSize.width > 0
      && imageSize.height > 0

    guard finite else {
      return .zero
    }

    guard normalized.width.isFinite,
      normalized.height.isFinite,
      normalized.minX.isFinite,
      normalized.minY.isFinite
    else {
      return .zero
    }

    let w = normalized.width * imageSize.width
    let h = normalized.height * imageSize.height
    let x = normalized.minX * imageSize.width
    let y = (1 - normalized.maxY) * imageSize.height
    return CGRect(x: x, y: y, width: w, height: h)
  }

  private static func mapNormalizedRect(_ rect: CGRect, in sourceRect: CGRect) -> CGRect {
    let rectFinite =
      rect.origin.x.isFinite
      && rect.origin.y.isFinite
      && rect.size.width.isFinite
      && rect.size.height.isFinite
      && sourceRect.origin.x.isFinite
      && sourceRect.origin.y.isFinite
      && sourceRect.size.width.isFinite
      && sourceRect.size.height.isFinite
    guard rectFinite else { return .zero }
    guard sourceRect.width.isFinite,
      sourceRect.height.isFinite,
      sourceRect.width > 0,
      sourceRect.height > 0
    else {
      return rect
    }
    guard sourceRect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return rect }
    let x = sourceRect.minX + rect.minX * sourceRect.width
    let y = sourceRect.minY + rect.minY * sourceRect.height
    let maxX = min(1, x + rect.width * sourceRect.width)
    let maxY = min(1, y + rect.height * sourceRect.height)
    return CGRect(
      x: max(0, x),
      y: max(0, y),
      width: max(0, maxX - max(0, x)),
      height: max(0, maxY - max(0, y))
    )
  }

  private static func cropIfNeeded(_ image: CIImage, sourceRect: CGRect) -> (CIImage, CGRect) {
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard sourceRect != unit else { return (image, unit) }
    let extent = image.extent
    let width = sourceRect.width * extent.width
    let height = sourceRect.height * extent.height
    guard width >= 160, height >= 160 else { return (image, unit) }

    let cropRect = CGRect(
      x: extent.minX + extent.width * sourceRect.minX,
      y: extent.minY + extent.height * sourceRect.minY,
      width: width,
      height: height
    ).integral
    guard cropRect.width >= 120, cropRect.height >= 120 else { return (image, unit) }
    return (image.cropped(to: cropRect), sourceRect)
  }

  private static func detectTextContentRect(in image: CIImage) -> CGRect? {
    var textRects: [CGRect] = []
    let request = VNDetectTextRectanglesRequest { request, _ in
      guard let observations = request.results as? [VNTextObservation] else { return }
      textRects = observations.map { $0.boundingBox }
    }
    request.reportCharacterBoxes = false
    let handler = VNImageRequestHandler(ciImage: image, options: [:])
    try? handler.perform([request])
    guard textRects.isEmpty == false else { return nil }

    var minX: CGFloat = 1
    var minY: CGFloat = 1
    var maxX: CGFloat = 0
    var maxY: CGFloat = 0
    for rect in textRects {
      let expanded = rect.insetBy(dx: -0.02, dy: -0.02)
      minX = min(minX, expanded.minX)
      minY = min(minY, expanded.minY)
      maxX = max(maxX, expanded.maxX)
      maxY = max(maxY, expanded.maxY)
    }

    let width = maxX - minX
    let height = maxY - minY
    guard width < 0.96 || height < 0.96 else { return nil }
    guard width >= 0.07 && height >= 0.07 else { return nil }
    return CGRect(
      x: max(0, min(1, minX)),
      y: max(0, min(1, minY)),
      width: max(0, min(1, maxX) - max(0, min(1, minX))),
      height: max(0, min(1, maxY) - max(0, min(1, minY)))
    )
  }

  private static func imageRectToPageRect(
    _ rect: CGRect,
    imageHeight: CGFloat,
    pageBounds: CGRect,
    scale: CGFloat
  ) -> CGRect {
    let rectFinite =
      rect.origin.x.isFinite
      && rect.origin.y.isFinite
      && rect.size.width.isFinite
      && rect.size.height.isFinite
      && pageBounds.origin.x.isFinite
      && pageBounds.origin.y.isFinite
      && pageBounds.size.width.isFinite
      && pageBounds.size.height.isFinite

    guard rectFinite,
      imageHeight.isFinite,
      imageHeight > 0,
      scale.isFinite,
      scale > 0
    else {
      return .zero
    }

    let pageX = pageBounds.minX + rect.minX / scale
    let pageY = pageBounds.minY + (imageHeight - rect.maxY) / scale
    return CGRect(x: pageX, y: pageY, width: rect.width / scale, height: rect.height / scale)
  }

  private static func score(_ result: OCRPageResult) -> Float {
    let countScore = Float(result.words.count)
    let confidenceScore = max(result.averageConfidence, 0.2)
    return countScore * confidenceScore
  }

  private static func dedupe(_ words: [PDFOCRWord]) -> [PDFOCRWord] {
    guard words.isEmpty == false else { return [] }
    let trimmedWords =
      words.count > 2200
      ? Array(words.prefix(2200))
      : words
    var deduped: [PDFOCRWord] = []
    deduped.reserveCapacity(min(trimmedWords.count, 2200))
    var byTextIndexes: [String: [Int]] = [:]

    for word in trimmedWords {
      let normalized = word.text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: .punctuationCharacters)
        .lowercased()
      guard normalized.isEmpty == false else { continue }

      if let indexes = byTextIndexes[normalized] {
        var duplicate = false
        for index in indexes {
          if iou(deduped[index].pageRect, word.pageRect) > 0.82 {
            if word.text.count > deduped[index].text.count {
              deduped[index] = word
            }
            duplicate = true
            break
          }
        }
        if duplicate { continue }
      }

      byTextIndexes[normalized, default: []].append(deduped.count)
      deduped.append(word)
    }

    let maxResultWords = 2600
    guard deduped.count > maxResultWords else { return deduped }
    return Array(deduped.prefix(maxResultWords))
  }

  private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    if intersection.isNull || intersection.isEmpty { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = (a.width * a.height) + (b.width * b.height) - intersectionArea
    return unionArea > 0 ? intersectionArea / unionArea : 0
  }

  private static func normalizeBackground(_ image: CIImage) -> CIImage {
    let blurred = image.applyingFilter(
      "CIBoxBlur",
      parameters: [
        "inputRadius": 12.0
      ])

    if let filter = CIFilter(name: "CIDivideBlendMode") {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(blurred, forKey: kCIInputBackgroundImageKey)
      if let output = filter.outputImage {
        return output.cropped(to: image.extent)
      }
    }

    if let filter = CIFilter(name: "CIColorDodgeBlendMode") {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(blurred, forKey: kCIInputBackgroundImageKey)
      if let output = filter.outputImage {
        return output.cropped(to: image.extent)
      }
    }

    return image
  }

  private static func adaptiveThresholdedCGImage(from image: CGImage, t: Float = 0.2) -> CGImage? {
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    var format = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      colorSpace: Unmanaged.passUnretained(rgbColorSpace),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)
        .union(.byteOrder32Big),
      version: 0,
      decode: nil,
      renderingIntent: .defaultIntent
    )

    var srcBuffer = vImage_Buffer()
    var error = vImageBuffer_InitWithCGImage(
      &srcBuffer,
      &format,
      nil,
      image,
      vImage_Flags(kvImageNoFlags)
    )
    guard error == kvImageNoError else { return nil }
    defer {
      free(srcBuffer.data)
    }

    var grayBuffer = vImage_Buffer()
    error = vImageBuffer_Init(
      &grayBuffer,
      srcBuffer.height,
      srcBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    guard error == kvImageNoError else { return nil }
    defer {
      free(grayBuffer.data)
    }

    let divisor: Int32 = 1000
    let coefficients: [Int16] = [213, 715, 72, 0]
    vImageMatrixMultiply_ARGB8888ToPlanar8(
      &srcBuffer,
      &grayBuffer,
      coefficients,
      divisor,
      nil,
      0,
      vImage_Flags(kvImageNoFlags)
    )

    var eqBuffer = vImage_Buffer()
    let eqError = vImageBuffer_Init(
      &eqBuffer,
      grayBuffer.height,
      grayBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    if eqError == kvImageNoError {
      vImageEqualization_Planar8(&grayBuffer, &eqBuffer, vImage_Flags(kvImageNoFlags))
    }
    var sourceBuffer = eqError == kvImageNoError ? eqBuffer : grayBuffer
    defer {
      if eqError == kvImageNoError {
        free(eqBuffer.data)
      }
    }

    let width = Int(sourceBuffer.width)
    let height = Int(sourceBuffer.height)
    let kernel = adaptiveKernelSize(width: width, height: height)

    var meanBuffer = vImage_Buffer()
    let meanError = vImageBuffer_Init(
      &meanBuffer,
      sourceBuffer.height,
      sourceBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    guard meanError == kvImageNoError else { return nil }
    defer {
      free(meanBuffer.data)
    }

    vImageBoxConvolve_Planar8(
      &sourceBuffer,
      &meanBuffer,
      nil,
      0,
      0,
      UInt32(kernel),
      UInt32(kernel),
      0,
      vImage_Flags(kvImageEdgeExtend)
    )

    var binaryBuffer = vImage_Buffer()
    error = vImageBuffer_Init(
      &binaryBuffer,
      sourceBuffer.height,
      sourceBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    guard error == kvImageNoError else { return nil }
    defer {
      free(binaryBuffer.data)
    }

    let srcRowBytes = sourceBuffer.rowBytes
    let meanRowBytes = meanBuffer.rowBytes
    let dstRowBytes = binaryBuffer.rowBytes
    let srcPtr = sourceBuffer.data.bindMemory(to: UInt8.self, capacity: srcRowBytes * height)
    let meanPtr = meanBuffer.data.bindMemory(to: UInt8.self, capacity: meanRowBytes * height)
    let dstPtr = binaryBuffer.data.bindMemory(to: UInt8.self, capacity: dstRowBytes * height)
    for y in 0..<height {
      let srcRow = srcPtr.advanced(by: y * srcRowBytes)
      let meanRow = meanPtr.advanced(by: y * meanRowBytes)
      let dstRow = dstPtr.advanced(by: y * dstRowBytes)
      for x in 0..<width {
        let pixel = Float(srcRow[x])
        let mean = Float(meanRow[x])
        let threshold = mean * (1.0 - t)
        dstRow[x] = pixel < threshold ? 0 : 255
      }
    }

    let grayColorSpace = CGColorSpaceCreateDeviceGray()
    var outFormat = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      colorSpace: Unmanaged.passUnretained(grayColorSpace),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      version: 0,
      decode: nil,
      renderingIntent: .defaultIntent
    )

    var outError: vImage_Error = kvImageNoError
    guard
      let cgImage = vImageCreateCGImageFromBuffer(
        &binaryBuffer,
        &outFormat,
        nil,
        nil,
        vImage_Flags(kvImageNoFlags),
        &outError
      )?.takeRetainedValue(),
      outError == kvImageNoError
    else {
      return nil
    }

    return cgImage
  }

  private static func adaptiveKernelSize(width: Int, height: Int) -> Int {
    let minDim = max(1, min(width, height))
    let raw = max(15, min(75, minDim / 8))
    return raw % 2 == 1 ? raw : raw + 1
  }
}

private actor PDFOCRRecognitionCoalescer {
  private struct CachedOCRResult {
    let words: [PDFOCRWord]
    let createdAt: Date
  }

  private struct OCRFailure {
    let lastAttempt: Date
    let consecutiveFailures: Int
  }

  private var running: Set<String> = []
  private var waiters: [String: [CheckedContinuation<[PDFOCRWord], Never>]] = [:]
  private var cache: [String: CachedOCRResult] = [:]
  private var cacheOrder: [String] = []
  private var failures: [String: OCRFailure] = [:]
  private let cacheTTL: TimeInterval = 12 * 60
  private let cacheCapacity: Int = 24
  private let failureTTL: TimeInterval = 18 * 60

  func run(_ key: String, _ operation: @escaping () async -> [PDFOCRWord]) async -> [PDFOCRWord] {
    let now = Date()
    pruneFailures(before: now)
    if let cached = cache[key], now.timeIntervalSince(cached.createdAt) < cacheTTL {
      bumpCacheOrder(key)
      return cached.words
    }

    if let lastFailure = failures[key] {
      let delay = failureRetryDelay(for: lastFailure.consecutiveFailures)
      if now.timeIntervalSince(lastFailure.lastAttempt) < delay {
        return []
      }
    }

    if running.contains(key) {
      return await withCheckedContinuation { continuation in
        waiters[key, default: []].append(continuation)
      }
    }

    running.insert(key)
    let value = await operation()
    if value.isEmpty {
      let failureCount = (failures[key]?.consecutiveFailures ?? 0) + 1
      failures[key] = OCRFailure(lastAttempt: now, consecutiveFailures: failureCount)
    } else {
      failures.removeValue(forKey: key)
      cache[key] = CachedOCRResult(words: value, createdAt: Date())
      bumpCacheOrder(key)
      trimCacheIfNeeded()
    }
    let pending = waiters.removeValue(forKey: key) ?? []
    for continuation in pending {
      continuation.resume(returning: value)
    }
    running.remove(key)
    return value
  }

  private func bumpCacheOrder(_ key: String) {
    if let index = cacheOrder.firstIndex(of: key) {
      cacheOrder.remove(at: index)
    }
    cacheOrder.append(key)
  }

  private func trimCacheIfNeeded() {
    while cacheOrder.count > cacheCapacity {
      if let removed = cacheOrder.first {
        cacheOrder.removeFirst()
        cache.removeValue(forKey: removed)
      } else {
        break
      }
    }
  }

  private func failureRetryDelay(for consecutiveFailures: Int) -> TimeInterval {
    let attempt = min(consecutiveFailures, 6)
    let base: TimeInterval = 0.8
    let factor = 1 << min(attempt, 6)
    return min(20, base * Double(factor))
  }

  private func pruneFailures(before now: Date) {
    let stale = failures.filter { now.timeIntervalSince($0.value.lastAttempt) > failureTTL }
    for key in stale.keys {
      failures.removeValue(forKey: key)
    }
  }
}
