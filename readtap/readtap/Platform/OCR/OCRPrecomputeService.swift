import Foundation
import PDFKit

/// PDF 임포트 후 백그라운드에서 페이지 OCR을 순차 실행하여
/// `OCRCacheStore`에 저장하는 서비스.
///
/// 2단계 분할:
/// - 임포트 시: 앞 절반 (`pageRange: 0..<half`)
/// - 리더 진입 시: 나머지 절반 (`pageRange: half..<total`) fire-and-forget
enum OCRPrecomputeService {

    /// 진행 상태 알림.
    /// userInfo: ["bookId": String, "current": Int, "total": Int]
    static let progressNotification = Notification.Name("OCRPrecomputeProgress")

    /// 완료 알림.
    /// userInfo: ["bookId": String]
    static let didFinishNotification = Notification.Name("OCRPrecomputeDidFinish")

    private actor ActiveTaskStorage {
        private var tasks: [String: Task<Void, Never>] = [:]

        func task(for key: String) -> Task<Void, Never>? {
            tasks[key]
        }

        func set(_ task: Task<Void, Never>, for key: String) {
            tasks[key] = task
        }

        func remove(for key: String) -> Task<Void, Never>? {
            tasks.removeValue(forKey: key)
        }
    }

    // MARK: - Active task tracking
    private static let activeTaskStorage = ActiveTaskStorage()

    /// 특정 bookId에 대해 이미 프리컴퓨트가 진행 중인지 확인.
    static func isActive(bookId: String) async -> Bool {
        await activeTaskStorage.task(for: bookId) != nil
    }

    /// 진행 중인 프리컴퓨트를 취소.
    static func cancel(bookId: String) async {
        let task = await activeTaskStorage.remove(for: bookId)
        task?.cancel()
    }

    // MARK: - Main entry

    /// 지정 범위의 페이지 OCR 프리컴퓨트. 이미 캐시된 페이지는 스킵.
    /// - `pageRange`: 처리할 페이지 범위. nil이면 전체.
    @discardableResult
    static func precomputeAllPages(
        bookId: String,
        fileURL: URL,
        pageRange: Range<Int>? = nil
    ) async -> Bool {
        // 같은 bookId + 같은 범위 중복 실행 방지
        let taskKey = "\(bookId)|\(pageRange?.description ?? "all")"
        let alreadyRunning = await activeTaskStorage.task(for: taskKey) != nil
        guard !alreadyRunning else { return false }

        let task = Task.detached(priority: .background) {
            await runPrecompute(bookId: bookId, fileURL: fileURL, pageRange: pageRange)
        }

        await activeTaskStorage.set(task, for: taskKey)

        await task.value

        _ = await activeTaskStorage.remove(for: taskKey)

        await MainActor.run {
            NotificationCenter.default.post(
                name: didFinishNotification,
                object: nil,
                userInfo: ["bookId": bookId]
            )
        }

        return !Task.isCancelled
    }

    // MARK: - Core logic

    private static func runPrecompute(bookId: String, fileURL: URL, pageRange: Range<Int>?) async {
        guard let document = PDFDocument(url: fileURL) else { return }
        let totalPages = document.pageCount
        guard totalPages > 0 else { return }

        let range = pageRange.map { $0.clamped(to: 0..<totalPages) } ?? (0..<totalPages)
        guard !range.isEmpty else { return }

        let languages = OCRTuning.currentRecognitionLanguages()

        for pageIndex in range {
            guard !Task.isCancelled else { return }

            // Thermal/battery 배려
            await throttleIfNeeded()

            // 캐시 확인 — 이미 있으면 스킵
            let cached = OCRCacheStore.shared.load(
                bookId: bookId,
                pageIndex: pageIndex,
                languages: languages
            )
            if cached != nil {
                await postProgress(bookId: bookId, current: pageIndex + 1, total: totalPages)
                continue
            }

            guard !Task.isCancelled else { return }

            // 페이지 OCR 실행 — 최대 속도: binarization 끄고 quick quality
            guard let page = document.page(at: pageIndex) else { continue }
            let words = await PDFOCRProcessor.recognizeWords(
                page: page,
                pageIndex: pageIndex,
                languages: languages,
                allowBinarization: false,
                allowAdaptiveRetry: false,
                quality: .quick
            )

            guard !Task.isCancelled else { return }

            // 캐시 저장
            if !words.isEmpty {
                OCRCacheStore.shared.save(
                    bookId: bookId,
                    pageIndex: pageIndex,
                    words: words,
                    languages: languages
                )
            }

            // 진행률 알림
            await postProgress(bookId: bookId, current: pageIndex + 1, total: totalPages)

            // 저전력 모드에서만 짧은 대기 (일반 모드는 풀스피드)
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
    }

    // MARK: - Helpers

    private static func throttleIfNeeded() async {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            // 과열 시 2초 대기
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func postProgress(bookId: String, current: Int, total: Int) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: progressNotification,
                object: nil,
                userInfo: [
                    "bookId": bookId,
                    "current": current,
                    "total": total,
                ]
            )
        }
    }
    
}
