import Foundation
import NaturalLanguage
import UIKit
import Vision
import CoreImage

@MainActor
final class AppWarmup {
    static let shared = AppWarmup()

    private var didWarmUp = false
    private var warmupTask: Task<Void, Never>?
    private var warmupTicket: UUID?
    let sessionId = UUID().uuidString
    private(set) var shouldPrioritizeFirstRunInteraction: Bool = false

    private init() {}

    func warmUpIfNeeded(progress: @escaping @Sendable (String) -> Void) async {
        if warmupTask != nil || didWarmUp { return }

        shouldPrioritizeFirstRunInteraction = true

        let currentTicket = UUID()
        warmupTicket = currentTicket
        let isFirstRunSession = shouldPrioritizeFirstRunInteraction
        let today = Calendar.current.startOfDay(for: Date())

        let task = Task.detached(priority: .background) {
            await Self.runWarmupInBackground(
                progress: progress,
                ticket: currentTicket,
                today: today,
                isFirstRunSession: isFirstRunSession
            )
        }

        warmupTask = task
    }

    func warmUpIfNeeded() {
        Task { @MainActor in
            await warmUpIfNeeded { _ in }
        }
    }

    func consumeFirstRunInteractionPriority() -> Bool {
        guard shouldPrioritizeFirstRunInteraction else { return false }
        shouldPrioritizeFirstRunInteraction = false
        return true
    }

    private static func runWarmupInBackground(
        progress: @escaping @Sendable (String) -> Void,
        ticket: UUID,
        today: Date,
        isFirstRunSession: Bool
    ) async {
        func report(_ message: String) async {
            let shouldReport = await MainActor.run {
                AppWarmup.shared.warmupTicket == ticket
            }
            guard shouldReport else { return }
            progress(message)
        }

        await report("앱을 준비하고 있어요")

        _ = SQLiteStore.shared
        await OCRCacheStore.shared.setup()
        _ = TranslationLookupCache.shared
        _ = TranslationTelemetryStore.shared

        await report("단어 데이터 불러오는 중")
        _ = await VocabularyStore.shared.fetchForDay(today, limit: 1)
        _ = (await BooksStore.shared.fetchAll()).first
        await VocabularyStore.shared.consolidateOrphanedBookIds()

        await report("엔진 준비 중")
        // ML 모델 프리로드를 백그라운드에서 수행해 첫 런칭 UX를 멈춤 현상 없이 진행하게 함.
        _ = await Task.detached(priority: .utility) {
            Self.primeVisionEngine()
            Self.primeLanguageRecognizer()
            Self.primeTextChecker()
        }.value

        await report("서버 연결 중")
        let serverWarmupPriority: TaskPriority = isFirstRunSession ? .background : .utility
        _ = await Task.detached(priority: serverWarmupPriority) {
            _ = try? await ContextMeaningService.shared.testConnection(rawServerURL: nil)
            // Prime Apple Translation API to avoid blocking the first long press
            if #available(iOS 18.0, *) {
                await AppleTranslationService.shared.prime()
            }
        }.value

        await report("준비 완료")

        let active = await MainActor.run { AppWarmup.shared.warmupTicket == ticket }
        guard active else { return }
        await MainActor.run {
            AppWarmup.shared.warmupTask = nil
            AppWarmup.shared.warmupTicket = nil
            AppWarmup.shared.didWarmUp = true
        }
    }

    /// Vision OCR 엔진 프리로드.
    /// VNRecognizeTextRequest는 첫 실행 시 ML 모델을 디스크에서 로드하는 데
    /// 수백ms가 걸린다. 앱 시작 시 1x1 더미 이미지로 미리 실행해두면
    /// 사용자가 처음 롱프레스했을 때 렉이 사라진다.
    private nonisolated static func primeVisionEngine() {
        // 1x1 흰색 픽셀 CIImage
        let dummyImage = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let cgImage = CIContext().createCGImage(dummyImage, from: dummyImage.extent) else { return }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }

    /// NLLanguageRecognizer 프리로드.
    /// 첫 호출 시 내부 ML 모델을 로드하는 데 수십~수백ms가 소요된다.
    /// 더미 문자열로 미리 실행해두면 첫 롱프레스 언어 감지 렉이 사라진다.
    private nonisolated static func primeLanguageRecognizer() {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString("hello")
        _ = recognizer.dominantLanguage
    }

    /// UITextChecker 프리로드.
    /// 첫 호출 시 시스템 사전을 디스크에서 로드하는 데 수십ms가 걸린다.
    /// 더미 단어로 미리 실행해두면 첫 롱프레스 맞춤법 교정 렉이 사라진다.
    private nonisolated static func primeTextChecker() {
        let checker = UITextChecker()
        let dummy = "hello"
        let range = NSRange(location: 0, length: dummy.utf16.count)
        _ = checker.rangeOfMisspelledWord(
            in: dummy, range: range, startingAt: 0, wrap: false, language: "en_US"
        )
        _ = UITextChecker.availableLanguages
    }
}
