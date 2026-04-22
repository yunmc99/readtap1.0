//
//  ReaderThumbnailSidebar.swift
//  readtap
//
//  Created by Codex.
//

import SwiftUI
import PDFKit
import UIKit
import CryptoKit

private actor ThumbnailRenderGate {
    private var inFlight: Int = 0
    private let maxConcurrent: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 3) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            inFlight = max(0, inFlight - 1)
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

final class PDFThumbnailCache {
    static let shared = PDFThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private var cachedKeysByPath: [String: Set<String>] = [:]
    private var renderedWindowByDocument: [String: Int] = [:]
    private let renderGate = ThumbnailRenderGate(maxConcurrent: 3)
    private let metaStore = PDFThumbnailMetaStore.shared
    private let diskQueue = DispatchQueue(label: "readtap.pdf.thumbnail.disk", qos: .utility)
    private let fileManager = FileManager.default
    private let diskBaseURL: URL
    private let debugStatsInterval: TimeInterval = 45
    private var debugLastReportAt: Date = .distantPast

    private struct Stats {
        var hits: Int = 0
        var misses: Int = 0
        var removals: Int = 0
        var clears: Int = 0
        var pathInvalidations: Int = 0
    }

    private var stats = Stats()

    init() {
        cache.countLimit = 80
        if #available(iOS 13.0, *) {
            cache.totalCostLimit = 64 * 1024 * 1024
        }
        PDFThumbnailMetaStore.shared.setup()
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("readtap", isDirectory: true)
            .appendingPathComponent("pdf-thumbnail-cache", isDirectory: true)
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            diskBaseURL = caches
                .appendingPathComponent("readtap", isDirectory: true)
                .appendingPathComponent("pdf-thumbnail-cache", isDirectory: true)
        } else {
            diskBaseURL = fallback
        }
        try? fileManager.createDirectory(at: diskBaseURL, withIntermediateDirectories: true)
    }

    func clearAll() {
        cache.removeAllObjects()
        cachedKeysByPath.removeAll()
        renderedWindowByDocument.removeAll()
        try? fileManager.removeItem(at: diskBaseURL)
        try? fileManager.createDirectory(at: diskBaseURL, withIntermediateDirectories: true)
        metaStore.clearAll()
        stats.clears += 1
        logSummaryIfNeeded(reason: "clear-all")
    }

    func remove(documentURL: URL) {
        let cacheRoot = documentCacheRoot(for: documentURL)
        diskQueue.async {
            try? self.fileManager.removeItem(at: cacheRoot)
        }
        let version = documentVersionFingerprint(for: documentURL)
        metaStore.deleteDocument(path: documentURL.path, version: version)
        let pathKey = documentURL.path
        renderedWindowByDocument.removeValue(forKey: stateKey(for: documentURL))
        guard let keys = cachedKeysByPath.removeValue(forKey: pathKey) else {
            stats.pathInvalidations += 1
            logSummaryIfNeeded(reason: "path-invalidated")
            return
        }
        stats.pathInvalidations += 1
        stats.removals += keys.count
        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
        logSummaryIfNeeded(reason: "path-invalidated")
    }

    func image(documentURL: URL?, page: PDFPage, pageIndex: Int, size: CGSize) -> UIImage {
        let key = imageCacheKey(documentURL: documentURL, pageIndex: pageIndex, size: size)
        if let cached = cache.object(forKey: key) {
            stats.hits += 1
            return cached
        }
        stats.misses += 1
        let normalized = canonicalCacheSize(for: size)
        let generated = page.thumbnail(of: normalized, for: .cropBox)
        let cost = Int(normalized.width * normalized.height * 4)
        cache.setObject(generated, forKey: key, cost: cost)
        if let path = documentURL?.path {
            cachedKeysByPath[path, default: .init()].insert(key as String)
        }
        logSummaryIfNeeded(reason: "page-render")
        return generated
    }

    func cachedImage(documentURL: URL?, pageIndex: Int, size: CGSize) async -> UIImage? {
        let key = imageCacheKey(documentURL: documentURL, pageIndex: pageIndex, size: size)
        if let cached = cache.object(forKey: key) {
            stats.hits += 1
            metaStore.touch(cacheKey: String(key))
            return cached
        }
        stats.misses += 1

        guard
            let documentURL,
            let diskURL = diskURL(for: documentURL, pageIndex: pageIndex, size: size),
            fileManager.fileExists(atPath: diskURL.path)
        else {
            return nil
        }

        let keyString = String(key)
        if let diskImage = await readImageFromDisk(at: diskURL) {
            let cost = Int(diskImage.size.width * diskImage.size.height * 4)
            cache.setObject(diskImage, forKey: key, cost: cost)
            cachedKeysByPath[documentURL.path, default: .init()].insert(key as String)
            metaStore.touch(cacheKey: String(key))
            return diskImage
        }
        metaStore.delete(cacheKey: keyString)
        return nil
    }

    func storeImage(image: UIImage, documentURL: URL?, pageIndex: Int, size: CGSize) {
        let key = imageCacheKey(documentURL: documentURL, pageIndex: pageIndex, size: size)
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        if let path = documentURL?.path {
            cachedKeysByPath[path, default: .init()].insert(key as String)
        }

        guard
            let documentURL,
            let diskURL = diskURL(for: documentURL, pageIndex: pageIndex, size: size),
            let pngData = image.pngData()
        else {
            return
        }

        diskQueue.async { [self] in
            try? self.fileManager.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? pngData.write(to: diskURL, options: .atomic)
            let bytes = Int64(pngData.count)
            self.metaStore.upsert(
                cacheKey: String(key),
                documentPath: documentURL.path,
                documentVersion: self.documentVersionFingerprint(for: documentURL),
                pageIndex: pageIndex,
                width: Int(self.canonicalCacheSize(for: size).width),
                height: Int(self.canonicalCacheSize(for: size).height),
                filePath: diskURL.path,
                bytes: bytes
            )
        }
    }

    func warmupInitialThumbnails(documentURL: URL, pageCountLimit: Int = 8) async {
        guard let document = PDFDocument(url: documentURL) else { return }
        let pageCount = min(document.pageCount, max(0, pageCountLimit))
        guard pageCount > 0 else { return }

        let targetSizes = warmupTargetSizes()
        let version = documentVersionFingerprint(for: documentURL)
        let requiredSizeCount = targetSizes.count
        if metaStore.hasSufficientWarmCache(
            documentPath: documentURL.path,
            documentVersion: version,
            pageLimit: pageCount,
            requiredSizeCount: requiredSizeCount
        ) {
            #if DEBUG
            print("[Cache][PDFThumbnail] warmup-skip-cached -> \(documentURL.lastPathComponent) pages=\(pageCount) sizes=\(requiredSizeCount)")
            #endif
            return
        }

        metaStore.deleteOtherVersions(for: documentURL.path, keep: version)

        for pageIndex in 0..<pageCount {
            if Task.isCancelled {
                break
            }
            let page = await MainActor.run { document.page(at: pageIndex) }
            guard let page else { continue }

            for target in targetSizes {
                let image = await withTaskGroup(of: UIImage.self, returning: UIImage.self) { group in
                    group.addTask(priority: .utility) { [page, target] in
                        page.thumbnail(of: target, for: .cropBox)
                    }
                    return await group.next() ?? page.thumbnail(of: target, for: .cropBox)
                }
                storeImage(image: image, documentURL: documentURL, pageIndex: pageIndex, size: target)
                if Task.isCancelled {
                    break
                }
            }
            if Task.isCancelled {
                break
            }
            if pageIndex + 1 < pageCount {
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
        }

        #if DEBUG
        print("[Cache][PDFThumbnail] warmup-complete -> \(documentURL.lastPathComponent) pages=\(pageCount) sizes=\(targetSizes.count)")
        #endif
    }

    func withRenderSlot<T>(_ operation: () async -> T) async -> T {
        await renderGate.acquire()
        defer {
            Task { await renderGate.release() }
        }
        return await operation()
    }

    func restoreRenderedWindow(for documentURL: URL?, totalPages: Int) -> Int {
        guard totalPages > 0, let documentURL else {
            return 0
        }
        let key = stateKey(for: documentURL)
        let cached = renderedWindowByDocument[key] ?? 0
        guard cached > 0 else {
            return 0
        }
        return min(cached, totalPages)
    }

    func persistRenderedWindow(for documentURL: URL?, count: Int, totalPages: Int) {
        guard totalPages > 0, let documentURL else { return }
        let clampedCount = max(0, min(count, totalPages))
        guard clampedCount > 0 else { return }
        renderedWindowByDocument[stateKey(for: documentURL)] = clampedCount
    }

    private func imageCacheKey(documentURL: URL?, pageIndex: Int, size: CGSize) -> NSString {
        let normalized = canonicalCacheSize(for: size)
        let docKey = documentURL?.path ?? "memory-document"
        let docVersion = documentVersionFingerprint(for: documentURL)
        return "\(docKey)|\(docVersion)|\(pageIndex)|\(Int(normalized.width))x\(Int(normalized.height))" as NSString
    }

    private func canonicalCacheSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return size
        }

        let width = canonicalCacheWidth(for: size.width)
        let scale = width / size.width
        let height = max(64, min(420, (size.height * scale).rounded(.toNearestOrAwayFromZero) * 8))
        return CGSize(width: width, height: height)
    }

    private func canonicalCacheWidth(for width: CGFloat) -> CGFloat {
        switch width {
        case ..<110:
            return 104
        case ..<130:
            return 120
        case ..<152:
            return 136
        default:
            return 156
        }
    }

    private func stateKey(for documentURL: URL) -> String {
        return "\(documentURL.path)|\(documentVersionFingerprint(for: documentURL))"
    }

    private func documentCacheRoot(for documentURL: URL) -> URL {
        let bucket = cacheBucketName(for: documentURL.path)
        return diskBaseURL.appendingPathComponent(bucket, isDirectory: true)
    }

    private func versionCacheRoot(for documentURL: URL) -> URL {
        let base = documentCacheRoot(for: documentURL)
        return base.appendingPathComponent(documentVersionFingerprint(for: documentURL), isDirectory: true)
    }

    private func diskURL(for documentURL: URL, pageIndex: Int, size: CGSize) -> URL? {
        let normalized = canonicalCacheSize(for: size)
        let width = Int(normalized.width)
        let height = Int(normalized.height)
        guard width > 0, height > 0 else { return nil }
        let fileName = "p\(pageIndex)_\(width)x\(height).png"
        return versionCacheRoot(for: documentURL).appendingPathComponent(fileName)
    }

    private func warmupTargetSizes() -> [CGSize] {
        [104, 120, 136, 156].map { base in
            CGSize(width: CGFloat(base) * 1.45, height: CGFloat(base) * 1.45 * 1.38)
        }
    }

    private func cacheBucketName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func readImageFromDisk(at url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            diskQueue.async {
                guard let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    func debugSummary() -> String {
        let totalLookups = max(1, stats.hits + stats.misses)
        let hitRate = (Double(stats.hits) / Double(totalLookups)) * 100
        let roundedHitRate = (hitRate * 10).rounded() / 10
        let parts: [String] = [
            "PDFThumbnailCache(",
            "hits:\(stats.hits), ",
            "misses:\(stats.misses), ",
            "removals:\(stats.removals), ",
            "pathInvalidations:\(stats.pathInvalidations), ",
            "clears:\(stats.clears), ",
            "hitRate:\(roundedHitRate)%"
        ]
        return parts.joined()
    }

    func logSummaryIfNeeded(reason: String) {
        #if DEBUG
        let now = Date()
        guard now.timeIntervalSince(debugLastReportAt) >= debugStatsInterval else { return }
        debugLastReportAt = now
        print("[Cache][PDFThumbnail] \(reason) -> \(debugSummary())")
        #endif
    }

    private func documentVersionFingerprint(for documentURL: URL?) -> String {
        guard let documentURL else {
            return "memory-document"
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: documentURL.path)
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.stringValue ?? "0"
            let version = Int(modified.timeIntervalSince1970 * 1_000)
            return "\(version)-\(size)"
        } catch {
            return "unversioned"
        }
    }
}

private struct ReaderThumbnailCell: View {
    let documentURL: URL?
    let document: PDFDocument
    let pageIndex: Int
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat
    let isCurrent: Bool
    let isBookmarked: Bool
    let cardSurface: Color
    let schemeIsDark: Bool
    let theme: LibraryTheme
    let onSelect: () -> Void
    let cache: PDFThumbnailCache

    @State private var renderedImage: UIImage?
    @State private var isLoading = false
    @EnvironmentObject private var appSettings: AppSettings
    private var styleMode: ReaderVisualStyleMode { appSettings.readerVisualStyleMode }

    private var placeholderHeight: CGFloat {
        max(60, thumbHeight - 4)
    }

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let renderedImage {
                        Image(uiImage: renderedImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: thumbWidth, height: thumbHeight)
                    } else if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.75)
                            .frame(width: thumbWidth, height: placeholderHeight)
                    } else {
                        Color.clear
                            .frame(width: thumbWidth, height: thumbHeight)
                    }
                }
                .background(cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: styleMode.isRefined ? 11 : 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: styleMode.isRefined ? 11 : 9, style: .continuous)
                            .stroke(
                                isCurrent
                                    ? (styleMode.isRefined ? ReaderRefinedPalette.accent.opacity(0.22) : theme.cardStroke)
                                    : (schemeIsDark
                                    ? theme.cardStroke.opacity(0.72)
                                    : (styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.58))),
                                lineWidth: isCurrent ? (styleMode.isRefined ? 1.6 : 2) : 0.6
                            )
                        .opacity(isCurrent ? 1.0 : 0.8)
                )
                .overlay(alignment: .topTrailing) {
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.accent : theme.calendarPalette(for: schemeIsDark ? .dark : .light).accent)
                            .padding(5)
                    }
                }

                Text("\(pageIndex + 1)")
                    .font(styleMode.isRefined ? .system(size: 11, weight: isCurrent ? .semibold : .medium, design: .rounded) : .caption2.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(
                    isCurrent
                        ? (styleMode.isRefined ? ReaderRefinedPalette.accentStrong : theme.cardStroke)
                        : (styleMode.isRefined ? ReaderRefinedPalette.inkMuted : theme.mutedText)
                )
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: styleMode.isRefined ? 14 : 12, style: .continuous)
                    .fill(styleMode.isRefined && isCurrent ? ReaderRefinedPalette.accentSoft : cardSurface)
            )
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .task(id: "\(pageIndex)-\(Int(thumbWidth))") {
            await renderIfNeeded()
        }
    }

    private func renderIfNeeded() async {
        guard renderedImage == nil else { return }
        let target = CGSize(width: thumbWidth * 1.45, height: thumbHeight * 1.45)
        if let cached = await cache.cachedImage(documentURL: documentURL, pageIndex: pageIndex, size: target) {
            renderedImage = cached
            return
        }
        isLoading = true
        let pageRef = await MainActor.run { [document, pageIndex] in
            document.page(at: pageIndex)
        }
        guard let pageRef else {
            isLoading = false
            return
        }
        let index = pageIndex
        let image = await cache.withRenderSlot {
            await Task.detached(priority: .utility) { [pageRef, target] in
                pageRef.thumbnail(of: target, for: .cropBox)
            }.value
        }
        if Task.isCancelled {
            isLoading = false
            return
        }
        await MainActor.run {
            guard Task.isCancelled == false else { return }
            cache.storeImage(image: image, documentURL: documentURL, pageIndex: index, size: target)
            renderedImage = image
            isLoading = false
        }
    }
}

struct PDFThumbnailSidebar: View {
    let documentURL: URL?
    let document: PDFDocument
    let currentPageIndex: Int
    let panelWidth: CGFloat
    let cache: PDFThumbnailCache
    let bookmarkedPages: Set<Int>
    let isVisible: Bool
    let onSelect: (Int) -> Void
    private let renderExpansionCount: Int = 8
    private let renderLookAheadWindow: Int = 4
    @State private var renderedPageCount: Int = 0
    @State private var scheduledWindowExpansion: DispatchWorkItem? = nil
    @AppStorage("pdfThumbnailSidebar.showBookmarksOnly") private var showBookmarksOnly: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettings
    private var theme: LibraryTheme { appSettings.theme }
    private var styleMode: ReaderVisualStyleMode { appSettings.readerVisualStyleMode }

    init(
        documentURL: URL?,
        document: PDFDocument,
        currentPageIndex: Int,
        panelWidth: CGFloat,
        cache: PDFThumbnailCache,
        bookmarkedPages: Set<Int> = [],
        isVisible: Bool = true,
        onSelect: @escaping (Int) -> Void
    ) {
        self.documentURL = documentURL
        self.document = document
        self.currentPageIndex = currentPageIndex
        self.panelWidth = panelWidth
        self.cache = cache
        self.bookmarkedPages = bookmarkedPages
        self.isVisible = isVisible
        self.onSelect = onSelect
    }

    var body: some View {
        let cardSurface = styleMode.isRefined
            ? ReaderRefinedPalette.panelSurfaceStrong
            : theme.cardSurface.opacity(colorScheme == .dark ? 0.24 : 0.2)
        let pageCount = document.pageCount
        let hasAnyPage = pageCount > 0 && (document.page(at: 0) != nil)
        let thumbWidth = max(CGFloat(84), min(CGFloat(160), panelWidth - 28))
        let thumbHeight = thumbWidth * 1.38
        let endIndex = max(0, min(pageCount, renderedPageCount))
        let allIndexes = Array(0..<endIndex)
        let visibleIndexes: [Int] = showBookmarksOnly
            ? allIndexes.filter { bookmarkedPages.contains($0) }
            : allIndexes

        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                // Filter chips: All | Bookmarks — pinned above the ScrollView so they
                // stay visible regardless of thumbnail-list scroll position.
                HStack(spacing: 4) {
                    thumbnailFilterChip(
                        title: AppText.L("All", "전체", "全部"),
                        isActive: !showBookmarksOnly
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) { showBookmarksOnly = false }
                    }
                    thumbnailFilterChip(
                        title: AppText.L("Bookmarks", "북마크", "书签"),
                        isActive: showBookmarksOnly,
                        count: bookmarkedPages.count
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) { showBookmarksOnly = true }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .padding(.horizontal, 10)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        if document.pageCount <= 0 {
                            VStack(spacing: 6) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.secondary)
                                Text("Loading pages…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .padding(.top, 20)
                        } else if hasAnyPage == false {
                            VStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("Thumbnails unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .padding(.top, 20)
                        } else if showBookmarksOnly && visibleIndexes.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bookmark")
                                    .font(.title2)
                                    .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted : theme.calendarPalette(for: colorScheme).muted)
                                Text(AppText.L("No bookmarked pages", "북마크된 페이지가 없습니다", "没有书签页面"))
                                    .font(.caption)
                                    .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted : theme.calendarPalette(for: colorScheme).muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .padding(.top, 20)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(visibleIndexes, id: \.self) { index in
                                    let isCurrent = index == currentPageIndex
                                    ReaderThumbnailCell(
                                        documentURL: documentURL,
                                        document: document,
                                        pageIndex: index,
                                        thumbWidth: thumbWidth,
                                        thumbHeight: thumbHeight,
                                        isCurrent: isCurrent,
                                        isBookmarked: bookmarkedPages.contains(index),
                                        cardSurface: cardSurface,
                                        schemeIsDark: colorScheme == .dark,
                                        theme: theme,
                                        onSelect: {
                                            ensureRenderedThrough(pageIndex: index, totalPages: pageCount)
                                            onSelect(index)
                                        },
                                        cache: cache
                                    )
                                    .id(index)
                                    .onAppear {
                                        maybeExpandWindow(around: index, totalPages: pageCount)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                    .padding(.horizontal, 10)
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1),
                        radius: 16,
                        x: 0,
                        y: 4
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(theme.cardStroke.opacity(0.4), lineWidth: 0.8)
            )
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear {
                if renderedPageCount == 0 {
                    renderedPageCount = clampedRenderWindow(pageCount: pageCount)
                }
                // Immediately expand render window to include current page so scrollTo works
                let needed = min(pageCount, currentPageIndex + 1)
                if renderedPageCount < needed {
                    renderedPageCount = needed
                }
                ensureRenderedThrough(pageIndex: currentPageIndex, totalPages: pageCount)
                persistRenderedWindowHint(totalPages: pageCount)
                DispatchQueue.main.async {
                    proxy.scrollTo(currentPageIndex, anchor: .center)
                }
            }
            .onChange(of: currentPageIndex) { _, newValue in
                ensureRenderedThrough(pageIndex: newValue, totalPages: pageCount)
                persistRenderedWindowHint(totalPages: pageCount)
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onChange(of: isVisible) { _, visible in
                if visible {
                    let needed = min(pageCount, currentPageIndex + 1)
                    if renderedPageCount < needed {
                        renderedPageCount = needed
                    }
                    ensureRenderedThrough(pageIndex: currentPageIndex, totalPages: pageCount)
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(currentPageIndex, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: pageCount) { _, newValue in
                renderedPageCount = clampedRenderWindow(pageCount: newValue)
                persistRenderedWindowHint(totalPages: newValue)
                ensureRenderedThrough(pageIndex: currentPageIndex, totalPages: newValue)
            }
            .onDisappear {
                scheduledWindowExpansion?.cancel()
                scheduledWindowExpansion = nil
                persistRenderedWindowHint(totalPages: pageCount)
            }
        }
    }

    private func thumbnailFilterChip(title: String, isActive: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isActive ? Color.white.opacity(0.25) : theme.cardStroke.opacity(0.3))
                        )
                }
            }
            .foregroundStyle(
                isActive
                    ? Color.white
                    : (styleMode.isRefined ? ReaderRefinedPalette.inkMuted : theme.calendarPalette(for: colorScheme).muted)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive
                          ? (styleMode.isRefined ? ReaderRefinedPalette.accent : theme.calendarPalette(for: colorScheme).accent)
                          : (styleMode.isRefined ? ReaderRefinedPalette.panelSurface : theme.cardSurface.opacity(0.5))
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func clampedRenderWindow(pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let baseline = initialRenderCount(for: pageCount)
        let restored = cache.restoreRenderedWindow(for: documentURL, totalPages: pageCount)
        if restored > 0 {
            return min(max(baseline, restored), pageCount)
        }
        return min(max(8, baseline), pageCount)
    }

    private func initialRenderCount(for pageCount: Int) -> Int {
        switch pageCount {
        case 0..<120:
            return 10
        case 120..<300:
            return 8
        default:
            return 6
        }
    }

    private func persistRenderedWindowHint(totalPages: Int) {
        cache.persistRenderedWindow(for: documentURL, count: renderedPageCount, totalPages: totalPages)
    }

    private func ensureRenderedThrough(pageIndex: Int, totalPages: Int) {
        guard totalPages > 0 else {
            renderedPageCount = 0
            return
        }
        let safeIndex = min(max(0, pageIndex), totalPages - 1)
        let baseline = initialRenderCount(for: totalPages)
        let targetThrough = min(totalPages, max(baseline, safeIndex + renderLookAheadWindow + 1))
        if renderedPageCount < targetThrough {
            let nextCount = min(totalPages, renderedPageCount + renderExpansionCount)
            let clampedNext = min(max(nextCount, baseline), targetThrough)
            renderedPageCount = clampedNext
            cache.persistRenderedWindow(for: documentURL, count: renderedPageCount, totalPages: totalPages)
            if renderedPageCount < targetThrough {
                scheduledWindowExpansion?.cancel()
                let workItem = DispatchWorkItem { [safeIndex, totalPages] in
                    ensureRenderedThrough(pageIndex: safeIndex, totalPages: totalPages)
                }
                scheduledWindowExpansion = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
            } else {
                scheduledWindowExpansion?.cancel()
                scheduledWindowExpansion = nil
            }
        } else if renderedPageCount > totalPages {
            renderedPageCount = totalPages
            cache.persistRenderedWindow(for: documentURL, count: renderedPageCount, totalPages: totalPages)
            scheduledWindowExpansion?.cancel()
            scheduledWindowExpansion = nil
        }
    }

    private func maybeExpandWindow(around index: Int, totalPages: Int) {
        guard totalPages > 0 else { return }
        let safeIndex = min(max(0, index), totalPages - 1)
        if safeIndex >= max(0, renderedPageCount - 2) {
            ensureRenderedThrough(pageIndex: safeIndex, totalPages: totalPages)
        }
    }
}
