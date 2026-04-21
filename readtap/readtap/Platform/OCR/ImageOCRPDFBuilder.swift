import Foundation
import UIKit
import Vision
import CoreImage
import CoreText
import Accelerate

struct ImageOCRPDFBuilder {
    enum BuildError: LocalizedError {
        case invalidImage
        case pdfWriteFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "Unable to process the selected image."
            case .pdfWriteFailed:
                return "Failed to create a PDF from the image."
            }
        }
    }

    /// Identifies where an image came from so the pipeline can skip preprocessing steps
    /// that have already been applied (e.g. VisionKit's scanner already perspective-corrects
    /// and enhances the page, so our binarized passes would only hurt quality).
    enum ImageOCRSource {
        case scanner          // VisionKit — already perspective-corrected + enhanced
        case photoLibrary     // PHPicker — raw photo, needs full preprocessing
        case fileImporter     // .fileImporter — raw file, needs full preprocessing
    }

    /// Full OCR build result with quality metrics used by callers to surface a
    /// "blurry scan, retake?" warning when recognition confidence is low.
    struct BuildResult {
        let url: URL
        let pageCount: Int
        let averageConfidence: Float
        let wordsPerPage: [Int]
        let confidencePerPage: [Float]
    }

    // MARK: - Public API (source-aware, returns BuildResult with quality metrics)

    static func buildPDF(from image: UIImage, source: ImageOCRSource, deskewAngle: CGFloat = 0) throws -> BuildResult {
        let page = try buildPage(
            from: image,
            deskewAngle: deskewAngle,
            includeOCR: true,
            maxDimension: 3200,
            source: source
        )
        let pdfData = renderPDF(pages: [page])
        let url = temporaryPDFURL(prefix: "Photo")

        do {
            try pdfData.write(to: url, options: .atomic)
        } catch {
            throw BuildError.pdfWriteFailed
        }

        return makeBuildResult(url: url, pages: [page])
    }

    static func buildPDF(from images: [UIImage], source: ImageOCRSource, deskewAngle: CGFloat = 0) throws -> BuildResult {
        guard !images.isEmpty else {
            throw BuildError.invalidImage
        }

        var pages: [(UIImage, [OCRWord])] = []
        pages.reserveCapacity(images.count)

        for image in images {
            let page = try buildPage(
                from: image,
                deskewAngle: deskewAngle,
                includeOCR: true,
                maxDimension: 3200,
                source: source
            )
            pages.append(page)
        }

        let pdfData = renderPDF(pages: pages)
        let url = temporaryPDFURL(prefix: "Scan")

        do {
            try pdfData.write(to: url, options: .atomic)
        } catch {
            throw BuildError.pdfWriteFailed
        }

        return makeBuildResult(url: url, pages: pages)
    }

    // MARK: - Public API (backward-compatible URL-returning wrappers, default to .fileImporter)

    static func buildPDF(from image: UIImage, deskewAngle: CGFloat = 0) throws -> URL {
        try buildPDF(from: image, source: .fileImporter, deskewAngle: deskewAngle).url
    }

    static func buildPDF(from images: [UIImage], deskewAngle: CGFloat = 0) throws -> URL {
        try buildPDF(from: images, source: .fileImporter, deskewAngle: deskewAngle).url
    }

    static func buildQuickPDF(from image: UIImage, source: ImageOCRSource = .fileImporter, deskewAngle: CGFloat = 0) throws -> URL {
        let page = try buildPage(
            from: image,
            deskewAngle: deskewAngle,
            includeOCR: false,
            maxDimension: 1800,
            source: source
        )
        let pdfData = renderPDF(pages: [page])
        let url = temporaryPDFURL(prefix: "PhotoQuick")
        do {
            try pdfData.write(to: url, options: .atomic)
        } catch {
            throw BuildError.pdfWriteFailed
        }
        return url
    }

    static func buildQuickPDF(from images: [UIImage], source: ImageOCRSource = .fileImporter, deskewAngle: CGFloat = 0) throws -> URL {
        guard !images.isEmpty else {
            throw BuildError.invalidImage
        }
        var pages: [(UIImage, [OCRWord])] = []
        pages.reserveCapacity(images.count)
        for image in images {
            let page = try buildPage(
                from: image,
                deskewAngle: deskewAngle,
                includeOCR: false,
                maxDimension: 1800,
                source: source
            )
            pages.append(page)
        }
        let pdfData = renderPDF(pages: pages)
        let url = temporaryPDFURL(prefix: "ScanQuick")
        do {
            try pdfData.write(to: url, options: .atomic)
        } catch {
            throw BuildError.pdfWriteFailed
        }
        return url
    }

    private static func makeBuildResult(url: URL, pages: [(UIImage, [OCRWord])]) -> BuildResult {
        let wordsPerPage = pages.map { $0.1.count }
        let confidencePerPage: [Float] = pages.map { _, words in
            guard !words.isEmpty else { return 0 }
            return words.reduce(0) { $0 + $1.confidence } / Float(words.count)
        }
        let allWords = pages.flatMap { $0.1 }
        let avgConf: Float
        if allWords.isEmpty {
            avgConf = 0
        } else {
            avgConf = allWords.reduce(0) { $0 + $1.confidence } / Float(allWords.count)
        }
        return BuildResult(
            url: url,
            pageCount: pages.count,
            averageConfidence: avgConf,
            wordsPerPage: wordsPerPage,
            confidencePerPage: confidencePerPage
        )
    }

    private struct OCRWord {
        let text: String
        let box: CGRect
        let confidence: Float
    }

    private struct OCRPassResult {
        let words: [OCRWord]
        let averageConfidence: Float
    }

    private struct OCRTuningText {
        static func joinText(_ words: [OCRWord]) -> String {
            return words.map(\.text).joined(separator: " ")
        }
    }

    private static func isHighQualityOCRResult(_ result: OCRPassResult) -> Bool {
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

    private static func isHighConfidence(_ result: OCRPassResult) -> Bool {
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

    private static func shouldRetryWithAdaptiveLanguage(_ result: OCRPassResult, languages: [String]) -> Bool {
        guard hasAtLeastTwoLanguageFamilies(languages) || result.words.isEmpty else { return false }
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

    private static func hasAtLeastTwoLanguageFamilies(_ languages: [String]) -> Bool {
        let familySet = Set(languages.compactMap { language -> String? in
            if language.hasPrefix("en") { return "en" }
            if language.hasPrefix("ko") { return "ko" }
            if language.hasPrefix("ja") { return "ja" }
            if language.hasPrefix("zh") { return "zh" }
            return nil
        })
        return familySet.count >= 2
    }

    private static func languageFamilyPriority(_ languages: [String]) -> [String] {
        let families = Set(languages.compactMap { language -> String? in
            if language.hasPrefix("ko") { return "ko" }
            if language.hasPrefix("ja") { return "ja" }
            if language.hasPrefix("zh") { return "zh" }
            if language.hasPrefix("en") { return "en" }
            return nil
        })

        if families.contains("ko") {
            if families.count == 1 { return ["ko"] }
            if families.contains("en") { return ["ko", "en"] }
            if families.contains("ja") { return ["ko", "ja"] }
            if families.contains("zh") { return ["ko", "zh"] }
        }

        if families.contains("ja"), families.count == 1 {
            return ["ja"]
        }
        if families.contains("zh"), families.count == 1 {
            return ["zh"]
        }
        if families.contains("en"), families.count == 1 {
            return ["en"]
        }

        if families.contains("en") { return ["en", "ko", "ja", "zh"] }
        if families.contains("ja") { return ["ja", "zh", "en"] }
        if families.contains("zh") { return ["zh", "ja", "en"] }
        return ["en", "ko", "ja", "zh"]
    }

    private static func adaptivePasses(for languages: [String], sampleWords: Int) -> [OCRPass] {
        let families = languageFamilyPriority(languages)

        if families.contains("ko") {
            if sampleWords < 28 {
                return [.documentEnhanced, .normalizedStrong, .binarizedStrong]
            }
            return [.documentEnhanced, .normalizedStrong]
        }

        if families.contains("ja") || families.contains("zh") {
            if sampleWords < 28 {
                return [.binarizedStrong, .documentEnhanced, .normalizedStrong]
            }
            return [.binarizedStrong, .documentEnhanced]
        }

        if sampleWords < 28 {
            return [.normalizedStrong, .binarizedStrong, .documentEnhanced]
        }
        return [.normalizedStrong, .binarizedStrong]
    }

    private static func normalizedLanguagePlan(_ languages: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for language in languages {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    private static func languagePlanKey(_ languages: [String]) -> String {
        return normalizedLanguagePlan(languages).map { $0.lowercased() }.joined(separator: ",")
    }

    private static func deduplicatedLanguagePlans(_ plans: [[String]], excluding baseLanguages: [String]) -> [[String]] {
        let baseKey = languagePlanKey(baseLanguages)
        var seen: Set<String> = [baseKey]
        var out: [[String]] = []

        for plan in plans {
            let normalized = normalizedLanguagePlan(plan)
            guard normalized.isEmpty == false else { continue }
            let key = languagePlanKey(normalized)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(normalized)
        }

        return out
    }

	    private static func buildPage(
            from image: UIImage,
            deskewAngle: CGFloat,
            includeOCR: Bool,
            maxDimension: CGFloat,
            source: ImageOCRSource = .fileImporter
        ) throws -> (UIImage, [OCRWord]) {
	        guard let normalized = normalizedImage(from: image) else {
	            throw BuildError.invalidImage
	        }

	        // Keep processing (especially OCR) fast by limiting source resolution.
	        let base = downscaledImageIfNeeded(normalized, maxDimension: maxDimension)

	        // VisionKit's document scanner already runs its own perspective correction
	        // and enhancement, so re-detecting a quad on that output only risks a false
	        // crop. Skip for .scanner; keep for raw photo-library / file-importer sources.
	        var output = base
	        if source != .scanner {
	            output = correctedDocumentImage(from: base) ?? base
	        }
	        if abs(deskewAngle) > 0.0001, let rotated = rotatedImage(from: output, angle: deskewAngle) {
	            output = rotated
	        }
	        let ocrWords = includeOCR ? bestOCRWords(for: output, source: source) : []
	        return (output, ocrWords)
	    }

    private static func temporaryPDFURL(prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "\(prefix)-\(formatter.string(from: Date())).pdf"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private enum OCRPass {
        case original
        case documentEnhanced
        case normalized
        case normalizedStrong
        case binarized
        case binarizedStrong
    }

    private static func bestOCRWords(for image: UIImage, source: ImageOCRSource = .fileImporter) -> [OCRWord] {
        // Scanner-sourced images are already contrast-enhanced by VisionKit, so our
        // aggressive binarization passes can hurt rather than help. Use a lighter pass
        // list for .scanner; keep the full 6-pass set for raw photo/file inputs.
        let passes: [OCRPass]
        switch source {
        case .scanner:
            passes = [.original, .documentEnhanced, .normalized]
        case .photoLibrary, .fileImporter:
            passes = [
                .documentEnhanced,
                .normalized,
                .normalizedStrong,
                .binarized,
                .binarizedStrong,
                .original
            ]
        }
        var results: [OCRPassResult] = []
        let languages = ocrRecognitionLanguages()
        results.reserveCapacity(passes.count)
        var bestSoFar: OCRPassResult?

        for pass in passes {
            let result = performOCR(on: image, pass: pass, languages: languages)
            results.append(result)
            if let currentBest = results.max(by: { score($0) < score($1) }) {
                bestSoFar = currentBest
            }

            // Early-exit when recognition is already strong. This keeps accuracy high on
            // hard images (we still try all passes), but speeds up the common "clean scan" case.
            if let currentBest = bestSoFar, isHighQualityOCRResult(currentBest) {
                break
            }
        }

        // Scanner sources normally skip binarization (VisionKit pre-enhances). But when a
        // scanner page still comes out weak — shadows, curved spines, faded print — the heavier
        // passes can rescue it. Clean scans never reach this branch thanks to early-exit above.
        if source == .scanner,
           let currentBest = bestSoFar,
           !isHighQualityOCRResult(currentBest),
           !isHighConfidence(currentBest) {
            let fallbackPasses: [OCRPass] = [.normalizedStrong, .binarized, .binarizedStrong]
            for pass in fallbackPasses {
                let result = performOCR(on: image, pass: pass, languages: languages)
                results.append(result)
                if let updated = results.max(by: { score($0) < score($1) }) {
                    bestSoFar = updated
                    if isHighQualityOCRResult(updated) {
                        break
                    }
                }
            }
        }

        guard var best = bestSoFar ?? results.max(by: { score($0) < score($1) }) else {
            return []
        }

        if shouldRetryWithAdaptiveLanguage(best, languages: languages) {
            let sampleText = OCRTuningText.joinText(best.words)
            let retryLanguagePlans = deduplicatedLanguagePlans(
                OCRTuning.adaptiveLanguagePlans(
                    for: languages,
                    sampleText: sampleText
                ),
                excluding: languages
            )

            var attemptedLanguageKeys = Set([languagePlanKey(languages)])
            let maxLanguagePlans = 2
            var attempts = 0

            for retryLanguages in retryLanguagePlans where attempts < maxLanguagePlans {
                let key = languagePlanKey(retryLanguages)
                if attemptedLanguageKeys.contains(key) { continue }
                attemptedLanguageKeys.insert(key)
                attempts += 1

                let extraPasses = adaptivePasses(for: retryLanguages, sampleWords: best.words.count)
                for pass in extraPasses {
                    results.append(performOCR(on: image, pass: pass, languages: retryLanguages))
                    if let currentBest = results.max(by: { score($0) < score($1) }) {
                        if score(currentBest) > score(best) {
                            best = currentBest
                        }
                        if isHighQualityOCRResult(currentBest) {
                            break
                        }
                    }
                }

                if let currentBest = results.max(by: { score($0) < score($1) }),
                   isHighQualityOCRResult(currentBest) {
                    best = currentBest
                    break
                }
                if isHighConfidence(best) {
                    break
                }
            }
        }

        let merged = mergePassResults(results)
        if !merged.isEmpty {
            return merged
        }

        if let best = results.max(by: { score($0) < score($1) }) {
            return best.words
        }

        return []
    }

    private static func score(_ result: OCRPassResult) -> Float {
        let countScore = Float(result.words.count)
        let confidenceScore = max(result.averageConfidence, 0.2)
        return countScore * confidenceScore
    }

    private static func mergePassResults(_ results: [OCRPassResult]) -> [OCRWord] {
        var merged: [OCRWord] = []
        for word in results.flatMap({ $0.words }) {
            if let index = merged.firstIndex(where: { existing in
                // Standard IoU check.
                if iou(existing.box, word.box) > 0.7 { return true }
                // Also merge if one word's box is largely contained within the other
                // (catches "based-on" overlapping "based on" from different passes).
                let intersection = existing.box.intersection(word.box)
                guard !intersection.isNull, !intersection.isEmpty else { return false }
                let intArea = intersection.width * intersection.height
                let smallerArea = min(existing.box.width * existing.box.height, word.box.width * word.box.height)
                return smallerArea > 0 && (intArea / smallerArea) > 0.65
            }) {
                merged[index] = preferredWord(merged[index], word)
            } else {
                merged.append(word)
            }
        }
        return dedupeWords(merged)
    }

	    private static func preferredWord(_ a: OCRWord, _ b: OCRWord) -> OCRWord {
	        if let preferred = preferredBySubstringGeometry(a, b) {
	            return preferred
	        }
	        if let language = spellcheckLanguage() {
	            let missA = misspellCount(in: a.text, language: language)
	            let missB = misspellCount(in: b.text, language: language)
	            if missA != missB {
	                return missA < missB ? a : b
            }
        }
        if a.confidence != b.confidence {
            return a.confidence >= b.confidence ? a : b
        }
	        if a.text.count != b.text.count {
	            return a.text.count >= b.text.count ? a : b
	        }
	        return a
	    }

	    private static func preferredBySubstringGeometry(_ a: OCRWord, _ b: OCRWord) -> OCRWord? {
	        let ta = a.text
	        let tb = b.text
	        guard ta != tb else { return nil }
	        guard isASCIIWordLike(ta), isASCIIWordLike(tb) else { return nil }

	        let la = ta.lowercased()
	        let lb = tb.lowercased()
	        let aContainsB = la.contains(lb)
	        let bContainsA = lb.contains(la)
	        guard aContainsB || bContainsA else { return nil }

	        let longer: OCRWord
	        let shorter: OCRWord
	        if ta.count >= tb.count {
	            longer = a
	            shorter = b
	        } else {
	            longer = b
	            shorter = a
	        }

	        let lengthDelta = longer.text.count - shorter.text.count
	        guard lengthDelta >= 3 && lengthDelta <= 6 else { return nil }

	        // If the longer word covers a meaningfully wider box, it's likely the true word.
	        let widthRatio = longer.box.width / max(1e-6, shorter.box.width)
	        let areaRatio = (longer.box.width * longer.box.height) / max(1e-8, (shorter.box.width * shorter.box.height))
	        guard widthRatio >= 1.06 || areaRatio >= 1.12 else { return nil }

	        // Don't override a massively higher confidence.
	        guard longer.confidence >= 0.4 else { return nil }
	        if longer.confidence >= shorter.confidence {
	            return longer
	        }
	        let confGap = shorter.confidence - longer.confidence
	        if confGap <= 0.35 {
	            return longer
	        }

	        return nil
	    }

	    private static func isASCIIWordLike(_ word: String) -> Bool {
	        if word.count < 3 { return false }
	        if word.rangeOfCharacter(from: .decimalDigits) != nil { return false }
	        if word == word.uppercased() { return false }

	        return word.unicodeScalars.allSatisfy { scalar in
	            guard scalar.isASCII else { return false }
	            if scalar.value == 39 { return true } // apostrophe
	            return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
	        }
	    }

    private static func performOCR(
        on image: UIImage,
        pass: OCRPass,
        languages: [String] = ocrRecognitionLanguages()
    ) -> OCRPassResult {
        guard let baseCI = CIImage(image: image) else {
            return OCRPassResult(words: [], averageConfidence: 0)
        }

        let preprocessed = preprocess(baseCI, pass: pass)
        let scaled = upscaledCIImage(preprocessed)

        let fullWords = recognizeWords(
            in: scaled,
            regions: nil,
            languages: languages
        )
        let fullAverage = fullWords.isEmpty ? 0 : fullWords.map { $0.confidence }.reduce(0, +) / Float(fullWords.count)

        // ROI recognition is expensive; only do it when the full-pass looks weak.
        let shouldRunROI = fullWords.count < 60 || fullAverage < 0.5
        let regionWords: [OCRWord]
        if shouldRunROI {
            let regions = detectTextRegions(in: scaled)
            regionWords = regions.isEmpty ? [] : recognizeWords(in: scaled, regions: regions, languages: languages)
        } else {
            regionWords = []
        }

        let unique = dedupeWords(fullWords + regionWords)
        let average = unique.isEmpty ? 0 : unique.map { $0.confidence }.reduce(0, +) / Float(unique.count)
        return OCRPassResult(words: unique, averageConfidence: average)
    }

    private static func configureTextRequest(_ request: VNRecognizeTextRequest, languages: [String] = ocrRecognitionLanguages()) {
        OCRTuning.configure(request, minimumTextHeight: 0.004, languages: languages)
    }

    private static func ocrRecognitionLanguages() -> [String] {
        OCRTuning.currentRecognitionLanguages()
    }

    private static let ocrWordTrimCharacters: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.formUnion(.symbols)
        set.formUnion(.whitespacesAndNewlines)
        return set
    }()

    private static func preprocess(_ image: CIImage, pass: OCRPass) -> CIImage {
        switch pass {
        case .original:
            return image
        case .documentEnhanced:
            return documentEnhancedCIImage(from: image)
        case .normalized:
            return normalizedCIImage(from: image)
        case .normalizedStrong:
            return normalizedStrongCIImage(from: image)
        case .binarized:
            return binarizedCIImage(from: image)
        case .binarizedStrong:
            return binarizedStrongCIImage(from: image)
        }
    }

    private static func recognizeWords(in image: CIImage, regions: [CGRect]?, languages: [String]) -> [OCRWord] {
        var items: [OCRWord] = []

        let extent = image.extent
        let roiList = (regions?.isEmpty == false) ? regions! : [CGRect(x: 0, y: 0, width: 1, height: 1)]

        func mapRect(_ rect: CGRect, within region: CGRect) -> CGRect {
            CGRect(
                x: region.minX + rect.minX * region.width,
                y: region.minY + rect.minY * region.height,
                width: rect.width * region.width,
                height: rect.height * region.height
            )
        }

        for region in roiList {
            let mappedRegion = clampRect(region)
            var cropRect = CGRect(
                x: extent.minX + mappedRegion.minX * extent.width,
                y: extent.minY + mappedRegion.minY * extent.height,
                width: mappedRegion.width * extent.width,
                height: mappedRegion.height * extent.height
            ).integral
            cropRect = cropRect.intersection(extent)
            if cropRect.width < 8 || cropRect.height < 8 {
                continue
            }

            let cropImage = image.cropped(to: cropRect)
            let transform: (CGRect) -> CGRect = { rect in
                mapRect(rect, within: mappedRegion)
            }

	            let request = VNRecognizeTextRequest { request, _ in
	                guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
	                for observation in observations {
	                    let fallback = transform(observation.boundingBox)
	                    // Keep multiple candidates; the top-1 confidence candidate is not always the most
	                    // semantically correct (e.g. "mathematical" vs "thematic"). We merge later using
	                    // geometry + heuristics.
	                    let candidates = observation.topCandidates(4)
	                    for candidate in candidates {
	                        items.append(contentsOf: ocrWords(from: candidate, fallbackBox: fallback, transform: transform))
	                    }
	                }
            }

            configureTextRequest(request, languages: languages)
            let handler = VNImageRequestHandler(ciImage: cropImage, options: [:])
            try? handler.perform([request])
        }

        return items
    }

    private static func ocrWords(
        from candidate: VNRecognizedText,
        fallbackBox: CGRect,
        transform: (CGRect) -> CGRect
    ) -> [OCRWord] {
        let text = candidate.string
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return [] }

        // First pass: collect boxes for tokens where Vision succeeds, track fallback indices.
        struct PendingToken {
            let normalized: String
            let coreRange: Range<String.Index>
        }

        var items: [OCRWord] = []
        items.reserveCapacity(tokens.count)
        var successHeights: [CGFloat] = []
        var pendingFallbacks: [(index: Int, token: PendingToken)] = []

        let language = spellcheckLanguage()

        for token in tokens {
            let tokenRange = token.startIndex..<token.endIndex
            guard let coreRange = trimmedRange(tokenRange, in: text) else { continue }

            let core = text[coreRange]
            let coreString = String(core)

            // If OCR missed a space (e.g. "contraryto"), try splitting into valid dictionary words.
            if let language,
               let splitRanges = mergedWordSplitRanges(coreRange, in: text, language: language),
               splitRanges.count >= 2 {
                var mappedBoxes: [CGRect] = []
                mappedBoxes.reserveCapacity(splitRanges.count)
                var canMapAll = true
                for r in splitRanges {
                    guard let rectObservation = try? candidate.boundingBox(for: r) else {
                        canMapAll = false
                        break
                    }
                    mappedBoxes.append(transform(rectObservation.boundingBox))
                }

                if canMapAll,
                   shouldAcceptSplit(text: text, ranges: splitRanges, boxes: mappedBoxes, candidate: candidate, transform: transform) {
                    for (idx, r) in splitRanges.enumerated() {
                        let segment = String(text[r])
                        let normalized = correctedWord(segment)
                        if normalized.isEmpty { continue }
                        items.append(OCRWord(text: normalized, box: mappedBoxes[idx], confidence: candidate.confidence))
                        successHeights.append(mappedBoxes[idx].height)
                    }
                    continue
                }
            }

            let normalized = correctedWord(coreString)
            if normalized.isEmpty { continue }

            if let rectObservation = try? candidate.boundingBox(for: coreRange) {
                let mapped = transform(rectObservation.boundingBox)
                items.append(OCRWord(text: normalized, box: mapped, confidence: candidate.confidence))
                successHeights.append(mapped.height)
            } else {
                // Mark placeholder; will fill with estimated box in second pass.
                let placeholderIndex = items.count
                items.append(OCRWord(text: normalized, box: .zero, confidence: candidate.confidence))
                pendingFallbacks.append((index: placeholderIndex, token: PendingToken(normalized: normalized, coreRange: coreRange)))
            }
        }

        // Second pass: estimate fallback boxes using median height from successful extractions.
        if !pendingFallbacks.isEmpty {
            let estimatedHeight: CGFloat
            if !successHeights.isEmpty {
                let sorted = successHeights.sorted()
                let mid = sorted.count / 2
                estimatedHeight = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
            } else {
                // No successful boxes at all; use 70% of fallback (line) height as conservative estimate.
                estimatedHeight = fallbackBox.height * 0.7
            }
            // Centre the estimated height vertically within the fallback box.
            let yOffset = (fallbackBox.height - estimatedHeight) / 2
            let estimatedY = fallbackBox.minY + yOffset

            let totalLen = max(1, text.count)
            for pending in pendingFallbacks {
                let charStart = text.distance(from: text.startIndex, to: pending.token.coreRange.lowerBound)
                let charEnd = text.distance(from: text.startIndex, to: pending.token.coreRange.upperBound)
                let xStart = fallbackBox.minX + fallbackBox.width * CGFloat(charStart) / CGFloat(totalLen)
                let xEnd = fallbackBox.minX + fallbackBox.width * CGFloat(charEnd) / CGFloat(totalLen)
                let estimatedBox = CGRect(
                    x: xStart,
                    y: estimatedY,
                    width: max(0.001, xEnd - xStart),
                    height: estimatedHeight
                )
                items[pending.index] = OCRWord(text: pending.token.normalized, box: estimatedBox, confidence: items[pending.index].confidence)
            }
        }

        return items
    }

    private static func trimmedRange(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var start = range.lowerBound
        var end = range.upperBound

        func isTrimChar(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { ocrWordTrimCharacters.contains($0) }
        }

        while start < end, isTrimChar(text[start]) {
            start = text.index(after: start)
        }
        while end > start {
            let prev = text.index(before: end)
            if isTrimChar(text[prev]) {
                end = prev
            } else {
                break
            }
        }
        return start < end ? start..<end : nil
    }

    private static func mergedWordSplitRanges(
        _ coreRange: Range<String.Index>,
        in text: String,
        language: String
    ) -> [Range<String.Index>]? {
        let core = text[coreRange]
        guard core.count >= 6 else { return nil }
        // Only attempt for ASCII-ish words; avoid numbers and ALLCAPS acronyms.
        let coreString = String(core)
        if coreString.rangeOfCharacter(from: .decimalDigits) != nil { return nil }
        if coreString == coreString.uppercased() { return nil }
        guard core.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }

        guard isMisspelled(coreString, language: language) else { return nil }

        // Build character boundary indices [0...n] so we can split by character count.
        var boundaries: [String.Index] = [core.startIndex]
        var idx = core.startIndex
        while idx < core.endIndex {
            idx = core.index(after: idx)
            boundaries.append(idx)
        }
        let n = boundaries.count - 1
        guard n >= 6 else { return nil }

        let minLen = 2

        func isValidWord(_ i: Int, _ j: Int) -> Bool {
            let len = j - i
            if len < minLen {
                // allow "a" / "I"
                if len == 1 {
                    let w = text[boundaries[i]..<boundaries[j]].lowercased()
                    return w == "a" || w == "i"
                }
                return false
            }
            let w = String(text[boundaries[i]..<boundaries[j]])
            return !isMisspelled(w, language: language)
        }

        // Prefer 3-way splits first, then fall back to 2-way.
        var best3: [Range<String.Index>]? = nil
        if n >= 8 {
            for i in (minLen...(n - minLen * 2)) {
                if !isValidWord(0, i) { continue }
                for j in (i + minLen...(n - minLen)) {
                    if !isValidWord(i, j) { continue }
                    if !isValidWord(j, n) { continue }
                    best3 = [
                        boundaries[0]..<boundaries[i],
                        boundaries[i]..<boundaries[j],
                        boundaries[j]..<boundaries[n]
                    ]
                    break
                }
                if best3 != nil { break }
            }
        }
        if let best3 { return best3 }

        for i in (minLen...(n - minLen)) {
            if isValidWord(0, i), isValidWord(i, n) {
                return [boundaries[0]..<boundaries[i], boundaries[i]..<boundaries[n]]
            }
        }

        return nil
    }

    private static func isMisspelled(_ word: String, language: String) -> Bool {
        let checker = UITextChecker()
        let nsRange = NSRange(location: 0, length: word.utf16.count)
        let miss = checker.rangeOfMisspelledWord(in: word, range: nsRange, startingAt: 0, wrap: false, language: language)
        return miss.location != NSNotFound
    }

    private static func shouldAcceptSplit(
        text: String,
        ranges: [Range<String.Index>],
        boxes: [CGRect],
        candidate: VNRecognizedText,
        transform: (CGRect) -> CGRect
    ) -> Bool {
        guard ranges.count == boxes.count, boxes.count >= 2 else { return false }
        for i in 1..<boxes.count {
            let a = boxes[i - 1]
            let b = boxes[i]
            if b.midX <= a.midX { return false }

            let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            if verticalOverlap <= 0 { return false }
            let minH = max(1e-6, min(a.height, b.height))
            if (verticalOverlap / minH) < 0.35 { return false }

            // Require evidence of an actual space gap: look at the gap between the last character
            // of the previous segment and the first character of the next segment.
            let prev = ranges[i - 1]
            let next = ranges[i]
            guard prev.lowerBound < prev.upperBound, next.lowerBound < next.upperBound else { return false }

            let lastStart = text.index(before: prev.upperBound)
            let lastEnd = text.index(after: lastStart)
            let firstStart = next.lowerBound
            let firstEnd = text.index(after: firstStart)

            guard let lastObs = try? candidate.boundingBox(for: lastStart..<lastEnd),
                  let firstObs = try? candidate.boundingBox(for: firstStart..<firstEnd) else {
                return false
            }

            let lastBox = transform(lastObs.boundingBox)
            let firstBox = transform(firstObs.boundingBox)
            let gap = firstBox.minX - lastBox.maxX
            let charWidth = max(1e-4, min(lastBox.width, firstBox.width))
            let minGap = max(0.0012, charWidth * 0.35)
            if gap < minGap { return false }
        }
        return true
    }

    private static func selectBestCandidate(from candidates: [VNRecognizedText]) -> VNRecognizedText? {
        guard let first = candidates.first else { return nil }
        guard candidates.count > 1 else { return first }

        guard let language = spellcheckLanguage() else {
            return candidates.max(by: { $0.confidence < $1.confidence })
        }

        var bestCandidate = first
        var bestMisspell = misspellCount(in: first.string, language: language)
        var bestConfidence = first.confidence

        for candidate in candidates.dropFirst() {
            let misspell = misspellCount(in: candidate.string, language: language)
            if misspell < bestMisspell {
                bestCandidate = candidate
                bestMisspell = misspell
                bestConfidence = candidate.confidence
            } else if misspell == bestMisspell && candidate.confidence > bestConfidence {
                bestCandidate = candidate
                bestConfidence = candidate.confidence
            }
        }

        return bestCandidate
    }

    private static func spellcheckLanguage() -> String? {
        switch AppLanguage.current() {
        case .korean, .chinese:
            return nil
        case .english, .system:
            let available = UITextChecker.availableLanguages
            if available.contains("en_US") { return "en_US" }
            if let fallback = available.first(where: { $0.hasPrefix("en") }) { return fallback }
            return nil
        }
    }

    private static func misspellCount(in text: String, language: String) -> Int {
        let checker = UITextChecker()
        var count = 0
        for raw in text.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
            let word = String(raw)
            if word.count <= 2 { continue }
            if word.rangeOfCharacter(from: .decimalDigits) != nil { continue }
            let range = NSRange(location: 0, length: word.utf16.count)
            let miss = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
            if miss.location != NSNotFound {
                count += 1
            }
        }
        return count
    }

    private static func correctedWord(_ word: String) -> String {
        // Normalize Korean Jamo (NFD → NFC) so decomposed Hangul syllables are composed properly.
        let normalized = word.precomposedStringWithCanonicalMapping
        let wordToCheck = normalized != word ? normalized : word

        guard let language = spellcheckLanguage() else { return wordToCheck }
        guard wordToCheck.count > 2 else { return wordToCheck }
        if wordToCheck.rangeOfCharacter(from: .decimalDigits) != nil { return wordToCheck }
        if wordToCheck == wordToCheck.uppercased() { return wordToCheck }

        let checker = UITextChecker()
        let range = NSRange(location: 0, length: wordToCheck.utf16.count)
        let miss = checker.rangeOfMisspelledWord(in: wordToCheck, range: range, startingAt: 0, wrap: false, language: language)
        guard miss.location != NSNotFound else { return wordToCheck }

        guard let guesses = checker.guesses(forWordRange: range, in: wordToCheck, language: language),
              let best = guesses.first else {
            return wordToCheck
        }

        let distance = editDistance(wordToCheck.lowercased(), best.lowercased())
        let maxDistance = wordToCheck.count >= 6 ? 2 : 1
        if distance <= maxDistance && best.first == wordToCheck.first {
            return best
        }
        return wordToCheck
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var current = Array(repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    current[j] = prev[j - 1]
                } else {
                    current[j] = min(prev[j - 1], prev[j], current[j - 1]) + 1
                }
            }
            prev = current
        }
        return prev[bChars.count]
    }

    private static func dedupeWords(_ words: [OCRWord]) -> [OCRWord] {
        var unique: [OCRWord] = []
        for word in words {
            if unique.contains(where: { existing in
                // Exact text + high box overlap.
                if existing.text == word.text && iou(existing.box, word.box) > 0.8 { return true }
                // One text is a substring of the other + significant box overlap → duplicate fragment.
                let a = existing.text.lowercased()
                let b = word.text.lowercased()
                let isSubstring = a.contains(b) || b.contains(a)
                if isSubstring {
                    let intersection = existing.box.intersection(word.box)
                    guard !intersection.isNull, !intersection.isEmpty else { return false }
                    let intArea = intersection.width * intersection.height
                    let smallerArea = min(existing.box.width * existing.box.height, word.box.width * word.box.height)
                    return smallerArea > 0 && (intArea / smallerArea) > 0.6
                }
                return false
            }) {
                continue
            }
            unique.append(word)
        }
        return unique
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        if intersection.isNull || intersection.isEmpty { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (a.width * a.height) + (b.width * b.height) - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private static func detectTextRegions(in image: CIImage) -> [CGRect] {
        var output: [CGRect] = []
        let request = VNDetectTextRectanglesRequest { request, _ in
            guard let observations = request.results as? [VNTextObservation] else { return }
            var rects = observations.map { $0.boundingBox }
            rects = rects.map { expandRect($0, by: 0.012) }
            rects = rects.filter { $0.width > 0.02 && $0.height > 0.01 }
            rects = mergeRects(rects)
            rects = rects.sorted { $0.minY > $1.minY }
            if rects.count > 18 {
                rects = Array(rects.prefix(18))
            }
            output = rects
        }
        request.reportCharacterBoxes = false

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        return output
    }

    private static func clampRect(_ rect: CGRect) -> CGRect {
        let x = max(0, min(1, rect.minX))
        let y = max(0, min(1, rect.minY))
        let maxX = max(0, min(1, rect.maxX))
        let maxY = max(0, min(1, rect.maxY))
        return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }

    private static func expandRect(_ rect: CGRect, by padding: CGFloat) -> CGRect {
        let expanded = rect.insetBy(dx: -padding, dy: -padding)
        return clampRect(expanded)
    }

    private static func mergeRects(_ rects: [CGRect]) -> [CGRect] {
        var merged = rects
        var didMerge = true
        while didMerge {
            didMerge = false
            var result: [CGRect] = []
            for rect in merged {
                let current = rect
                var mergedIntoExisting = false
                for index in result.indices {
                    if rectsShouldMerge(result[index], current) {
                        result[index] = result[index].union(current)
                        mergedIntoExisting = true
                        didMerge = true
                        break
                    }
                }
                if !mergedIntoExisting {
                    result.append(current)
                }
            }
            merged = result
        }
        return merged
    }

    private static func rectsShouldMerge(_ a: CGRect, _ b: CGRect) -> Bool {
        let expandedA = expandRect(a, by: 0.012)
        if expandedA.intersects(b) {
            return true
        }

        let horizontalOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let horizontalGap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
        let verticalGap = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))

        if horizontalOverlap > 0 && verticalGap < 0.02 {
            return true
        }
        if verticalOverlap > 0 && horizontalGap < 0.02 {
            return true
        }

        return false
    }

    private static func renderPDF(from image: UIImage, words: [OCRWord]) -> Data {
        renderPDF(pages: [(image, words)])
    }

    // US Letter at 72 dpi — PDFKit's native point unit. Every scanned page is letterboxed to one of these
    // two sizes so downstream min/max zoom, thumbnails, and page navigation stay consistent regardless of
    // source image resolution.
    private static let canonicalPortraitPageSize = CGSize(width: 612, height: 792)
    private static let canonicalLandscapePageSize = CGSize(width: 792, height: 612)

    private static func canonicalPageBounds(for imageSize: CGSize) -> CGRect {
        let size = imageSize.width > imageSize.height ? canonicalLandscapePageSize : canonicalPortraitPageSize
        return CGRect(origin: .zero, size: size)
    }

    private static func letterboxedRect(for imageSize: CGSize, in pageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, pageSize.width > 0, pageSize.height > 0 else {
            return CGRect(origin: .zero, size: pageSize)
        }
        let scale = min(pageSize.width / imageSize.width, pageSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (pageSize.width - fittedSize.width) / 2,
            y: (pageSize.height - fittedSize.height) / 2
        )
        return CGRect(origin: origin, size: fittedSize)
    }

	    private static func renderPDF(pages: [(UIImage, [OCRWord])]) -> Data {
	        let firstPageBounds = canonicalPageBounds(for: pages.first?.0.size ?? .zero)
	        let renderer = UIGraphicsPDFRenderer(bounds: firstPageBounds)

	        return renderer.pdfData { context in
	            for (image, words) in pages {
	                let pageBounds = canonicalPageBounds(for: image.size)
	                let imageRect = letterboxedRect(for: image.size, in: pageBounds.size)
	                context.beginPage(withBounds: pageBounds, pageInfo: [:])
	                image.draw(in: imageRect)

	                let cgContext = context.cgContext
	                cgContext.saveGState()
	                cgContext.translateBy(x: 0, y: pageBounds.height)
	                cgContext.scaleBy(x: 1, y: -1)
	                cgContext.setTextDrawingMode(.invisible)
	                cgContext.textMatrix = .identity

	                let items = stabilizedTextItems(from: words, pageSize: imageRect.size)
	                for item in items {
	                    let offsetRect = item.rect.offsetBy(dx: imageRect.origin.x, dy: imageRect.origin.y)
	                    drawText(item.text, in: offsetRect, context: cgContext)
	                }

	                cgContext.restoreGState()
	            }
	        }
	    }

	    private struct PDFTextItem {
	        let text: String
	        let rect: CGRect
	    }

	    /// Stabilize word boundaries for PDFKit by grouping into lines and inserting explicit
	    /// spaces between adjacent words. This prevents common OCR-PDF issues like "contraryto"
	    /// being selected as one word on long-press.
	    private static func stabilizedTextItems(from words: [OCRWord], pageSize: CGSize) -> [PDFTextItem] {
	        struct WordItem {
	            let word: OCRWord
	            var rect: CGRect
	        }

	        let minWordPixels: CGFloat = 2
	        var items: [WordItem] = []
	        items.reserveCapacity(words.count)
	        for word in words {
	            if word.text.isEmpty { continue }
	            let rect = CGRect(
	                x: word.box.minX * pageSize.width,
	                y: word.box.minY * pageSize.height,
	                width: word.box.width * pageSize.width,
	                height: word.box.height * pageSize.height
	            )
	            if rect.width < minWordPixels || rect.height < minWordPixels { continue }
	            items.append(WordItem(word: word, rect: rect.integral))
	        }
	        guard !items.isEmpty else { return [] }

	        items.sort { $0.rect.midY > $1.rect.midY }

	        struct Line {
	            var rect: CGRect
	            var words: [WordItem]
	        }

	        func verticalOverlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
	            let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
	            if overlap <= 0 { return 0 }
	            let denom = max(1, min(a.height, b.height))
	            return overlap / denom
	        }

	        var lines: [Line] = []
	        lines.reserveCapacity(32)

	        for item in items {
	            var bestIndex: Int?
	            var bestScore: CGFloat = 0
	            for idx in lines.indices {
	                let score = verticalOverlapRatio(lines[idx].rect, item.rect)
	                if score > bestScore {
	                    bestScore = score
	                    bestIndex = idx
	                }
	            }
	            if let bestIndex, bestScore >= 0.50 {
	                lines[bestIndex].words.append(item)
	                lines[bestIndex].rect = lines[bestIndex].rect.union(item.rect)
	            } else {
	                lines.append(Line(rect: item.rect, words: [item]))
	            }
	        }

	        // Top-to-bottom, then left-to-right within each line.
	        lines.sort { $0.rect.midY > $1.rect.midY }

	        // Clamp overlapping word boxes between adjacent lines.
	        // When a word box from one line extends into an adjacent line, shrink it
	        // to the midpoint of the gap between the two lines' median centres.
	        if lines.count >= 2 {
	            for i in 0..<(lines.count - 1) {
	                let upperLine = lines[i]     // higher midY = lower on screen (PDF coords)
	                let lowerLine = lines[i + 1]
	                let boundary = (upperLine.rect.midY + lowerLine.rect.midY) / 2

	                // Clamp words in the upper line whose minY dips below the boundary.
	                for j in lines[i].words.indices {
	                    var r = lines[i].words[j].rect
	                    if r.minY < boundary {
	                        let newHeight = r.maxY - boundary
	                        if newHeight > 2 {
	                            r.origin.y = boundary
	                            r.size.height = newHeight
	                            lines[i].words[j].rect = r
	                        }
	                    }
	                }
	                // Clamp words in the lower line whose maxY rises above the boundary.
	                for j in lines[i + 1].words.indices {
	                    var r = lines[i + 1].words[j].rect
	                    if r.maxY > boundary {
	                        let newHeight = boundary - r.minY
	                        if newHeight > 2 {
	                            r.size.height = newHeight
	                            lines[i + 1].words[j].rect = r
	                        }
	                    }
	                }
	            }
	        }

	        var output: [PDFTextItem] = []
	        output.reserveCapacity(items.count * 2)

	        /// Remove overlapping words within a single sorted-by-X line.
	        func dedupeLineWords(_ sorted: [WordItem]) -> [WordItem] {
	            guard sorted.count > 1 else { return sorted }
	            var result: [WordItem] = []
	            result.reserveCapacity(sorted.count)
	            for item in sorted {
	                if let lastIndex = result.lastIndex(where: { existing in
	                    let overlapMinX = max(existing.rect.minX, item.rect.minX)
	                    let overlapMaxX = min(existing.rect.maxX, item.rect.maxX)
	                    let overlap = overlapMaxX - overlapMinX
	                    guard overlap > 0 else { return false }
	                    let smallerWidth = min(existing.rect.width, item.rect.width)
	                    return smallerWidth > 0 && (overlap / smallerWidth) > 0.5
	                }) {
	                    let existText = result[lastIndex].word.text.lowercased()
	                    let newText = item.word.text.lowercased()
	                    if existText.contains(newText) { continue }
	                    if newText.contains(existText) { continue }
	                    if item.word.text.count > result[lastIndex].word.text.count {
	                        result[lastIndex] = item
	                    }
	                    continue
	                }
	                result.append(item)
	            }
	            return result
	        }

	        func medianHeight(of items: [WordItem]) -> CGFloat {
	            let heights = items.map(\.rect.height).sorted()
	            let mid = heights.count / 2
	            if heights.isEmpty { return 0 }
	            if heights.count % 2 == 1 { return heights[mid] }
	            return (heights[mid - 1] + heights[mid]) / 2
	        }

	        for line in lines {
	            var row = line.words
	            if row.isEmpty { continue }
	            row.sort { $0.rect.minX < $1.rect.minX }

	            // Deduplicate words with significant horizontal overlap within the same line.
	            // Multiple OCR passes can produce overlapping entries for the same physical word.
	            row = dedupeLineWords(row)
	            if row.isEmpty { continue }

	            let lineHeight = max(8, medianHeight(of: row))

	            // Trim overlapping word boxes so PDFKit sees clear word boundaries.
	            // When small text produces heavily overlapping OCR boxes, PDFKit treats
	            // adjacent invisible-text glyphs as one continuous token.
	            for i in 0..<(row.count - 1) {
	                let overlap = row[i].rect.maxX - row[i + 1].rect.minX
	                if overlap > 0 {
	                    let half = overlap / 2 + 1  // +1 pixel gap for the space character
	                    var r0 = row[i].rect
	                    var r1 = row[i + 1].rect
	                    r0.size.width = max(2, r0.width - half)
	                    r1.origin.x += half
	                    r1.size.width = max(2, r1.width - half)
	                    row[i].rect = r0
	                    row[i + 1].rect = r1
	                }
	            }

	            for i in row.indices {
	                let current = row[i]
	                output.append(PDFTextItem(text: current.word.text, rect: current.rect))

	                guard i < row.count - 1 else { continue }
	                let next = row[i + 1]
	                let gap = next.rect.minX - current.rect.maxX

	                // Always insert an explicit space between distinct OCR words on the same line.
	                // Without this, PDFKit's selectionForWord(at:) treats adjacent words as one
	                // continuous token, selecting the entire line on long-press.
	                // For small text, OCR boxes often overlap heavily, so we cannot rely on gap size.
	                let spaceWidth = max(2, min(max(gap, 2), lineHeight * 0.45))
	                let centerX: CGFloat
	                if gap >= spaceWidth {
	                    centerX = current.rect.maxX + gap * 0.5
	                } else {
	                    // Boxes overlap or are very close — place space at the boundary.
	                    centerX = (current.rect.maxX + next.rect.minX) * 0.5
	                }
	                var spaceRect = CGRect(
	                    x: centerX - spaceWidth * 0.5,
	                    y: min(current.rect.minY, next.rect.minY),
	                    width: spaceWidth,
	                    height: max(current.rect.height, next.rect.height)
	                )

	                // Clamp to page.
	                if spaceRect.minX < 0 { spaceRect.origin.x = 0 }
	                if spaceRect.maxX > pageSize.width { spaceRect.origin.x = max(0, pageSize.width - spaceRect.width) }
	                if spaceRect.minY < 0 { spaceRect.origin.y = 0 }
	                if spaceRect.maxY > pageSize.height { spaceRect.size.height = max(1, pageSize.height - spaceRect.minY) }

	                if spaceRect.width >= 2, spaceRect.height >= 2 {
	                    output.append(PDFTextItem(text: " ", rect: spaceRect.integral))
	                }
	            }
	        }

	        return output
	    }

	    private static func drawText(_ text: String, in rect: CGRect, context: CGContext) {
	        guard rect.width > 1, rect.height > 1 else { return }

	        var fontSize = max(4, rect.height * 0.9)
        var font = UIFont.systemFont(ofSize: fontSize)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        var attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        if width > 0 {
            let scale = min(1.0, rect.width / width)
            if scale < 1.0 {
                fontSize = max(4, fontSize * scale)
                font = UIFont.systemFont(ofSize: fontSize)
                attributes = [.font: font]
                attributed = NSAttributedString(string: text, attributes: attributes)
                line = CTLineCreateWithAttributedString(attributed)
            }
        }

        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let x = rect.minX
        let y = rect.minY + (rect.height - bounds.height) * 0.5 - bounds.minY
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

	    private static func normalizedImage(from image: UIImage) -> UIImage? {
	        guard let cgImage = image.cgImage else { return image }
	        if image.imageOrientation == .up {
	            return image
	        }
        let ciImage = CIImage(cgImage: cgImage)
        let oriented = ciImage.oriented(forExifOrientation: Int32(CGImagePropertyOrientation(image.imageOrientation).rawValue))
	        guard let out = ciContext.createCGImage(oriented, from: oriented.extent) else { return image }
	        return UIImage(cgImage: out, scale: image.scale, orientation: .up)
	    }

	    private static func downscaledImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
	        let pixelWidth = image.size.width * image.scale
	        let pixelHeight = image.size.height * image.scale
	        let maxSide = max(pixelWidth, pixelHeight)
	        guard maxSide > maxDimension else { return image }
	        guard let ciImage = CIImage(image: image) else { return image }

	        let scale = max(0.01, maxDimension / maxSide)
	        let scaled = ciImage.applyingFilter("CILanczosScaleTransform", parameters: [
	            kCIInputScaleKey: scale,
	            kCIInputAspectRatioKey: 1.0
	        ])

	        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return image }
	        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
	    }

    private static func correctedDocumentImage(from image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let detectionImage = normalizedCIImage(from: ciImage)
        guard let rect = detectDocumentRect(in: detectionImage) else { return nil }
        let area = rect.boundingBox.width * rect.boundingBox.height
        if area < 0.85 {
            return nil
        }

        let extent = ciImage.extent
        let tl = CGPoint(x: rect.topLeft.x * extent.width, y: rect.topLeft.y * extent.height)
        let tr = CGPoint(x: rect.topRight.x * extent.width, y: rect.topRight.y * extent.height)
        let bl = CGPoint(x: rect.bottomLeft.x * extent.width, y: rect.bottomLeft.y * extent.height)
        let br = CGPoint(x: rect.bottomRight.x * extent.width, y: rect.bottomRight.y * extent.height)

        let corrected = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: tl),
            "inputTopRight": CIVector(cgPoint: tr),
            "inputBottomLeft": CIVector(cgPoint: bl),
            "inputBottomRight": CIVector(cgPoint: br)
        ])

        guard let cgImage = ciContext.createCGImage(corrected, from: corrected.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    private static func rotatedImage(from image: UIImage, angle: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let radians = Double(angle)
        let absCos = abs(cos(radians))
        let absSin = abs(sin(radians))
        let newWidth = size.width * CGFloat(absCos) + size.height * CGFloat(absSin)
        let newHeight = size.height * CGFloat(absCos) + size.width * CGFloat(absSin)
        let newSize = CGSize(width: newWidth, height: newHeight)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let rotated = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(UIColor.white.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: newSize))
            cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cgContext.rotate(by: angle)
            cgContext.translateBy(x: -size.width / 2, y: -size.height / 2)
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rotated
    }

    private static func detectDocumentRect(in image: CIImage) -> VNRectangleObservation? {
        // VNDetectDocumentSegmentationRequest (iOS 15+) uses the Neural Engine and is
        // materially better than VNDetectRectanglesRequest at finding a real document
        // quad in photo-library inputs. Same return type — VNRectangleObservation
        // exposes the four corners that CIPerspectiveCorrection consumes downstream.
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let results = request.results, !results.isEmpty else { return nil }
        return results.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        })
    }

    private static func documentEnhancedCIImage(from image: CIImage) -> CIImage {
        var output = image
        if let filter = CIFilter(name: "CIDocumentEnhancer") {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let filtered = filter.outputImage {
                output = filtered.cropped(to: output.extent)
            }
        }
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.35,
            kCIInputBrightnessKey: 0.05
        ])
        output = output.applyingFilter("CISharpenLuminance", parameters: [
            "inputSharpness": 0.35
        ])
        return output
    }

    private static func normalizedCIImage(from image: CIImage) -> CIImage {
        var output = image
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.2,
            kCIInputBrightnessKey: 0.02
        ])
        output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputShadowAmount": 1.0,
            "inputHighlightAmount": 0.2
        ])
        output = normalizeBackground(output)
        output = output.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 0.88
        ])
        output = output.applyingFilter("CISharpenLuminance", parameters: [
            "inputSharpness": 0.45
        ])
        output = output.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.015,
            "inputSharpness": 0.4
        ])
        return output
    }

    private static func normalizedStrongCIImage(from image: CIImage) -> CIImage {
        var output = image
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.45,
            kCIInputBrightnessKey: 0.06
        ])
        output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputShadowAmount": 1.2,
            "inputHighlightAmount": 0.15
        ])
        output = normalizeBackground(output)
        output = output.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: 0.3
        ])
        output = output.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 0.8
        ])
        output = output.applyingFilter("CISharpenLuminance", parameters: [
            "inputSharpness": 0.7
        ])
        output = output.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.02,
            "inputSharpness": 0.4
        ])
        return output
    }

    private static func binarizedCIImage(from image: CIImage) -> CIImage {
        var output = image
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.85,
            kCIInputBrightnessKey: 0.1
        ])
        output = output.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: 0.6
        ])
        output = output.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 0.75
        ])
        output = output.applyingFilter("CISharpenLuminance", parameters: [
            "inputSharpness": 0.6
        ])
        output = output.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.02,
            "inputSharpness": 0.4
        ])
        if (averageLuminance(for: output) ?? 0.5) < 0.35 {
            output = output.applyingFilter("CIColorInvert")
        }
        output = normalizeBackground(output)
        guard let cgImage = ciContext.createCGImage(output, from: output.extent) else { return output }
        if let thresholded = adaptiveThresholdedCGImage(from: cgImage, t: 0.12) {
            return CIImage(cgImage: thresholded)
        }
        return CIImage(cgImage: cgImage)
    }

    private static func binarizedStrongCIImage(from image: CIImage) -> CIImage {
        var output = image
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 2.1,
            kCIInputBrightnessKey: 0.12
        ])
        output = output.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: 0.8
        ])
        output = output.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 0.65
        ])
        output = output.applyingFilter("CISharpenLuminance", parameters: [
            "inputSharpness": 0.9
        ])
        output = output.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.03,
            "inputSharpness": 0.45
        ])
        if (averageLuminance(for: output) ?? 0.5) < 0.4 {
            output = output.applyingFilter("CIColorInvert")
        }
        output = normalizeBackground(output)
        guard let cgImage = ciContext.createCGImage(output, from: output.extent) else { return output }
        if let thresholded = adaptiveThresholdedCGImage(from: cgImage, t: 0.09) {
            return CIImage(cgImage: thresholded)
        }
        return CIImage(cgImage: cgImage)
    }

    private static func normalizeBackground(_ image: CIImage) -> CIImage {
        let blurred = image.applyingFilter("CIBoxBlur", parameters: [
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

    private static func averageLuminance(for image: CIImage) -> Float? {
        let extent = image.extent
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let r = Float(bitmap[0]) / 255.0
        let g = Float(bitmap[1]) / 255.0
        let b = Float(bitmap[2]) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
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
        guard let cgImage = vImageCreateCGImageFromBuffer(
            &binaryBuffer,
            &outFormat,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            &outError
        )?.takeRetainedValue(),
        outError == kvImageNoError else {
            return nil
        }

        return cgImage
    }

    private static func adaptiveKernelSize(width: Int, height: Int) -> Int {
        let minDim = max(1, min(width, height))
        let raw = max(15, min(75, minDim / 8))
        return raw % 2 == 1 ? raw : raw + 1
    }

    private static func upscaledCIImage(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        let minDim = min(extent.width, extent.height)
        guard minDim > 0 else { return image }
        let targetMin: CGFloat = 2200
        let scale = min(3.0, max(1.0, targetMin / minDim))
        guard scale > 1.01 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
        ])
    }
}

private let ciContext = CIContext(options: nil)

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
