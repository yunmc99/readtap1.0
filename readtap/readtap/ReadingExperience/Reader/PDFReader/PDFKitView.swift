import SwiftUI
import UIKit
import PDFKit

@MainActor
struct PDFKitView: UIViewRepresentable {
    private enum Timing {
            static let singleTapDebounce: TimeInterval = 0.25
        static let singleTapEventReentryWindow: TimeInterval = 0.45
        static let singleTapEventDuplicateDistance: CGFloat = 24
            static let twoFingerTapDebounce: TimeInterval = 0.28
            static let longPressToSingleTapCooldown: TimeInterval = 0.3
            static let longPressLookupChangeThrottle: TimeInterval = 0.04
            static let longPressStateRefreshThrottle: TimeInterval = 0.05
            static let selectionChangeCooldown: TimeInterval = 0.5
            static let selectionToLongPressSuppression: TimeInterval = 0.7
            static let longPressSingleTapCooldown: TimeInterval = 0.5
            static let singleTapReadinessDelay: TimeInterval = 0.0
            static let singleTapPostOpenSuppression: TimeInterval = 0.0
            static let singleTapRecoveryDebounce: TimeInterval = 0.25
        static let longPressTapRecoveryDebounce: TimeInterval = 0.45
        static let singleTapReenableDebounce: TimeInterval = 0.15
        static let twoFingerGestureSeparation: TimeInterval = 0.12
        static let layoutLongPressRefreshDelay: TimeInterval = 0.02
        static let programmaticPageTurnTimeout: TimeInterval = 0.6
        static let fileLoadRetryDelay: TimeInterval = 0.8
            static let gestureModeWarmupDelay: TimeInterval = 0
        static let geometryWarmupDelay: TimeInterval = 0.03
            static let geometryToGestureWarmupDelay: TimeInterval = 0.08
            static let boundaryWarmupDelay: TimeInterval = 0.03
            static let longPressReadinessDelay: TimeInterval = 0
            static let longPressFirstLookupDeferralDelay: TimeInterval = 0.12
            static let pdfReadyStabilizationDelay: TimeInterval = 0.05
            static let longPressStartupTapSuppression: TimeInterval = 0.35
            static let longPressSystemDisableRetryDelay: TimeInterval = 0.05
            static let longPressInitialLookupFallbackDelay: TimeInterval = 0.0
            static let longPressLookupFallbackCooldown: TimeInterval = 0.02
            } 

    private enum Threshold {
        static let tiny: CGFloat = 0.001
        static let small: CGFloat = 0.01
        static let medium: CGFloat = 0.02
    }

    private enum Gesture {
        static let minimumViewDimensionForLookup: CGFloat = 44
        static let dismissHorizontalTolerance: CGFloat = 80
        static let dismissThreshold: CGFloat = 140
        static let maxDismissDistance: CGFloat = 180
        static let popupYOffset: CGFloat = 8
        static let popupMinY: CGFloat = 24
        static let longPressFastScanDepth: Int = 10
        static let longPressAreaScanDepth: Int = 24
    }

        private enum LookupPoint {
            static let maxMovementCap: CGFloat = 14
            static let centerScale: CGFloat = 0.35
            static let diagonalScale: CGFloat = 0.65
            static let pagePointScale: CGFloat = 1000
            static let lookupBoundsInset: CGFloat = 10
            static let signatureQuantization: CGFloat = 12
            static let fallbackPressXRatio: CGFloat = 0.5
            static let sampleCount: Int = 17
            static let initialSampleCount: Int = 4
            static let initialColdStartSampleCount: Int = 2
            static let candidateDeltas: [CGPoint] = [
                .init(x: 0, y: 0),
                .init(x: centerScale, y: 0),
                .init(x: -centerScale, y: 0),
                .init(x: 0, y: centerScale),
                .init(x: 0, y: -centerScale),
                .init(x: diagonalScale, y: diagonalScale),
                .init(x: -diagonalScale, y: diagonalScale),
                .init(x: diagonalScale, y: -diagonalScale),
                .init(x: -diagonalScale, y: -diagonalScale),
                .init(x: 0.5, y: 0.5),
                .init(x: -0.5, y: 0.5),
                .init(x: 0.5, y: -0.5),
                .init(x: -0.5, y: -0.5),
                .init(x: 1, y: 0),
                .init(x: -1, y: 0),
                .init(x: 0, y: 1),
                .init(x: 0, y: -1),
                .init(x: 1.2, y: 0),
                .init(x: -1.2, y: 0),
                .init(x: 0, y: 1.2),
                .init(x: 0, y: -1.2),
                .init(x: 1.2, y: 1.2),
                .init(x: -1.2, y: 1.2),
                .init(x: 1.2, y: -1.2),
                .init(x: -1.2, y: -1.2)
            ]
        }

        private enum FirstLookupWarmup {
            static let maxChangedAttempts: Int = 2
        }

    private enum Layout {
        static let landscapePageBreakInset: CGFloat = 2
        static let ratioBoundary: CGFloat = 1.02
    }

    private enum PagePrefetch {
        static let initialRadius: Int = 1
        static let largeDocumentOpenRadius: Int = 1
        static let followRadius: Int = 1
        static let maxPagesPerPass: Int = 4
        static let openBackgroundDelay: TimeInterval = 0.18
        static let largeDocumentOpenBackgroundDelay: TimeInterval = 1.1
        static let largeDocumentLookupWarmupDelay: TimeInterval = 0.40
        static let initialDelay: TimeInterval = 0.15
        static let followDelay: TimeInterval = 0.12
        static let interPageDelay: TimeInterval = 0.05
        static let largeDocumentPageCountThreshold: Int = 200
        static let largeDocumentExtraDelay: TimeInterval = 0.12
        static let largeDocumentInterPageDelay: TimeInterval = 0.09
        static let largeDocumentMaxPagesPerPass: Int = 2
    }

    let documentURL: URL
    let bookId: String
    @Binding var currentPageIndex: Int
    @Binding var totalPages: Int
    @Binding var requestedPage: Int?
    @Binding var hasTextSelection: Bool
    @Binding var markupAction: PDFMarkupAction?
    @Binding var zoomRatio: CGFloat
    @Binding var shouldResetZoomOnPageNavigation: Bool
    @Binding var readerMode: ReaderInteractionMode
    @Binding var pdfViewRef: PDFView?
    let autoSaveEnabled: Bool
    let readerLongPressEnabled: Bool
    let lookupInteractionReady: Bool
    var onPDFViewReady: ((PDFView) -> Void)?
    var onPDFReady: (() -> Void)?
    let onSelection: (WordSelection, PDFView) -> Void
    let onOCRLookup: @MainActor (CGPoint, PDFView) -> WordSelection?
    let onLookupNeedsOCRProbe: @MainActor (UInt64, CGPoint, PDFView) -> Void
    let onReadingInteraction: () -> Void
    let onSingleTap: () -> Void
    let onLookupTapOutside: () -> Void
    let onTwoFingerTap: () -> Void
    var onLoadFailed: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            onOCRLookup: onOCRLookup,
            onLookupNeedsOCRProbe: onLookupNeedsOCRProbe,
            onReadingInteraction: onReadingInteraction,
            onSingleTap: onSingleTap,
            onLookupTapOutside: onLookupTapOutside,
            onTwoFingerTap: onTwoFingerTap,
            currentPageIndex: $currentPageIndex,
            totalPages: $totalPages,
            hasTextSelection: $hasTextSelection,
            zoomRatio: $zoomRatio,
            shouldResetZoomOnPageNavigation: $shouldResetZoomOnPageNavigation,
            readerMode: $readerMode,
            autoSaveEnabled: autoSaveEnabled,
            readerLongPressEnabled: readerLongPressEnabled,
            lookupInteractionReady: lookupInteractionReady
        )
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = ReadTapPDFView()
        // Start with auto-scaling enabled so the first render doesn't depend on an early (often zero)
        // `scaleFactorForSizeToFit` before layout has happened.
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.displaysPageBreaks = false
        pdfView.pageBreakMargins = .zero
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = ReaderVisualStyleMode.current.isRefined
            ? ReaderRefinedPalette.canvasUIColor
            : UIColor.clear
        pdfView.applyCanvasAppearance()
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.installZoomedPageSwipe()
        context.coordinator.loadDocumentAsync(
            from: documentURL,
            into: pdfView,
            onLoadFailed: onLoadFailed,
            onPDFReady: onPDFReady
        )
        context.coordinator.attach(to: pdfView)
        context.coordinator.lastDocumentURL = documentURL
        context.coordinator.queueStateMutation { [pdfView] in
            if self.pdfViewRef !== pdfView {
                self.pdfViewRef = pdfView
            }
            self.onPDFViewReady?(pdfView)
        }
        return pdfView
    }

    func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.detach(from: uiView)

        uiView.clearSelection()
        if let readerView = uiView as? ReadTapPDFView {
            readerView.forceClearSelection()
            readerView.clearLookupHighlight(immediate: true)
        }
        uiView.document = nil
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        // Keep coordinator closures in sync with the latest SwiftUI body evaluation
        // so captured values (e.g. readyGeneration) are never stale.
        context.coordinator.updateCallbacks(
            onSelection: onSelection,
            onOCRLookup: onOCRLookup,
            onLookupNeedsOCRProbe: onLookupNeedsOCRProbe,
            onReadingInteraction: onReadingInteraction,
            onSingleTap: onSingleTap,
            onLookupTapOutside: onLookupTapOutside,
            onTwoFingerTap: onTwoFingerTap
        )
        let needsDocument = context.coordinator.lastDocumentURL != documentURL || pdfView.document == nil
        if needsDocument {
            context.coordinator.loadDocumentAsync(
                from: documentURL,
                into: pdfView,
                onLoadFailed: onLoadFailed,
                onPDFReady: onPDFReady
            )
            context.coordinator.queueStateMutation {
                self.totalPages = 0
                self.currentPageIndex = 0
            }
        }
        if context.coordinator.areGesturesDetached() {
            context.coordinator.attach(to: pdfView)
        }
        if pdfViewRef !== pdfView {
            context.coordinator.queueStateMutation { [pdfView] in
                if self.pdfViewRef !== pdfView {
                    self.pdfViewRef = pdfView
                }
                self.onPDFViewReady?(pdfView)
            }
        }
        // Update bindings asynchronously to avoid "Modifying state during view update" issues.
        context.coordinator.scheduleBindingSyncIfNeeded(using: pdfView)
        context.coordinator.updateLayoutIfNeeded(using: pdfView)
        context.coordinator.updateInteractionIfNeeded(
            readerMode: readerMode,
            autoSaveEnabled: autoSaveEnabled,
            longPressEnabled: readerLongPressEnabled,
            lookupInteractionReady: lookupInteractionReady,
            using: pdfView
        )
        if pdfView.document != nil {
            context.coordinator.ensureGesturesHealthy(using: pdfView)
        }
        pdfView.backgroundColor = ReaderVisualStyleMode.current.isRefined
            ? ReaderRefinedPalette.canvasUIColor
            : UIColor.clear
        (pdfView as? ReadTapPDFView)?.applyCanvasAppearance()

        if let target = requestedPage, let doc = pdfView.document, target >= 0, target < doc.pageCount {
            if let page = doc.page(at: target) {
                pdfView.go(to: page)
                context.coordinator.queueStateMutation {
                    if self.currentPageIndex != target {
                        self.currentPageIndex = target
                    }
                    self.requestedPage = nil
                }
            }
        }

        if let action = markupAction, let view = pdfView as? ReadTapPDFView {
            switch action {
            case .highlight:
                view.highlightSelection(nil)
            case .underline:
                view.underlineSelection(nil)
            }
            context.coordinator.queueStateMutation {
                self.markupAction = nil
            }
        }
    }


        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private enum GestureMode: Equatable {
            case readingSingleTap
            case readingLongPress
            case nonReading
        }

        private enum GestureRuntimePhase: Equatable {
            case inactive
            case singleTapReady
            case longPressReady
            case longPressActive
        }

        private struct GestureState: Equatable {
            let mode: GestureMode
            let interactionAllowed: Bool
            let singleTapEnabled: Bool
            let twoFingerEnabled: Bool
            let lookupPressEnabled: Bool
            let pinchEnabled: Bool
            let navigationEnabled: Bool
            let systemLongPressEnabled: Bool
        }

        private struct GestureRefreshSignature: Equatable {
            let mode: GestureMode
            let interactionReady: Bool
            let singleTapReady: Bool
            let lookupReady: Bool
            let hostLongPress: Bool
            let readingMode: Bool
            let lookupInteractionReady: Bool
            let applyingProgrammaticScale: Bool
            let handlingPageChange: Bool
            let suppressSingleTap: Bool
            let needsSystemLongPressScan: Bool
            let recollect: Bool
            let readerMode: ReaderInteractionMode
            let viewID: ObjectIdentifier?

            init(
                from coordinator: Coordinator,
                recollect: Bool,
                viewID: ObjectIdentifier?
            ) {
                self.mode = coordinator.expectedGestureMode()
                self.interactionReady = coordinator.isInteractionReady
                self.singleTapReady = coordinator.isSingleTapGesturesReady
                self.lookupReady = coordinator.isLookupGesturesReady
                self.hostLongPress = coordinator.hostLongPressEnabled
                let readingMode = coordinator.readerMode.wrappedValue == .reading
                self.readingMode = readingMode
                self.lookupInteractionReady = coordinator.lookupInteractionReady
                self.applyingProgrammaticScale = coordinator.isApplyingProgrammaticScale
                self.handlingPageChange = coordinator.isHandlingPageChange
                self.suppressSingleTap = coordinator.shouldSuppressSingleTap
                self.needsSystemLongPressScan = readingMode && !coordinator.didCollectSystemLongPressesForCurrentView
                self.recollect = recollect
                self.readerMode = coordinator.readerMode.wrappedValue
                self.viewID = viewID
            }
        }

        private var onSelection: (WordSelection, PDFView) -> Void
        private var onOCRLookup: @MainActor (CGPoint, PDFView) -> WordSelection?
        private var onLookupNeedsOCRProbe: @MainActor (UInt64, CGPoint, PDFView) -> Void
        private var onReadingInteraction: () -> Void
        private var onSingleTap: () -> Void
        private var onLookupTapOutside: () -> Void
        private var onTwoFingerTap: () -> Void
        private var currentPageIndex: Binding<Int>
        private var totalPages: Binding<Int>
        private var hasTextSelection: Binding<Bool>
        private var zoomRatio: Binding<CGFloat>
        private var shouldResetZoomOnPageNavigation: Binding<Bool>
        private var readerMode: Binding<ReaderInteractionMode>
        private var hostAutoSaveEnabled: Bool
        private var lastAppliedAutoSaveEnabled: Bool?
        private var hostLongPressEnabled: Bool
        private var lastAppliedLongPressEnabled: Bool?
        private var lookupInteractionReady: Bool

        private weak var pdfView: PDFView?
        private weak var singleTap: UITapGestureRecognizer?
        private weak var lookupPress: UILongPressGestureRecognizer?
        private weak var twoFingerTap: UITapGestureRecognizer?
        private weak var pinchSnap: UIPinchGestureRecognizer?
        private weak var trackedScrollPanGesture: UIPanGestureRecognizer?
        private var systemLongPresses: [UILongPressGestureRecognizer] = []
        private var lastSelectionAt: Date?
        private let cooldown: TimeInterval = Timing.selectionChangeCooldown
        private var lastLookupPressAt: Date?
        private let singleTapDebounceInterval: TimeInterval = Timing.singleTapDebounce
        private let twoFingerTapDebounceInterval: TimeInterval = Timing.twoFingerTapDebounce
        private let longPressToSingleTapCooldown: TimeInterval = Timing.longPressToSingleTapCooldown
        private var lastSingleTapAt: Date?
        private var lastSingleTapDeliveryAt: Date?
        private var lastSingleTapDeliveryPoint: CGPoint?
        private var lastSingleTapDeliveryViewID: ObjectIdentifier?
        private var lastTwoFingerTapAt: Date?
        private var lastSuccessfulLongPressLookupAt: Date?
        private var lastLookupSelectionSignature: String?
        private var lastLookupWordSignature: String?
        private var appLifecycleObserver: NSObjectProtocol?
        private var isLookupActive = false
        private var suppressSingleTapUntil: Date?
        private var lastLookupProbePointKey: UInt64?
        private var lastLookupFallbackProbePointKey: UInt64?
        private var lastLookupFallbackAttemptAt: Date?
        private var lastLookupFallbackWindowStartedAt: Date?
        private var fallbackAttemptsInWindow: Int = 0
        private let longPressFallbackRetryWindow: TimeInterval = 0.30
        private var isFirstLongPressLookup = false
        private var isPrimingFirstLongPressLookup = false
        private var firstLongPressWarmupAttemptsLeft: Int = 0
        private var longPressLookupAttemptCount: Int = 0
        private var lastLookupChangedAt: Date?
        private var lastAppliedGestureMode: GestureMode?
        private var singleTapReenableWorkItem: Task<Void, Never>?
        private var lastLookupGestureAt: Date?
        private var didLookupForCurrentLongPress = false
        private var initialLongPressLocation: CGPoint?
        private var shouldDismissLookupArtifactsOnNextTap = false
        private var isApplyingProgrammaticScale = false
        private var isHandlingPageChange = false
#if DEBUG
        private var lastDebugLogSignatureByTag: [String: String] = [:]
        private var lastDebugLogAtByTag: [String: Date] = [:]
        private let debugGestureLogThrottle: TimeInterval = 0.15
#endif
        private var pendingLookupReset: Task<Void, Never>?
        private var lookupPressRecovery: Task<Void, Never>?
        private var pendingLookupSessionEndTask: Task<Void, Never>?
        private var pendingLookupTask: Task<Void, Never>?
        private var pendingLongPressRefresh: DispatchWorkItem?
        private var lastGestureRefreshAt = Date.distantPast
        private var isInteractionReady: Bool = false
        private var lastAppliedGestureState: GestureState?
        private var lastAppliedGestureViewID: ObjectIdentifier?
        private var lastScheduledGestureRefreshSignature: GestureRefreshSignature?
        private var lastAppliedGestureRefreshSignature: GestureRefreshSignature?
        private var didCollectSystemLongPressesForCurrentView = false
        private var systemLongPressCollectionViewID: ObjectIdentifier?
        private var systemLongPressCollectionGeneration = -1
        private var lastSystemLongPressScanAt = Date.distantPast
        private var isSingleTapGesturesReady: Bool = false
        private var isLookupGesturesReady: Bool = false
        private var gestureRuntimePhase: GestureRuntimePhase = .inactive
        private var pendingSelectionWorkTask: Task<Void, Never>?
        private var pendingProgrammaticPageTurn: PendingPageTurn?
        private var pendingProgrammaticPageTurnTimeout: DispatchWorkItem?
        private var pendingReadySignal: DispatchWorkItem?
        private var pendingFirstLongPressLookup: Task<Void, Never>?
        private var pendingLongPressLookupTask: Task<Void, Never>?
        private var hasCompletedInitialLookupWarmup: Bool = false
        private var hasBypassedInitialLookupWarmup: Bool = false
        private var hasDeferredInitialLongPressLookup: Bool = false
        private var isFirstLongPressAfterLoad: Bool = true
        private let enableLookupSessionGuard = true
        private var currentLookupSessionId: UInt64 = 0
        private var activeLookupSessionId: UInt64 = 0
        private var activeLookupPageIndex: Int = -1
        private var pendingSingleTapReadiness: Task<Void, Never>?
        private var pendingLookupPressReadiness: Task<Void, Never>?
        private var pendingInitialInteractionReadiness: Task<Void, Never>?
        private var cachedFitScale: CGFloat = 0
        private var cachedFitToWidthScale: CGFloat = 0
        private var lastObservedZoomRatio: CGFloat?
        fileprivate var lastDocumentURL: URL?
        private var lastLayoutSignature: LayoutSignature?
        private var lastPageBoxSize: CGSize?
        private var pendingBindingSync: Task<Void, Never>?
        private var pendingGeometryWarmup: Task<Void, Never>?
        private var pendingLookupBoundsWarmup: Task<Void, Never>?
        private var pendingOpenWarmupTask: Task<Void, Never>?
        private var pendingDocumentLoad: DispatchWorkItem?
        private var pendingDocumentLoadRetry: DispatchWorkItem?
        private let documentLoadQueue = DispatchQueue(
            label: "com.readtap.pdfkit.document-load",
            qos: .userInitiated
        )
        private var documentLoadGeneration: Int = 0
        private var readyDocumentLoadGeneration: Int = 0
        private var documentLoadInFlightURL: URL?
        private var isDocumentLoadInFlight = false
        private var lastDisplayBox: PDFDisplayBox?
        private var isProgrammaticSelectionClear = false
        private var lastAppliedReaderMode: ReaderInteractionMode?
        private var lastBoundDocumentRef: ObjectIdentifier?
        private var lastBoundPageCount: Int = -1
        private var lastBoundCurrentPage: Int = -1
        private var pendingPagePrefetch: DispatchWorkItem?
        private var prefetchedPageIndexes: Set<Int> = []
        private var pendingOpenPrefetchWork: DispatchWorkItem?
        private var pageLookupBoundsCache: [ObjectIdentifier: CGRect] = [:]
        private var pagesWithoutLookupBounds: Set<ObjectIdentifier> = []
        private let singleTapHapticGenerator = UIImpactFeedbackGenerator(style: .light)
        private let longPressLookupHapticGenerator = UIImpactFeedbackGenerator(style: .medium)
        private var didEmitLongPressHaptic = false
        private var pendingStateMutationWork: DispatchWorkItem?
        private var pendingStateMutations: [() -> Void] = []
        private var needsGestureReactivation: Bool = false
        private var hasSeenInitialPageChange = false

        private let minZoomRatio: CGFloat = 1.0
        private let maxZoomRatio: CGFloat = 6.0
        private let snapToFitThreshold: CGFloat = 1.02

        private func startLookupSession() -> UInt64 {
            guard enableLookupSessionGuard else { return 0 }
            currentLookupSessionId &+= 1
            if currentLookupSessionId == 0 {
                currentLookupSessionId = 1
            }
            activeLookupSessionId = currentLookupSessionId
            cancelLookupSessionEndTimer()
            #if DEBUG
            if shouldEmitDebug(tag: "lookupSession", signature: "start:\(activeLookupSessionId)") {
                print("[LongPressDebug] lookupSession start=\(activeLookupSessionId)")
            }
            #endif
            return activeLookupSessionId
        }

        private func isLookupSessionCurrent(_ sessionId: UInt64) -> Bool {
            guard enableLookupSessionGuard else { return true }
            return sessionId != 0 && activeLookupSessionId == sessionId
        }

        private func currentLookupPageIndex(for pdfView: PDFView) -> Int {
            guard let page = pdfView.currentPage else { return -1 }
            return pdfView.document?.index(for: page) ?? -1
        }

        private func isLookupSessionUsable(_ sessionId: UInt64) -> Bool {
            guard enableLookupSessionGuard else { return true }
            guard isLookupSessionCurrent(sessionId) else { return false }
            guard activeLookupPageIndex >= 0 else { return false }
            guard let pdfView else { return false }
            return currentLookupPageIndex(for: pdfView) == activeLookupPageIndex
        }

        private func endLookupSession() {
            guard enableLookupSessionGuard else { return }
            #if DEBUG
            if activeLookupSessionId != 0,
               shouldEmitDebug(tag: "lookupSession", signature: "end:\(activeLookupSessionId)") {
                print("[LongPressDebug] lookupSession end=\(activeLookupSessionId)")
            }
            #endif
            activeLookupSessionId = 0
        }

        private func cancelLookupSessionEndTimer() {
            pendingLookupSessionEndTask?.cancel()
            pendingLookupSessionEndTask = nil
        }

        private func invalidateLookupSessionForPageChange() {
            endLookupSession()
            activeLookupPageIndex = -1
            cancelLookupSessionEndTimer()
            cancelLookupTransitionState()
            pendingLookupPressReadiness?.cancel()
            pendingLookupPressReadiness = nil
            pendingLookupTask?.cancel()
            pendingLookupTask = nil
            pendingLookupReset?.cancel()
            pendingLookupReset = nil
            lookupPressRecovery?.cancel()
            lookupPressRecovery = nil
            pendingLongPressLookupTask?.cancel()
            pendingLongPressLookupTask = nil
            pendingFirstLongPressLookup?.cancel()
            pendingFirstLongPressLookup = nil
        }

        private func scheduleLookupSessionEnd(
            sessionId: UInt64,
            preserveDismissHint: Bool,
            delay: TimeInterval
        ) {
            guard delay > 0 else {
                resetLookupPressState(force: true, preserveDismissHint: preserveDismissHint)
                return
            }
            cancelLookupSessionEndTimer()
            let sessionToken = sessionId
            pendingLookupSessionEndTask = Task { [weak self] in
                do {
                    let nanos = UInt64(delay * 1_000_000_000)
                    if nanos > 0 {
                        try await Task.sleep(nanoseconds: nanos)
                    }
                } catch {
                    return
                }
                guard let self else { return }
                guard self.isLookupSessionCurrent(sessionToken) else { return }
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    self.resetLookupPressState(force: true, preserveDismissHint: preserveDismissHint)
                }
            }
        }

        private struct LayoutSignature: Equatable {
            let size: CGSize
            let isLandscape: Bool
        }

        private struct PendingPageTurn: Equatable {
            let token: UUID
            let intendedZoomRatio: CGFloat
            let direction: Direction

            enum Direction: Equatable {
                case next
                case previous
            }
        }

        init(onSelection: @escaping (WordSelection, PDFView) -> Void,
             onOCRLookup: @escaping @MainActor (CGPoint, PDFView) -> WordSelection?,
             onLookupNeedsOCRProbe: @escaping @MainActor (UInt64, CGPoint, PDFView) -> Void,
             onReadingInteraction: @escaping () -> Void,
             onSingleTap: @escaping () -> Void,
             onLookupTapOutside: @escaping () -> Void,
             onTwoFingerTap: @escaping () -> Void,
             currentPageIndex: Binding<Int>,
             totalPages: Binding<Int>,
             hasTextSelection: Binding<Bool>,
             zoomRatio: Binding<CGFloat>,
             shouldResetZoomOnPageNavigation: Binding<Bool>,
             readerMode: Binding<ReaderInteractionMode>,
             autoSaveEnabled: Bool,
             readerLongPressEnabled: Bool,
             lookupInteractionReady: Bool) {
            self.onSelection = onSelection
            self.onOCRLookup = onOCRLookup
            self.onLookupNeedsOCRProbe = onLookupNeedsOCRProbe
            self.onReadingInteraction = onReadingInteraction
            self.onSingleTap = onSingleTap
            self.onLookupTapOutside = onLookupTapOutside
            self.onTwoFingerTap = onTwoFingerTap
            self.currentPageIndex = currentPageIndex
            self.totalPages = totalPages
            self.hasTextSelection = hasTextSelection
            self.zoomRatio = zoomRatio
            self.shouldResetZoomOnPageNavigation = shouldResetZoomOnPageNavigation
            self.readerMode = readerMode
            self.hostAutoSaveEnabled = autoSaveEnabled
            self.lastAppliedAutoSaveEnabled = autoSaveEnabled
            self.hostLongPressEnabled = readerLongPressEnabled
            self.lastAppliedLongPressEnabled = readerLongPressEnabled
            self.lookupInteractionReady = lookupInteractionReady
            super.init()
        }

        /// Refresh all host-provided closures so the coordinator never holds stale captures.
        func updateCallbacks(
            onSelection: @escaping (WordSelection, PDFView) -> Void,
            onOCRLookup: @escaping @MainActor (CGPoint, PDFView) -> WordSelection?,
            onLookupNeedsOCRProbe: @escaping @MainActor (UInt64, CGPoint, PDFView) -> Void,
            onReadingInteraction: @escaping () -> Void,
            onSingleTap: @escaping () -> Void,
            onLookupTapOutside: @escaping () -> Void,
            onTwoFingerTap: @escaping () -> Void
        ) {
            self.onSelection = onSelection
            self.onOCRLookup = onOCRLookup
            self.onLookupNeedsOCRProbe = onLookupNeedsOCRProbe
            self.onReadingInteraction = onReadingInteraction
            self.onSingleTap = onSingleTap
            self.onLookupTapOutside = onLookupTapOutside
            self.onTwoFingerTap = onTwoFingerTap
        }

        func attach(to pdfView: PDFView) {
            isDetached = false
            detach(from: self.pdfView)
            self.pdfView = pdfView
            let viewID = ObjectIdentifier(pdfView)
            systemLongPressCollectionViewID = viewID
            systemLongPressCollectionGeneration = -1

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectionChanged),
                name: Notification.Name.PDFViewSelectionChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePageChanged),
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScaleChanged),
                name: Notification.Name.PDFViewScaleChanged,
                object: pdfView
            )

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            singleTap.numberOfTouchesRequired = 1
            singleTap.cancelsTouchesInView = false

            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTapsRequired = 1
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.cancelsTouchesInView = false

            singleTap.delegate = self
            twoFingerTap.delegate = self

            pdfView.addGestureRecognizer(singleTap)
            pdfView.addGestureRecognizer(twoFingerTap)
            self.singleTap = singleTap
            self.twoFingerTap = twoFingerTap

            // Custom long-press for lookup without the system magnifier.
            let lookupPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLookupLongPress(_:)))
            lookupPress.minimumPressDuration = isFirstLongPressAfterLoad
                ? ReaderLookupLimits.longPressFirstTouchMinimumPressDuration
                : ReaderLookupLimits.longPressMinimumPressDuration
            lookupPress.allowableMovement = ReaderLookupLimits.longPressAllowableMovement
            lookupPress.numberOfTouchesRequired = 1
            lookupPress.cancelsTouchesInView = false
            lookupPress.delaysTouchesBegan = false
            lookupPress.delegate = self
            pdfView.addGestureRecognizer(lookupPress)
            self.lookupPress = lookupPress

            // Snap-to-fit should happen when the user finishes pinching, not mid-gesture.
            let pinchSnap = UIPinchGestureRecognizer(target: self, action: #selector(handleUserPinch(_:)))
            pinchSnap.cancelsTouchesInView = false
            pinchSnap.delegate = self
            pdfView.addGestureRecognizer(pinchSnap)
            self.pinchSnap = pinchSnap
            ensureScrollInteractionTracking(using: pdfView)

            // Ensure a clean initial gesture state before first user interaction.
            clearSingleTapSuppression()
            longPressLookupAttemptCount = 0
            lastLookupFallbackProbePointKey = nil
            lastLookupFallbackAttemptAt = nil
            gestureRuntimePhase = .inactive
            isLookupActive = false
            lastLookupGestureAt = nil
            lastLookupPressAt = nil
            hasSeenInitialPageChange = false
            isInteractionReady = false
            isSingleTapGesturesReady = false
            isLookupGesturesReady = false
            didCollectSystemLongPressesForCurrentView = false
            lastSystemLongPressScanAt = .distantPast
            lastScheduledGestureRefreshSignature = nil
            lastAppliedGestureRefreshSignature = nil
            applyGestureMode(using: pdfView, recollect: false)
            scheduleRefreshLongPressEnabled(
                recollect: true,
                delay: Timing.layoutLongPressRefreshDelay
            )
            needsGestureReactivation = true
            appLifecycleObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.forceResetLookupInteractions()
            }

            scheduleBindingSyncIfNeeded(using: pdfView)
            updateInteractionMode(readerMode.wrappedValue, using: pdfView)
        }

        fileprivate func areGesturesDetached() -> Bool {
            return singleTap == nil
                || lookupPress == nil
                || twoFingerTap == nil
                || pinchSnap == nil
        }

        fileprivate func consumePendingGestureReactivation() -> Bool {
            let shouldReactivate = needsGestureReactivation
            needsGestureReactivation = false
            return shouldReactivate
        }

        private var isDetached: Bool = false

        fileprivate func detach(from pdfView: PDFView?) {
            isDocumentLoadInFlight = false
            documentLoadInFlightURL = nil
            guard !isDetached else { return }
            isDetached = true

            if let existing = pdfView {
                if let singleTap {
                    existing.removeGestureRecognizer(singleTap)
                }
                if let twoFingerTap {
                    existing.removeGestureRecognizer(twoFingerTap)
                }
                if let lookupPress {
                    existing.removeGestureRecognizer(lookupPress)
                }
                if let pinchSnap {
                    existing.removeGestureRecognizer(pinchSnap)
                }
            }
            if let trackedScrollPanGesture {
                trackedScrollPanGesture.removeTarget(self, action: #selector(handleReaderScrollPan(_:)))
            }

            NotificationCenter.default.removeObserver(
                self,
                name: Notification.Name.PDFViewSelectionChanged,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: Notification.Name.PDFViewPageChanged,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: Notification.Name.PDFViewScaleChanged,
                object: nil
            )
            systemLongPressCollectionViewID = nil
            systemLongPressCollectionGeneration = -1
            lastSystemLongPressScanAt = .distantPast
            if let observer = appLifecycleObserver {
                NotificationCenter.default.removeObserver(observer)
                appLifecycleObserver = nil
            }

            pendingGeometryWarmup?.cancel()
            pendingLookupBoundsWarmup?.cancel()
            pendingOpenWarmupTask?.cancel()
            pendingDocumentLoad?.cancel()
            pendingDocumentLoadRetry?.cancel()
            pendingLongPressRefresh?.cancel()
            pendingReadySignal?.cancel()
            pendingLookupPressReadiness?.cancel()
            pendingInitialInteractionReadiness?.cancel()
            pendingSelectionWorkTask?.cancel()
            pendingProgrammaticPageTurnTimeout?.cancel()
            pendingOpenPrefetchWork?.cancel()
            cancelPendingPagePrefetch()
            pendingLookupReset?.cancel()
            lookupPressRecovery?.cancel()
            singleTapReenableWorkItem?.cancel()
            pendingSingleTapReadiness?.cancel()
            pendingFirstLongPressLookup?.cancel()
            pendingStateMutationWork?.cancel()

            pendingGeometryWarmup = nil
            pendingLookupBoundsWarmup = nil
            pendingOpenWarmupTask = nil
            pendingDocumentLoad = nil
            pendingDocumentLoadRetry = nil
            pendingLongPressRefresh = nil
            pendingReadySignal = nil
            pendingLookupPressReadiness = nil
            pendingInitialInteractionReadiness = nil
            pendingSelectionWorkTask = nil
            pendingProgrammaticPageTurnTimeout = nil
            pendingLookupReset = nil
            lookupPressRecovery = nil
            singleTapReenableWorkItem = nil
            pendingSingleTapReadiness = nil
            pendingFirstLongPressLookup = nil
            pendingStateMutationWork = nil
            pendingPagePrefetch = nil
            pendingOpenPrefetchWork = nil
            pendingStateMutations.removeAll(keepingCapacity: true)
            hasCompletedInitialLookupWarmup = false
            hasBypassedInitialLookupWarmup = false
            hasDeferredInitialLongPressLookup = false
            pendingProgrammaticPageTurn = nil
            pendingDocumentLoadGeneration()
            prefetchedPageIndexes.removeAll(keepingCapacity: true)

            pageLookupBoundsCache.removeAll()
            pagesWithoutLookupBounds.removeAll()
            lastLookupTaskReset()

            singleTap = nil
            lookupPress = nil
            twoFingerTap = nil
            pinchSnap = nil
            trackedScrollPanGesture = nil
            self.pdfView = nil
            systemLongPresses.removeAll()

            isInteractionReady = false
            isSingleTapGesturesReady = false
            isLookupGesturesReady = false
            didCollectSystemLongPressesForCurrentView = false
            lastLookupPressAt = nil
            suppressSingleTapUntil = nil
            gestureRuntimePhase = .inactive
            lastLookupSelectionSignature = nil
            lastLookupWordSignature = nil
            didLookupForCurrentLongPress = false
            shouldDismissLookupArtifactsOnNextTap = false
            isFirstLongPressLookup = false
            isPrimingFirstLongPressLookup = false
            firstLongPressWarmupAttemptsLeft = 0
            longPressLookupAttemptCount = 0
            lastLookupFallbackProbePointKey = nil
            lastLookupFallbackAttemptAt = nil
            lastLookupChangedAt = nil
            isLookupActive = false
            lastAppliedGestureMode = nil
            lastAppliedGestureState = nil
            lastAppliedGestureViewID = nil
            lastAppliedReaderMode = nil
            lastScheduledGestureRefreshSignature = nil
            lastAppliedGestureRefreshSignature = nil
            lastObservedZoomRatio = nil
            isApplyingProgrammaticScale = false
            isHandlingPageChange = false
            didEmitLongPressHaptic = false
#if DEBUG
            lastDebugLogSignatureByTag.removeAll(keepingCapacity: true)
            lastDebugLogAtByTag.removeAll(keepingCapacity: true)
#endif
        }

        private func pendingDocumentLoadGeneration() {
            documentLoadGeneration += 1
            readyDocumentLoadGeneration = 0
            hasCompletedInitialLookupWarmup = false
            hasBypassedInitialLookupWarmup = false
            lastBoundDocumentRef = nil
            lastBoundPageCount = -1
            lastBoundCurrentPage = -1
            prefetchedPageIndexes.removeAll(keepingCapacity: true)
            isDocumentLoadInFlight = false
            documentLoadInFlightURL = nil
            pendingOpenWarmupTask?.cancel()
            pendingOpenWarmupTask = nil
        }

        private func bypassInitialLookupWarmup() {
            pendingOpenWarmupTask?.cancel()
            pendingOpenWarmupTask = nil
            pendingGeometryWarmup?.cancel()
            pendingGeometryWarmup = nil
            pendingLookupBoundsWarmup?.cancel()
            pendingLookupBoundsWarmup = nil
            pendingOpenPrefetchWork?.cancel()
            pendingOpenPrefetchWork = nil
            cancelPendingPagePrefetch()
            hasBypassedInitialLookupWarmup = true
        }

        private func clearDocumentLoadInFlight(for requestToken: Int) {
            guard requestToken == documentLoadGeneration else { return }
            isDocumentLoadInFlight = false
            if documentLoadInFlightURL != nil {
                documentLoadInFlightURL = nil
            }
        }

        private func enqueueStateMutation(_ mutation: @escaping () -> Void) {
            pendingStateMutations.append(mutation)
            guard pendingStateMutationWork == nil else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let mutations = self.pendingStateMutations
                self.pendingStateMutations.removeAll(keepingCapacity: true)
                self.pendingStateMutationWork = nil
                for mutation in mutations {
                    mutation()
                }
            }
            pendingStateMutationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: work)
        }

        private func queueBindingValue<T: Equatable>(_ binding: Binding<T>, to value: T) {
            enqueueStateMutation { [binding] in
                if binding.wrappedValue != value {
                    binding.wrappedValue = value
                }
            }
        }

        fileprivate func queueStateMutation(_ mutation: @escaping () -> Void) {
            enqueueStateMutation(mutation)
        }

        private func lastLookupTaskReset() {
            pendingLookupTask?.cancel()
            pendingLookupTask = nil
            pendingLongPressLookupTask?.cancel()
            pendingLongPressLookupTask = nil
            pendingLookupReset?.cancel()
            pendingLookupReset = nil
            lookupPressRecovery?.cancel()
            lookupPressRecovery = nil
            isPrimingFirstLongPressLookup = false
            firstLongPressWarmupAttemptsLeft = 0
            longPressLookupAttemptCount = 0
            lastLookupFallbackProbePointKey = nil
            lastLookupFallbackAttemptAt = nil
            cancelInitialLongPressLookupDelay()
        }

        func reapplyZoomAfterLayout() {
            let shouldRecollect = expectedGestureMode() == .readingSingleTap
            scheduleRefreshLongPressEnabled(recollect: shouldRecollect, delay: Timing.layoutLongPressRefreshDelay)
            guard let pdfView else { return }
            let ratio = normalizedZoomRatio(
                resolvedZoomRatio(using: pdfView, fallback: zoomRatio.wrappedValue)
            )
            applyZoomRatio(ratio, resetPosition: false)
        }

        deinit {
            // Cleanup is performed in PDFKitView.dismantleUIView(_:coordinator:).
            // Keeping deinit intentionally minimal avoids dealloc-path races with weak references.
        }

        func updateInteractionMode(_ mode: ReaderInteractionMode, using pdfView: PDFView) {
                self.pdfView = pdfView
            if mode == .writing {
                clearSelectionIfNeeded(on: pdfView)
                if hasTextSelection.wrappedValue {
                    queueBindingValue(hasTextSelection, to: false)
                }
            } else if lastAppliedReaderMode == .writing {
                // Recompute the reading layout on next update tick.
                lastLayoutSignature = nil
                updateLayoutIfNeeded(using: pdfView)
            }
            lastAppliedReaderMode = mode
            transitionGestureRuntime(to: desiredGestureRuntimePhase(), using: pdfView)
        }

        func updateInteractionIfNeeded(
            readerMode: ReaderInteractionMode,
            autoSaveEnabled: Bool,
            longPressEnabled: Bool,
            lookupInteractionReady: Bool,
            using pdfView: PDFView
        ) {
            let modeChanged = lastAppliedReaderMode != readerMode
            let autoSaveChanged = lastAppliedAutoSaveEnabled != autoSaveEnabled
            let longPressChanged = lastAppliedLongPressEnabled != longPressEnabled
            let lookupReadyChanged = self.lookupInteractionReady != lookupInteractionReady

            if modeChanged {
                updateInteractionMode(readerMode, using: pdfView)
            }

            if longPressChanged || lookupReadyChanged {
                // Update AFTER calling setLookupLongPressEnabled so the internal
                // lookupReadyTransition check sees the old vs new difference.
                setLookupLongPressEnabled(longPressEnabled, lookupInteractionReady: lookupInteractionReady)
                self.lookupInteractionReady = lookupInteractionReady
            }

            if autoSaveChanged {
                hostAutoSaveEnabled = autoSaveEnabled
                lastAppliedAutoSaveEnabled = autoSaveEnabled
                lastLookupSelectionSignature = nil
                lastLookupWordSignature = nil
                if hasTextSelection.wrappedValue {
                    queueBindingValue(hasTextSelection, to: false)
                }
                pdfView.clearSelection()
                if isLookupActive {
                    resetLookupPressState(force: true)
                }
                clearSingleTapSuppression()
                lastAppliedGestureState = nil
                lastAppliedGestureViewID = nil
                lastAppliedGestureMode = nil
                (pdfView as? ReadTapPDFView)?.refreshAutoSavePreference()
                transitionGestureRuntime(to: desiredGestureRuntimePhase(), using: pdfView)
                applyGestureMode(using: pdfView, recollect: true)
            }
        }

        fileprivate func reactivateGesturesAfterReopen(using pdfView: PDFView) {
            guard readerMode.wrappedValue == .reading else { return }
            clearSingleTapSuppression()

            if !isInteractionReady {
                if pendingInitialInteractionReadiness == nil {
                    scheduleInitialInteractionReadiness(
                        delay: Timing.singleTapReadinessDelay,
                        generation: documentLoadGeneration,
                        using: pdfView
                    )
                }
                scheduleRefreshLongPressEnabled(
                    recollect: true,
                    delay: Timing.layoutLongPressRefreshDelay
                )
                return
            }

            if isLookupActive {
                resetLookupPressState(force: true)
            }

            if expectedGestureMode() == .readingLongPress,
               longPressEnabled(),
               !isLookupGesturesReady,
               pendingLookupPressReadiness == nil {
                ensureLookupPressReadinessIfNeeded()
            }

            if !isSingleTapGesturesReady && pendingSingleTapReadiness == nil {
                scheduleSingleTapReadiness(
                    delay: 0,
                    generation: documentLoadGeneration,
                    using: pdfView
                )
            }

            transitionGestureRuntime(to: desiredGestureRuntimePhase(), using: pdfView)
            // During same-document page changes, gesture recognizers don't change.
            // Only recollect on document load (didCollect already false for new docs).
            applyGestureMode(using: pdfView, recollect: false)
        }

        fileprivate func ensureGesturesHealthy(using pdfView: PDFView) {
            guard readerMode.wrappedValue == .reading else {
                return
            }
            transitionGestureRuntime(to: desiredGestureRuntimePhase(), using: pdfView)

            if needsGestureReactivation {
                needsGestureReactivation = false
                reactivateGesturesAfterReopen(using: pdfView)
                // Fall through to the safety-net below instead of returning,
                // so lookupPress.isEnabled is reconciled even after reactivation.
            }

            if isInteractionReady == false {
                if pendingInitialInteractionReadiness == nil {
                    scheduleInitialInteractionReadiness(
                        delay: Timing.singleTapReadinessDelay,
                        generation: documentLoadGeneration,
                        using: pdfView
                    )
                }
                scheduleRefreshLongPressEnabled(recollect: true, delay: Timing.layoutLongPressRefreshDelay)
                return
            }

            if shouldDismissLookupArtifactsOnNextTap {
                resetLookupPressState(force: true)
            }

            if isSingleTapGesturesReady == false && pendingSingleTapReadiness == nil {
                scheduleSingleTapReadiness(
                    delay: 0,
                    generation: documentLoadGeneration,
                    using: pdfView
                )
            }

            if isLookupGesturesReady == false && pendingLookupPressReadiness == nil {
                ensureLookupPressReadinessIfNeeded()
            }

            // Safety-net: reconcile gestureRuntimePhase and lookupPress.isEnabled
            // with the current coordinator state on every updateUIView cycle.
            // Multiple coordinators or async bind() timing can leave these
            // out of sync even though all conditions for long-press are met.
            let desiredPhase = desiredGestureRuntimePhase()
            if gestureRuntimePhase != desiredPhase {
                #if DEBUG
                if shouldEmitDebug(tag: "ensureGesturesHealthy", signature: "\(gestureRuntimePhase)->\(desiredPhase)") {
                    print("[LongPressDebug] ensureGesturesHealthy phase fix: \(gestureRuntimePhase) -> \(desiredPhase)")
                }
                #endif
                gestureRuntimePhase = desiredPhase
            }
            applyGestureMode(using: pdfView, recollect: false)
        }

        private func desiredGestureRuntimePhase() -> GestureRuntimePhase {
            guard readerMode.wrappedValue == .reading else { return .inactive }

            switch expectedGestureMode() {
            case .readingLongPress:
                return isLookupActive ? .longPressActive : .longPressReady
            case .readingSingleTap:
                return .singleTapReady
            case .nonReading:
                return .inactive
            }
        }

        private func transitionGestureRuntime(to next: GestureRuntimePhase, using pdfView: PDFView?) {
            guard gestureRuntimePhase != next else { return }
            gestureRuntimePhase = next
            guard let pdfView else { return }
            applyGestureMode(using: pdfView, recollect: false)
        }

        private func isSingleTapRuntimeEnabled() -> Bool {
            return readerMode.wrappedValue == .reading
                && !isApplyingProgrammaticScale
                && !isHandlingPageChange
                && gestureRuntimePhase != .longPressActive
        }

        private func isLongPressRuntimeEnabled() -> Bool {
            return gestureRuntimePhase == .longPressReady || gestureRuntimePhase == .longPressActive
        }

        private func shouldAllowSingleTapFlow() -> Bool {
            return readerMode.wrappedValue == .reading
                && gestureRuntimePhase != .longPressActive
                && !shouldSuppressSingleTap
                && !isApplyingProgrammaticScale
        }

        private func shouldAllowLookupFlow() -> Bool {
            return readerMode.wrappedValue == .reading
                && longPressEnabled()
                && !isApplyingProgrammaticScale
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard expectedGestureMode() != .nonReading else { return false }
            if gestureRecognizer === singleTap || otherGestureRecognizer === singleTap ||
                gestureRecognizer === lookupPress || otherGestureRecognizer === lookupPress {
                return false
            }
            if gestureRecognizer is UILongPressGestureRecognizer && otherGestureRecognizer is UILongPressGestureRecognizer {
                return false
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === singleTap, otherGestureRecognizer === lookupPress {
                // Keep single-tap responsive. Requiring lookup long-press to fail here can
                // stall tap delivery and trigger "gesture gate timed out" under reopen/rebind
                // transitions. Long-press already checks readystate/suppression paths internally.
                return false
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Force PDFKit's internal long-press (text selection) to fail when our lookup gesture succeeds
            if gestureRecognizer === lookupPress, 
               otherGestureRecognizer is UILongPressGestureRecognizer,
               otherGestureRecognizer !== lookupPress {
                return true
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === singleTap {
                if shouldDismissLookupArtifactsOnNextTap {
                    return readerMode.wrappedValue == .reading
                        && expectedGestureMode() != .nonReading
                        && !isApplyingProgrammaticScale
                }
                return readerMode.wrappedValue == .reading
                    && !isApplyingProgrammaticScale
            }

            if gestureRecognizer === twoFingerTap {
                return readerMode.wrappedValue == .reading
                    && expectedGestureMode() != .nonReading
                    && !isLookupActive
                    && !isApplyingProgrammaticScale
            }

            if gestureRecognizer === lookupPress {
                let result = readerMode.wrappedValue == .reading
                    && longPressEnabled()
                    && !isApplyingProgrammaticScale
                #if DEBUG
                if !result {
                    if shouldEmitDebug(tag: "shouldReceiveTouch", signature: "reading=\(readerMode.wrappedValue == .reading)|mode=\(expectedGestureMode())|interactionReady=\(isInteractionReady)|longPressEnabled=\(longPressEnabled())|programmaticScale=\(isApplyingProgrammaticScale)|pageChange=\(isHandlingPageChange)") {
                        print("[LongPressDebug] shouldReceiveTouch BLOCKED: reading=\(readerMode.wrappedValue == .reading) mode=\(expectedGestureMode()) interactionReady=\(isInteractionReady) longPressEnabled=\(longPressEnabled()) programmaticScale=\(isApplyingProgrammaticScale) pageChange=\(isHandlingPageChange)")
                    }
                }
                #endif
                return result
            }

            if let longPress = gestureRecognizer as? UILongPressGestureRecognizer,
               readerMode.wrappedValue == .reading,
               longPress !== lookupPress {
                return !isLongPressMode()
            }

            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard readerMode.wrappedValue == .reading else { return false }
            guard pdfView != nil else { return false }

            if gestureRecognizer === singleTap {
                if shouldDismissLookupArtifactsOnNextTap {
                    return true
                }
                return !isApplyingProgrammaticScale
            }
                if gestureRecognizer === lookupPress {
                    guard longPressEnabled() else {
                    #if DEBUG
                    if shouldEmitDebug(tag: "shouldBegin", signature: "longPressEnabled=false") {
                        print("[LongPressDebug] shouldBegin BLOCKED: longPressEnabled=false")
                    }
                    #endif
                    resetLookupPressState(force: true)
                    return false
                    }
                    if !isInteractionReady {
                        #if DEBUG
                        if shouldEmitDebug(tag: "shouldBegin", signature: "interactionReady=false") {
                            print("[LongPressDebug] shouldBegin BLOCKED: interactionReady=false")
                        }
                        #endif
                        return true
                    }
                    if !isLookupGesturesReady && isInteractionReady {
                        #if DEBUG
                        if shouldEmitDebug(tag: "shouldBegin", signature: "lookupGesturesReady=false") {
                            print("[LongPressDebug] shouldBegin WAIT: lookupGesturesReady=false")
                        }
                        #endif
                        ensureLookupPressReadinessIfNeeded()
                        return true
                    }
                    if let pv = pdfView {
                        let location = gestureRecognizer.location(in: pv)
                        if !hasTextAtPressLocation(location, in: pv) {
                            return false
                        }
                    }
                    #if DEBUG
                if shouldEmitDebug(tag: "shouldBegin", signature: "allowed") {
                    print("[LongPressDebug] shouldBegin ALLOWED")
                }
                #endif
                return true
            }
            return true
        }

        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            #if DEBUG
            let signature = [
                "mode=\(readerMode.wrappedValue)",
                "interactionReady=\(isInteractionReady)",
                "singleTapReady=\(isSingleTapGesturesReady)",
                "lookupReady=\(isLookupGesturesReady)",
                "suppress=\(shouldSuppressSingleTap)",
                "lookupActive=\(isLookupActive)"
            ].joined(separator: "|")
            if shouldEmitDebug(tag: "singleTapGesture", signature: signature) {
                debugSingleTapState("singleTapGesture")
            }
            #endif
            guard gesture.state == .ended else { return }
            let now = Date()
            let location = gesture.view.flatMap { gesture.location(in: $0) }
            if let targetView = gesture.view as? PDFView {
                if shouldDropDuplicateSingleTapEvent(at: targetView, timestamp: now, location: location) {
                    #if DEBUG
                    if shouldEmitDebug(tag: "singleTapGesture", signature: "duplicate-event") {
                        debugSingleTapState("singleTapDuplicate")
                    }
                    #endif
                    return
                }
                recordSingleTapDelivery(at: targetView, timestamp: now, location: location)
            }

            let decision = PDFTapSingleTapPolicy.decide(
                readerMode: readerMode.wrappedValue,
                shouldDismissLookupArtifactsOnNextTap: shouldDismissLookupArtifactsOnNextTap,
                isInteractionReady: isInteractionReady,
                isLookupActive: isLookupActive,
                didLookupForCurrentLongPress: didLookupForCurrentLongPress,
                canHandleSingleTapGesture: canHandleSingleTapGesture(),
                now: now,
                lastSingleTapAt: lastSingleTapAt,
                lastLookupPressAt: lastLookupPressAt,
                lastTwoFingerTapAt: lastTwoFingerTapAt,
                singleTapDebounceInterval: singleTapDebounceInterval,
                longPressToSingleTapCooldown: longPressToSingleTapCooldown,
                twoFingerTapDebounceInterval: twoFingerTapDebounceInterval
            )

            if decision.reason != "normal_single_tap" {
                if decision.reason != "single_tap_not_ready" {
                    #if DEBUG
                    if shouldEmitDebug(tag: "singleTapDecision", signature: decision.reason) {
                        debugSingleTapState("singleTapDecision")
                    }
                    #endif
                }
            }

            if decision.shouldResetLookupArtifacts {
                resetLookupPressState(force: false)
                onLookupTapOutside()
            }

            if decision.shouldDropEvent {
                return
            }
            if decision.shouldInvokeSingleTap == false {
                return
            }
            lastSingleTapAt = now

            guard readerMode.wrappedValue == .reading else { return }
            guard !isLookupActive else { return }
            guard let pdfView else {
                onSingleTap()
                return
            }

            // Clear stale text selection and keep the single-tap flow.
            if decision.shouldClearSelection && (hasTextSelection.wrappedValue || pdfView.currentSelection != nil) {
                pdfView.clearSelection()
                queueBindingValue(hasTextSelection, to: false)
            }

            if decision.shouldEmitHaptic {
                singleTapHapticGenerator.impactOccurred()
            }
            onSingleTap()
        }

        @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard readerMode.wrappedValue == .reading else { return }
            let now = Date()
            if let last = lastTwoFingerTapAt, now.timeIntervalSince(last) < twoFingerTapDebounceInterval {
                return
            }
            lastTwoFingerTapAt = now
            onTwoFingerTap()
            lastLookupPressAt = now
        }

        @objc private func handlePageChanged() {
            invalidateLookupSessionForPageChange()
            let shouldResetHandlingPageChange = isHandlingPageChange
            defer {
                if shouldResetHandlingPageChange {
                    isHandlingPageChange = false
                }
            }

            guard let pdfView, let doc = pdfView.document, let page = pdfView.currentPage else { return }
            ensureScrollInteractionTracking(using: pdfView)
            if hasSeenInitialPageChange {
                onReadingInteraction()
            } else {
                hasSeenInitialPageChange = true
            }
            // Defer the expensive gesture scan until after the transition settles.
            scheduleRefreshLongPressEnabled(recollect: false, delay: Timing.layoutLongPressRefreshDelay)
            let index = doc.index(for: page)
            queueBindingValue(currentPageIndex, to: index)
            queueBindingValue(totalPages, to: doc.pageCount)
            // prefetch는 ContentView.onChange(of: currentPageIndex)에서
            // OCR debounce 후 트리거되므로 여기서 중복 호출 제거.
            syncZoomRatioFromView(pdfView)

            let fit = cachedFitScale > 0 ? cachedFitScale : pdfView.scaleFactorForSizeToFit
            if fit > 0 {
                cachedFitScale = fit
                let ratio = normalizedZoomRatio(clampedZoomRatio(pdfView.scaleFactor / fit))
                lastObservedZoomRatio = ratio
                if shouldResetZoomOnPageNavigation.wrappedValue == false {
                    let isPortrait = pdfView.bounds.width <= pdfView.bounds.height
                    let defaultRatio: CGFloat
                    if isPortrait {
                        let ftwRatio = fitToWidthZoomRatio(using: pdfView)
                        defaultRatio = ftwRatio
                    } else {
                        defaultRatio = minZoomRatio
                    }
                    if ratio <= defaultRatio + Threshold.tiny {
                        shouldResetZoomOnPageNavigation.wrappedValue = true
                    }
                }
            }

            if shouldResetZoomOnPageNavigation.wrappedValue {
                shouldResetZoomOnPageNavigation.wrappedValue = false
                isHandlingPageChange = true
                // In portrait, reset to fit-to-width; in landscape, reset to fit-to-page
                let isPortrait = pdfView.bounds.width <= pdfView.bounds.height
                if isPortrait {
                    let ftwRatio = fitToWidthZoomRatio(using: pdfView)
                    applyZoomRatio(ftwRatio, resetPosition: true)
                } else {
                    applyZoomRatio(minZoomRatio, resetPosition: false)
                }
                isHandlingPageChange = false
                return
            }

            let pageBoxSize = page.bounds(for: pdfView.displayBox).size
            let shouldRefreshDisplayBox = lastPageBoxSize != pageBoxSize
            if shouldRefreshDisplayBox {
                lastPageBoxSize = pageBoxSize
                cachedFitScale = 0
                cachedFitToWidthScale = 0
                ensureDisplayBoxValid(for: page)
            }

            if let pending = pendingProgrammaticPageTurn {
                pendingProgrammaticPageTurn = nil
                pendingProgrammaticPageTurnTimeout?.cancel()
                pendingProgrammaticPageTurnTimeout = nil

                isHandlingPageChange = true
                applyZoomRatio(pending.intendedZoomRatio, resetPosition: false)
                isHandlingPageChange = false
                return
            }

            let intendedRatio = normalizedZoomRatio(
                resolvedZoomRatio(
                    using: pdfView,
                    fallback: zoomRatio.wrappedValue
                )
            )
            guard intendedRatio > minZoomRatio + Threshold.tiny else { return }

            let fitScale = cachedFitScale > 0 ? cachedFitScale : pdfView.scaleFactorForSizeToFit
            guard fitScale > 0 else { return }
            cachedFitScale = fitScale
            let targetScale = fitScale * intendedRatio
            guard abs(pdfView.scaleFactor - targetScale) > Threshold.medium else { return }

            // Re-apply immediately to avoid the "page shows, then zoom pops in" effect.
            isHandlingPageChange = true
            applyZoomRatio(intendedRatio, resetPosition: false)
            isHandlingPageChange = false
        }

        private func goToNextPage(preserving ratio: CGFloat) {
            guard let pdfView else { return }
            isHandlingPageChange = true
            queueProgrammaticPageTurn(.next, preserving: ratio, for: pdfView)
            pdfView.goToNextPage(nil)
        }

        private func goToPreviousPage(preserving ratio: CGFloat) {
            guard let pdfView else { return }
            isHandlingPageChange = true
            queueProgrammaticPageTurn(.previous, preserving: ratio, for: pdfView)
            pdfView.goToPreviousPage(nil)
        }

        @objc private func handleScaleChanged() {
            guard let pdfView else { return }
            let fit = cachedFitScale > 0 ? cachedFitScale : pdfView.scaleFactorForSizeToFit
            guard fit > 0 else { return }
            cachedFitScale = fit
            let ratio = normalizedZoomRatio(pdfView.scaleFactor / fit)
            guard !isApplyingProgrammaticScale, !isHandlingPageChange else { return }

            let previousObserved = lastObservedZoomRatio ?? zoomRatio.wrappedValue
            if previousObserved > minZoomRatio + Threshold.small && ratio <= minZoomRatio + Threshold.tiny {
                shouldResetZoomOnPageNavigation.wrappedValue = true
            } else if ratio > minZoomRatio + Threshold.tiny {
                shouldResetZoomOnPageNavigation.wrappedValue = false
            }
            lastObservedZoomRatio = ratio
            if abs(zoomRatio.wrappedValue - ratio) > Threshold.small {
                queueBindingValue(zoomRatio, to: ratio)
            }
        }

        @objc private func handleUserPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let pdfView else { return }
            switch gesture.state {
            case .ended, .cancelled, .failed:
                onReadingInteraction()
                let fit = cachedFitScale > 0 ? cachedFitScale : pdfView.scaleFactorForSizeToFit
                guard fit > 0 else { return }
                cachedFitScale = fit
                let ratio = pdfView.scaleFactor / fit
                let normalized = normalizedZoomRatio(ratio)
                applyZoomRatio(normalized, resetPosition: false)
            default:
                break
            }
        }

        private func ensureScrollInteractionTracking(using pdfView: PDFView) {
            guard let scrollView = internalScrollView(in: pdfView) else { return }
            let panGesture = scrollView.panGestureRecognizer
            guard trackedScrollPanGesture !== panGesture else { return }
            trackedScrollPanGesture?.removeTarget(self, action: #selector(handleReaderScrollPan(_:)))
            panGesture.addTarget(self, action: #selector(handleReaderScrollPan(_:)))
            trackedScrollPanGesture = panGesture
        }

        private func internalScrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let scrollView = internalScrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
        }

        @objc private func handleReaderScrollPan(_ gesture: UIPanGestureRecognizer) {
            guard readerMode.wrappedValue == .reading else { return }
            guard gesture.state == .ended else { return }
            let translation = gesture.translation(in: pdfView)
            let velocity = gesture.velocity(in: pdfView)
            let movedEnough = hypot(translation.x, translation.y) >= 16
            let fastEnough = hypot(velocity.x, velocity.y) >= 140
            guard movedEnough || fastEnough else { return }
            onReadingInteraction()
        }

        private func fitToWidthScale(for pdfView: PDFView) -> CGFloat {
            guard let page = pdfView.currentPage else { return 0 }
            let pageWidth = page.bounds(for: pdfView.displayBox).width
            let viewWidth = pdfView.bounds.width
            guard pageWidth > 0, viewWidth > 0 else { return 0 }
            return viewWidth / pageWidth
        }

        /// Returns the zoom ratio that corresponds to fit-to-width, expressed relative to fit-to-page.
        private func fitToWidthZoomRatio(using pdfView: PDFView) -> CGFloat {
            let fit = cachedFitScale > 0 ? cachedFitScale : pdfView.scaleFactorForSizeToFit
            guard fit > 0 else { return minZoomRatio }
            let ftw = fitToWidthScale(for: pdfView)
            guard ftw > 0 else { return minZoomRatio }
            let ratio = ftw / fit
            return clampedZoomRatio(ratio)
        }

        private func clampedZoomRatio(_ raw: CGFloat) -> CGFloat {
            max(minZoomRatio, min(raw, maxZoomRatio))
        }

        private func normalizedZoomRatio(_ raw: CGFloat) -> CGFloat {
            let clamped = clampedZoomRatio(raw)
            return clamped < snapToFitThreshold ? minZoomRatio : clamped
        }

        private func applyZoomRatio(_ ratio: CGFloat, resetPosition: Bool) {
            guard let pdfView else { return }
            let fit = cachedFitScale > 0 ? cachedFitScale : pdfView.scaleFactorForSizeToFit
            guard fit > 0 else { return }
            cachedFitScale = fit

            // Keep zoom behavior deterministic by treating zoom as a ratio of the "fit" scale.
            pdfView.autoScales = false
            pdfView.minScaleFactor = fit * minZoomRatio
            pdfView.maxScaleFactor = fit * maxZoomRatio

            let normalized = normalizedZoomRatio(ratio)
            lastObservedZoomRatio = normalized
            let targetScale = fit * normalized
            if abs(pdfView.scaleFactor - targetScale) > Threshold.small {
                isApplyingProgrammaticScale = true
                UIView.performWithoutAnimation {
                    pdfView.scaleFactor = targetScale
                }
                isApplyingProgrammaticScale = false
            }

            if abs(zoomRatio.wrappedValue - normalized) > Threshold.small {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if abs(self.zoomRatio.wrappedValue - normalized) > Threshold.small {
                        self.queueBindingValue(self.zoomRatio, to: normalized)
                    }
                }
            }

            if resetPosition, normalized > minZoomRatio + Threshold.tiny {
                resetViewportToTopLeft()
            }
        }

        private func resetViewportToTopLeft() {
            guard let pdfView, let page = pdfView.currentPage else { return }
            let bounds = page.bounds(for: pdfView.displayBox)
            let topLeft = CGPoint(x: bounds.minX, y: bounds.maxY)
            let destination = PDFDestination(page: page, at: topLeft)
            destination.zoom = pdfView.scaleFactor
            UIView.performWithoutAnimation {
                pdfView.go(to: destination)
            }
        }

        @objc private func handleSelectionChanged() {
            pendingSelectionWorkTask?.cancel()
            pendingSelectionWorkTask = Task { [weak self] in
                defer {
                    Task { @MainActor in
                        self?.pendingSelectionWorkTask = nil
                    }
                }
                do {
                    let nanos = UInt64(ReaderLookupLimits.selectionChangeDebounceInterval * 1_000_000_000)
                    if nanos > 0 {
                        try await Task.sleep(nanoseconds: nanos)
                    }
                } catch {
                    return
                }
                guard let self else { return }
                await MainActor.run {
                    self.processSelectionChanged()
                }
            }
        }

        private func processSelectionChanged() {
            guard let pdfView else { return }
            if isLongPressMode() {
                clearSelectionIfNeeded(on: pdfView)
                queueBindingValue(hasTextSelection, to: false)
                return
            }
            if isLookupActive {
                queueBindingValue(hasTextSelection, to: false)
                return
            }
            if !longPressEnabled() {
                let hasSelection = pdfView.currentSelection != nil
                queueBindingValue(hasTextSelection, to: hasSelection)
                return
            }
            if longPressEnabled(),
               let successTime = lastSuccessfulLongPressLookupAt,
               Date().timeIntervalSince(successTime) < Timing.selectionToLongPressSuppression {
                queueBindingValue(hasTextSelection, to: false)
                return
            } else if longPressEnabled() && lastSuccessfulLongPressLookupAt != nil {
                lastSuccessfulLongPressLookupAt = nil
            }

            if isProgrammaticSelectionClear {
                queueBindingValue(hasTextSelection, to: false)
                return
            }
            if readerMode.wrappedValue == .writing {
                clearSelectionIfNeeded(on: pdfView)
                queueBindingValue(hasTextSelection, to: false)
                return
            }
            guard let currentSelection = pdfView.currentSelection else {
                queueBindingValue(hasTextSelection, to: false)
                return
            }

            let now = Date()
            if let last = lastSelectionAt, now.timeIntervalSince(last) < cooldown {
                return
            }

            guard let filteredText = ReaderSelectionFilter.filteredText(from: currentSelection) else {
                return
            }

            guard let page = currentSelection.pages.first else { return }
            let pageIndex = pdfView.document?.index(for: page) ?? 0
            let fullRectOnPage = currentSelection.bounds(for: page)

            let boundedSentence = ReaderView.boundedLookupText(
                ReaderSelectionFilter.contextSentence(from: currentSelection) ?? filteredText,
                maxWordCount: ReaderLookupLimits.maxPopupContextWordCount
            )

            let boundedText = ReaderView.boundedLookupText(filteredText, maxWordCount: ReaderLookupLimits.maxPopupWordCount)
            let sentence = boundedSentence.text
            let lookupText = boundedText.text

            // Clip highlight rect to match actually-processed text range.
            let fullRawText = (currentSelection.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            let wasLimited = fullRawText.count > lookupText.count + 2 && fullRawText.count > 0
            let rectOnPage: CGRect
            if wasLimited {
                let ratio = CGFloat(lookupText.count) / CGFloat(fullRawText.count)
                rectOnPage = CGRect(
                    x: fullRectOnPage.origin.x,
                    y: fullRectOnPage.origin.y,
                    width: fullRectOnPage.width * min(ratio, 1.0),
                    height: fullRectOnPage.height
                )
            } else {
                rectOnPage = fullRectOnPage
            }
            let rectOnView = pdfView.convert(rectOnPage, from: page)
            let anchor = CGPoint(
                x: rectOnView.midX,
                y: max(rectOnView.minY - Gesture.popupYOffset, Gesture.popupMinY)
            )

            let signature = [
                "\(pageIndex)",
                "\(lookupText.lowercased())",
                lookupSignatureComponentString(anchor)
            ].joined(separator: "|")
            if signature == lastLookupSelectionSignature {
                return
            }
            lastLookupSelectionSignature = signature

            lastSelectionAt = now

            if longPressEnabled() {
                suppressSingleTap(for: Timing.longPressSingleTapCooldown)
                suppressSingleTapTemporarily(Timing.singleTapRecoveryDebounce)
            }

            pdfView.clearSelection()
            queueBindingValue(hasTextSelection, to: false)

            let tapSelection = WordSelection(
                text: lookupText,
                sentence: sentence,
                anchor: anchor,
                pageIndex: pageIndex,
                highlightRect: rectOnView,
                rectOnPage: rectOnPage,
                page: page,
                wasLimited: wasLimited
            )
            Task { @MainActor in
                onSelection(tapSelection, pdfView)
            }
        }

        @objc private func handleLookupLongPress(_ gesture: UILongPressGestureRecognizer) {
            #if DEBUG
            let signature = [
                "mode=\(readerMode.wrappedValue)",
                "interactionReady=\(isInteractionReady)",
                "lookupReady=\(isLookupGesturesReady)",
                "active=\(isLookupActive)",
                "suppress=\(shouldSuppressSingleTap)",
                "attempts=\(longPressLookupAttemptCount)"
            ].joined(separator: "|")
            if shouldEmitDebug(tag: "lookupGesture", signature: "\(gesture.state.rawValue)|\(gesture.location(in: pdfView))|\(signature)") {
                print("[LongPressDebug] handleLookupLongPress state=\(gesture.state.rawValue) location=\(gesture.location(in: pdfView))")
            }
            if shouldEmitDebug(tag: "lookupGesture", signature: signature) {
                debugLongPressState("lookupGesture")
            }
            #endif
            let lookupStartAt = CFAbsoluteTimeGetCurrent()
            var lookupSessionId = activeLookupSessionId
            guard readerMode.wrappedValue == .reading else {
                resetLookupPressState(force: true)
                return
            }
            guard longPressEnabled() else {
                resetLookupPressState(force: true)
                return
            }
            let isTerminalLongPressState = gesture.state == .ended
                || gesture.state == .cancelled
                || gesture.state == .failed
                || gesture.state == .recognized
            let activePressDuration = isFirstLongPressAfterLoad
                ? ReaderLookupLimits.longPressFirstTouchMinimumPressDuration
                : ReaderLookupLimits.longPressMinimumPressDuration

            if !isInteractionReady && !isTerminalLongPressState {
                ensureLookupPressReadinessIfNeeded()
                suppressSingleTapTemporarily(activePressDuration + Timing.singleTapRecoveryDebounce)
            }
            if !isLookupGesturesReady {
                ensureLookupPressReadinessIfNeeded()
            }
            guard let pdfView else { return }
            guard pdfView.window != nil else {
                resetLookupPressState(force: true)
                return
            }
            guard pdfView.isUserInteractionEnabled, pdfView.bounds.width > 0, pdfView.bounds.height > 0 else {
                resetLookupPressState(force: true)
                return
            }
            if isApplyingProgrammaticScale {
                resetLookupPressState()
                return
            }

            switch gesture.state {
            case .began:
                onReadingInteraction()
                initialLongPressLocation = gesture.location(in: pdfView)
                if isLookupActive {
                    resetLookupPressState(force: true)
                }
                cancelLookupSessionEndTimer()
                lookupSessionId = startLookupSession()
                activeLookupPageIndex = currentLookupPageIndex(for: pdfView)
                // Reset session-level duplicate guards so one press does not block the next one.
                lastLookupSelectionSignature = nil
                lastLookupWordSignature = nil
                lastLookupProbePointKey = nil
                transitionGestureRuntime(to: .longPressActive, using: pdfView)
                isFirstLongPressLookup = true
                let wasFirstLongPressAfterLoad = isFirstLongPressAfterLoad
                let isFirstLongPressTouch = wasFirstLongPressAfterLoad
                #if DEBUG
                if shouldEmitDebug(tag: "lookupSession", signature: "begin:\(lookupSessionId)") {
                    print("[LongPressDebug] lookupSession begin=\(lookupSessionId)")
                }
                #endif
                if wasFirstLongPressAfterLoad {
                    bypassInitialLookupWarmup()
                    isFirstLongPressAfterLoad = false
                    #if DEBUG
                    if shouldEmitDebug(tag: "lookupFirstTouch", signature: "\(CFAbsoluteTimeGetCurrent() - lookupStartAt)") {
                        print("[LongPressDebug] firstTouchBypassWarmup elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - lookupStartAt) * 1000))ms")
                    }
                    #endif
                }
                
                longPressLookupAttemptCount = 0
                lastLookupFallbackProbePointKey = nil
                lastLookupFallbackAttemptAt = nil
                lastLookupFallbackWindowStartedAt = nil
                fallbackAttemptsInWindow = 0
                lastLookupChangedAt = nil
                suppressSingleTap(for: Timing.longPressStartupTapSuppression)
                suppressSingleTapTemporarily(activePressDuration + Timing.singleTapRecoveryDebounce)
                didLookupForCurrentLongPress = false
                let now = Date()
                suppressSingleTapUntil = nil
                if let lastLookupGestureAt,
                   now.timeIntervalSince(lastLookupGestureAt) < Timing.twoFingerGestureSeparation {
                    resetLookupPressState()
                    return
                }
                self.lastLookupGestureAt = now
                if let previousPress = self.lastLookupPressAt,
                   now.timeIntervalSince(previousPress) < ReaderLookupLimits.longPressDuplicateDebounceInterval {
                    resetLookupPressState()
                    return
                }
                self.lastLookupPressAt = now
                isLookupActive = true
                didLookupForCurrentLongPress = false
                didEmitLongPressHaptic = false
                scheduleLookupPressRecovery(
                    timeout: max(1.4, ReaderLookupLimits.longPressRecoverySeconds + 1.0)
                )
                let shouldDeferInitialLookup = isFirstLongPressTouch
                    && hasDeferredInitialLongPressLookup == false
                    && hasCompletedInitialLookupWarmup == false
                    && !hasBypassedInitialLookupWarmup
                if hasDeferredInitialLongPressLookup {
                    let didLookup = performLookupForLongPress(
                        with: pdfView,
                        gesture: gesture,
                        lookupSessionId: lookupSessionId
                    )
                    if !didLookup {
                        // Keep the long-press active for a short follow-up attempt on movement/end.
                        didLookupForCurrentLongPress = false
                    } else {
                        isPrimingFirstLongPressLookup = false
                    }
                    firstLongPressWarmupAttemptsLeft = 0
                } else if shouldDeferInitialLookup {
                    hasDeferredInitialLongPressLookup = true
                    isPrimingFirstLongPressLookup = false
                    firstLongPressWarmupAttemptsLeft = 0
                    let didLookup = performLookupForLongPress(
                        with: pdfView,
                        gesture: gesture,
                        lookupSessionId: lookupSessionId
                    )
                    if !didLookup {
                        didLookupForCurrentLongPress = false
                        scheduleInitialLongPressLookupDelay(
                            with: pdfView,
                            gesture: gesture,
                            lookupSessionId: lookupSessionId
                        )
                    }
                } else {
                    hasDeferredInitialLongPressLookup = true
                    isPrimingFirstLongPressLookup = false
                    firstLongPressWarmupAttemptsLeft = 0

                    let didLookup = performLookupForLongPress(
                        with: pdfView,
                        gesture: gesture,
                        lookupSessionId: lookupSessionId
                    )
                    if !didLookup {
                        // Keep the long-press active for a short follow-up attempt on movement/end.
                        didLookupForCurrentLongPress = false
                        scheduleInitialLongPressLookupDelay(
                            with: pdfView,
                            gesture: gesture,
                            lookupSessionId: lookupSessionId
                        )
                    } else {
                        isPrimingFirstLongPressLookup = false
                        firstLongPressWarmupAttemptsLeft = 0
                    }
                }
            case .changed:
                guard isLookupSessionCurrent(lookupSessionId) else { return }
                guard pendingFirstLongPressLookup == nil else { return }
                guard isLookupActive else { return }
                let now = Date()
                if isPrimingFirstLongPressLookup {
                    guard firstLongPressWarmupAttemptsLeft > 0 else { return }
                    firstLongPressWarmupAttemptsLeft -= 1
                }
                if let lastChanged = lastLookupChangedAt,
                   now.timeIntervalSince(lastChanged) < Timing.longPressLookupChangeThrottle {
                    return
                }
                lastLookupChangedAt = now
                if didLookupForCurrentLongPress {
                    return
                }
                let location = gesture.location(in: pdfView)
                scheduleDebouncedLookup(
                    at: location,
                    state: gesture.state,
                    in: pdfView,
                    lookupSessionId: lookupSessionId
                )
            case .ended, .cancelled, .failed, .recognized:
                let isCurrentLookupSession = isLookupSessionCurrent(lookupSessionId)
                let hasSupersedingLookupSession = activeLookupSessionId != 0 && activeLookupSessionId != lookupSessionId
                if isCurrentLookupSession == false && isTerminalLongPressState && hasSupersedingLookupSession {
                    cancelInitialLongPressLookupDelay()
                    pendingLookupTask?.cancel()
                    return
                }
                cancelInitialLongPressLookupDelay()
                pendingLookupTask?.cancel()
                pendingLookupTask = nil
                if let lookupPress {
                    lookupPress.minimumPressDuration = ReaderLookupLimits.longPressMinimumPressDuration
                }
                isFirstLongPressLookup = false
                lastLookupChangedAt = nil
                lastLookupPressAt = Date()
                let hasSynchronousLookupResult = didLookupForCurrentLongPress
                suppressSingleTap(for: Timing.longPressTapRecoveryDebounce)
                let shouldCloseImmediately: Bool
                if isCurrentLookupSession, isLookupActive, !didLookupForCurrentLongPress {
                    // Reset probe key so the final retry isn't blocked by
                    // dedup when the finger hasn't moved. The .ended state
                    // is the last chance to find a word via forceFallback.
                    lastLookupProbePointKey = nil
                    shouldCloseImmediately = performLookupForLongPress(
                        at: gesture.location(in: pdfView),
                        state: gesture.state,
                        in: pdfView,
                        lookupSessionId: lookupSessionId,
                        allowLateDelivery: true
                    )
                } else if !isCurrentLookupSession && isTerminalLongPressState && !didLookupForCurrentLongPress {
                    lastLookupProbePointKey = nil
                    shouldCloseImmediately = performLookupForLongPress(
                        at: gesture.location(in: pdfView),
                        state: gesture.state,
                        in: pdfView,
                        lookupSessionId: lookupSessionId,
                        allowLateDelivery: true
                    )
                } else {
                    shouldCloseImmediately = false
                }
                let shouldKeepDismissHint = didLookupForCurrentLongPress
                didLookupForCurrentLongPress = false
                initialLongPressLocation = nil
                isLookupActive = false
                isPrimingFirstLongPressLookup = false
                firstLongPressWarmupAttemptsLeft = 0
                let sessionEndDelay: TimeInterval = (hasSynchronousLookupResult || shouldCloseImmediately)
                  ? 1.2
                  : 3.0

                scheduleLookupSessionEnd(
                    sessionId: lookupSessionId,
                    preserveDismissHint: shouldKeepDismissHint,
                    delay: sessionEndDelay
                )
            default:
                break
            }
        }

        @discardableResult
        private func performLookupForLongPress(
            at location: CGPoint,
            state: UIGestureRecognizer.State,
            in pdfView: PDFView,
            lookupSessionId: UInt64,
            allowLateDelivery: Bool = false
        ) -> Bool {
            _ = allowLateDelivery
            guard isLookupSessionUsable(lookupSessionId) else {
                #if DEBUG
                if shouldEmitDebug(tag: "lookupSession", signature: "skip:\(lookupSessionId)") {
                    print("[LongPressDebug] performLookupForLongPress stale session=\(lookupSessionId)")
                }
                #endif
                return false
            }
            let lookupStartAt = CFAbsoluteTimeGetCurrent()
            longPressLookupAttemptCount += 1
            guard location.x.isFinite && location.y.isFinite else {
                didLookupForCurrentLongPress = false
                shouldDismissLookupArtifactsOnNextTap = false
                return false
            }

            let clampedLocation = CGPoint(
                x: min(max(location.x, 0), max(0, pdfView.bounds.width)),
                y: min(max(location.y, 0), max(0, pdfView.bounds.height))
            )
            let isTerminalLookupState = state == .ended ||
                state == .cancelled ||
                state == .failed ||
                state == .recognized
            if state != .began {
                let probeKey = lookupPointKey(for: clampedLocation)
                if isTerminalLookupState == false {
                    if let lastProbeKey = lastLookupProbePointKey, lastProbeKey == probeKey {
                        return false
                    }
                }
                lastLookupProbePointKey = probeKey
            } else {
                lastLookupProbePointKey = lookupPointKey(for: clampedLocation)
            }

            pendingLookupTask?.cancel()
            pendingLookupTask = nil
            let firstLookup = isFirstLongPressLookup
            let isColdStartLookup = isPrimingFirstLongPressLookup
            if state == .began {
                syncZoomRatioFromView(pdfView)
            }
            let shouldForceFallback = isTerminalLookupState
            let lookupCandidateCount = lookupCandidateLimit(
                isFirstLookup: firstLookup,
                isColdStart: isColdStartLookup
            )
            let shouldAttemptFallback = !(isColdStartLookup && !isTerminalLookupState)
            #if DEBUG
            if shouldEmitDebug(tag: "lookupPerform", signature: "\(state.rawValue)|\(lookupCandidateCount)|\(firstLookup)|\(isColdStartLookup)|\(shouldForceFallback)|\(shouldAttemptFallback)") {
                print("[LongPressDebug] performLookupForLongPress state=\(state.rawValue) candidates=\(lookupCandidateCount) firstLookup=\(firstLookup) coldStart=\(isColdStartLookup) forceFallback=\(shouldForceFallback) attemptFallback=\(shouldAttemptFallback)")
            }
            #endif
            // Defer only for movement states. Terminal states should execute fallback
            // immediately so OCR lookup can run before session teardown.
            let shouldDeferFallback =
                state == .changed ||
                isColdStartLookup
            let fallbackDelay = isColdStartLookup
                ? Timing.longPressFirstLookupDeferralDelay
                : Timing.longPressInitialLookupFallbackDelay
            let didLookup = performLookup(
                at: clampedLocation,
                in: pdfView,
                lookupSessionId: lookupSessionId,
                candidateLimit: lookupCandidateCount,
                attemptLookupFallback: shouldAttemptFallback,
                deferFallback: shouldDeferFallback,
                forceFallback: shouldForceFallback,
                fallbackDelay: fallbackDelay,
                allowLateDelivery: allowLateDelivery || isTerminalLookupState
            )
            #if DEBUG
            if shouldEmitDebug(tag: "lookupResult", signature: "\(didLookup)") {
                print("[LongPressDebug] performLookup result=\(didLookup)")
            }
            #endif
            if didLookup {
                let now = Date()
                didLookupForCurrentLongPress = true
                shouldDismissLookupArtifactsOnNextTap = true
                lastSelectionAt = now
                lastSuccessfulLongPressLookupAt = now
                isPrimingFirstLongPressLookup = false
                firstLongPressWarmupAttemptsLeft = 0
            } else {
                didLookupForCurrentLongPress = false
                shouldDismissLookupArtifactsOnNextTap = false
                lastSuccessfulLongPressLookupAt = nil
            }
            if firstLookup {
                isFirstLongPressLookup = false
            }
            #if DEBUG
            if shouldEmitDebug(tag: "lookupPerformance", signature: "\(longPressLookupAttemptCount)\(didLookup ? "|hit" : "|miss")") {
                print("[LongPressDebug] performLookupForLongPress done elapsed=\(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - lookupStartAt) * 1000))ms state=\(state.rawValue) result=\(didLookup)")
            }
            #endif
            return didLookup
        }

        private func performLookupForLongPress(
            with pdfView: PDFView,
            gesture: UILongPressGestureRecognizer,
            lookupSessionId: UInt64
        ) -> Bool {
            return performLookupForLongPress(
                at: gesture.location(in: pdfView),
                state: gesture.state,
                in: pdfView,
                lookupSessionId: lookupSessionId
            )
        }

        private func scheduleDebouncedLookup(
            at location: CGPoint,
            state: UIGestureRecognizer.State,
            in pdfView: PDFView,
            lookupSessionId: UInt64
        ) {
            pendingLongPressLookupTask?.cancel()
            let location = location
            let state = state
            let sessionId = lookupSessionId
            pendingLongPressLookupTask = Task { [weak self, weak pdfView] in
                defer {
                    Task { @MainActor in
                        self?.pendingLongPressLookupTask = nil
                    }
                }
                do {
                    let nanos = UInt64(Timing.longPressLookupChangeThrottle * 1_000_000_000)
                    if nanos > 0 {
                        try await Task.sleep(nanoseconds: nanos)
                    }
                } catch {
                    return
                }
                guard let self else { return }
                guard let pdfView else { return }
                guard self.isLookupSessionUsable(sessionId) else {
                    #if DEBUG
                    if self.shouldEmitDebug(tag: "lookupSession", signature: "skip-debounced:\(sessionId)") {
                        print("[LongPressDebug] scheduleDebouncedLookup skip stale session=\(sessionId)")
                    }
                    #endif
                    return
                }
                await MainActor.run {
                    _ = self.performLookupForLongPress(
                        at: location,
                        state: state,
                        in: pdfView,
                        lookupSessionId: sessionId
                    )
                }
            }
        }

        private func setLookupLongPressEnabled(_ enabled: Bool, lookupInteractionReady: Bool) {
            let lookupReadyTransition = self.lookupInteractionReady != lookupInteractionReady
            let canStartLookupGestures = enabled
            let changed = lastAppliedLongPressEnabled != enabled || lookupReadyTransition
            guard changed else {
                guard let pdfView else { return }

                if canStartLookupGestures {
                    if isInteractionReady
                        && readerMode.wrappedValue == .reading
                        && !isLookupGesturesReady {
                        if !shouldSuppressSingleTap {
                            suppressSingleTapTemporarily(Timing.longPressStartupTapSuppression)
                        }
                        scheduleLookupPressReadiness(
                            delay: Timing.longPressReadinessDelay,
                            generation: documentLoadGeneration,
                            using: pdfView
                        )
                    }
                } else {
                    cancelLookupPressReadiness()
                    isLookupGesturesReady = false
                    if isLookupActive {
                        resetLookupPressState(force: true)
                    }
                }

                transitionGestureRuntime(to: desiredGestureRuntimePhase(), using: pdfView)
                return
            }

            if isLookupActive {
                resetLookupPressState(force: true)
            }
            hasDeferredInitialLongPressLookup = false
            isPrimingFirstLongPressLookup = false
            isFirstLongPressLookup = false
            firstLongPressWarmupAttemptsLeft = 0
            longPressLookupAttemptCount = 0
            lastLookupFallbackProbePointKey = nil
            lastLookupFallbackAttemptAt = nil
            lastLookupChangedAt = nil
            suppressSingleTapUntil = nil
            shouldDismissLookupArtifactsOnNextTap = false
            didEmitLongPressHaptic = false
            cancelLookupTransitionState()
            clearSingleTapSuppression()
            lastSingleTapAt = nil
            lastLookupGestureAt = nil
            lastLookupPressAt = nil

            hostLongPressEnabled = enabled
            lastAppliedLongPressEnabled = enabled

            if !enabled {
                if isLookupActive {
                    resetLookupPressState(force: true)
                }
                // Selection must be reset immediately when lookup mode is turned off.
                cancelInitialLongPressLookupDelay()
                cancelLookupPressReadiness()
                isLookupGesturesReady = false
                queueBindingValue(hasTextSelection, to: false)
                pdfView?.clearSelection()
                lastLookupSelectionSignature = nil
                lastLookupWordSignature = nil
                lastSuccessfulLongPressLookupAt = nil
            } else {
                cancelLookupPressReadiness()
                isLookupGesturesReady = false
                lastLookupSelectionSignature = nil
                lastLookupWordSignature = nil
                didLookupForCurrentLongPress = false
                pdfView?.clearSelection()
                queueBindingValue(hasTextSelection, to: false)
            }
            (pdfView as? ReadTapPDFView)?.setLookupSelectionEnabled(!enabled)

            if let pdfView = pdfView {
                let readinessDelay: TimeInterval = (canStartLookupGestures
                    && self.isInteractionReady
                    && self.readerMode.wrappedValue == .reading
                    && (hasCompletedInitialLookupWarmup || hasBypassedInitialLookupWarmup))
                    ? 0
                    : Timing.longPressReadinessDelay
                scheduleLookupPressReadiness(
                    delay: canStartLookupGestures ? readinessDelay : 0,
                    generation: documentLoadGeneration,
                    using: pdfView
                )
                transitionGestureRuntime(to: desiredGestureRuntimePhase(), using: pdfView)
                scheduleRefreshLongPressEnabled(
                    recollect: canStartLookupGestures,
                    delay: Timing.gestureModeWarmupDelay
                )
                #if DEBUG
                let mode = expectedGestureMode()
                let signature = [
                    "mode=\(mode)",
                    "enabled=\(enabled)",
                    "interactionReady=\(isInteractionReady)",
                    "singleTapReady=\(isSingleTapGesturesReady)",
                    "lookupReady=\(isLookupGesturesReady)",
                    "readerMode=\(readerMode.wrappedValue)"
                ].joined(separator: "|")
                if shouldEmitDebug(tag: "setLongPressEnabled", signature: signature) {
                    let coordPtr = Unmanaged.passUnretained(self).toOpaque()
                    let singleTapState = singleTap?.isEnabled ?? false
                    let lookupPressState = lookupPress?.isEnabled ?? false
                    print(
                        "[ReaderGesture][setLongPressEnabled] "
                        + "coord=\(coordPtr) "
                        + "enabled=\(enabled) "
                        + "changed=true "
                        + "mode=\(mode) "
                        + "singleTap=\(singleTapState) "
                        + "lookupPress=\(lookupPressState)"
                    )
                }
                #endif
            }
        }

        private func setLookupLongPressEnabled(_ enabled: Bool) {
            setLookupLongPressEnabled(enabled, lookupInteractionReady: lookupInteractionReady)
        }

        private func performLookup(
            at location: CGPoint,
            in pdfView: PDFView,
            lookupSessionId: UInt64,
            candidateLimit: Int? = nil,
            attemptLookupFallback: Bool = true,
            deferFallback: Bool = false,
            forceFallback: Bool = false,
            fallbackDelay: TimeInterval? = nil,
            allowLateDelivery: Bool = false
        ) -> Bool {
            _ = allowLateDelivery
            guard isLookupSessionUsable(lookupSessionId) else {
                #if DEBUG
                if shouldEmitDebug(tag: "lookupSession", signature: "skip-performLookup:\(lookupSessionId)") {
                    print("[LongPressDebug] performLookup stale session=\(lookupSessionId)")
                }
                #endif
                return false
            }
            let effectiveCandidateLimit = candidateLimit ?? LookupPoint.sampleCount
            let bounds = pdfView.bounds
            let effectiveFallbackDelay = fallbackDelay ?? Timing.longPressInitialLookupFallbackDelay
            guard bounds.width > 0, bounds.height > 0 else { return false }
            let clampedLocation = CGPoint(
                x: min(max(location.x, 0), bounds.width),
                y: min(max(location.y, 0), bounds.height)
            )
            guard pdfView.page(for: clampedLocation, nearest: false) != nil else {
                #if DEBUG
                if shouldEmitDebug(tag: "lookupCandidate", signature: "miss-nearest-page") {
                    print("[LongPressDebug] performLookup missed strict page")
                }
                #endif
                return false
            }

            if let initialLoc = initialLongPressLocation,
               let initialPage = pdfView.page(for: initialLoc, nearest: false) {
                let initPagePt = pdfView.convert(initialLoc, to: initialPage)
                let pageText = initialPage.string ?? ""
                let hasTextLayer = !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasTextLayer {
                    let checkRect = CGRect(x: initPagePt.x - 5, y: initPagePt.y - 5, width: 10, height: 10)
                    if let sel = initialPage.selection(for: checkRect),
                       let text = sel.string,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // OK — text layer has content at press location
                    } else {
                        // Text layer exists but no text at press location.
                        // Don't bail out early — allow OCR fallback to handle
                        // CJK PDFs where the text layer is incomplete or uses
                        // CID fonts that PDFKit cannot decode.
                        // Allow OCR fallback for CJK PDFs with incomplete text layers
                    }
                }
            }

            let candidatePoints = lookupCandidatePoints(
                around: clampedLocation,
                in: bounds,
                maxCount: max(1, effectiveCandidateLimit)
            )
            let pageIndexLookup = candidatePoints.isEmpty ? nil : pdfView.document
            var lastPage: PDFPage?
            var lastPageIndex: Int = 0
            var lastLookupBounds: CGRect = .zero

            for candidate in candidatePoints {
                guard let page = pdfView.page(for: candidate, nearest: false) else { continue }
                let pagePoint = pdfView.convert(candidate, to: page)
                guard pagePoint.x.isFinite && pagePoint.y.isFinite else { continue }
                let originalLocation = initialLongPressLocation ?? clampedLocation
                let originalPagePoint = pdfView.convert(originalLocation, to: page)

                let resolvedLookupBounds: CGRect
                let pageIndex: Int
                if let cachedPage = lastPage, cachedPage == page {
                    resolvedLookupBounds = lastLookupBounds
                    pageIndex = lastPageIndex
                } else {
                    guard let resolvedBounds = lookupBounds(for: page) else { continue }
                    guard resolvedBounds.isEmpty == false else {
                        continue
                    }
                    resolvedLookupBounds = resolvedBounds
                    lastPage = page
                    lastLookupBounds = resolvedBounds
                    pageIndex = pageIndexLookup.flatMap { $0.index(for: page) } ?? 0
                    lastPageIndex = pageIndex
                }

                if let selection = performLookupCandidate(
                    in: pdfView,
                    page: page,
                    pagePoint: pagePoint,
                    originalPagePoint: originalPagePoint,
                    lookupBounds: resolvedLookupBounds,
                    pageIndex: pageIndex,
                    lookupSessionId: lookupSessionId
                ) {
                    emitLookupSelection(
                        selection,
                        in: pdfView,
                        lookupSessionId: lookupSessionId,
                        allowLateDelivery: allowLateDelivery
                    )
                    return true
                }
            }

            if forceFallback {
                guard isLookupSessionUsable(lookupSessionId) else { return false }
                let shouldAttemptFallback = shouldAttemptLookupFallback(at: clampedLocation)
                guard shouldAttemptFallback else { return false }
                if let fallback = lookupFallback(from: clampedLocation, in: pdfView) {
                    emitLookupSelection(
                        fallback,
                        in: pdfView,
                        lookupSessionId: lookupSessionId,
                        allowLateDelivery: allowLateDelivery
                    )
                    return true
                }
                requestOCRLookupProbe(
                    sessionId: lookupSessionId,
                    at: clampedLocation,
                    in: pdfView,
                    allowLateDelivery: allowLateDelivery
                )
                return false
            }

            let shouldAttemptFallback = attemptLookupFallback && shouldAttemptLookupFallback(at: clampedLocation)
            guard shouldAttemptFallback else { return false }

            if deferFallback {
                guard shouldAttemptFallback else { return false }
                performDeferredOCRFallback(
                    from: clampedLocation,
                    in: pdfView,
                    delay: effectiveFallbackDelay,
                    lookupSessionId: lookupSessionId,
                    allowLateDelivery: allowLateDelivery
                )
                return false
            }

            guard shouldAttemptLookupFallback(at: clampedLocation) else { return false }
            if let fallback = lookupFallback(from: clampedLocation, in: pdfView) {
                emitLookupSelection(
                    fallback,
                    in: pdfView,
                    lookupSessionId: lookupSessionId,
                    allowLateDelivery: allowLateDelivery
                )
                return true
            }
            requestOCRLookupProbe(
                sessionId: lookupSessionId,
                at: clampedLocation,
                in: pdfView,
                allowLateDelivery: allowLateDelivery
            )
            return false
        }

        private func requestOCRLookupProbe(
            sessionId: UInt64,
            at location: CGPoint,
            in pdfView: PDFView,
            allowLateDelivery: Bool = false
        ) {
            _ = allowLateDelivery
            if isLookupSessionUsable(sessionId) == false {
                return
            }
            Task { @MainActor in
                onLookupNeedsOCRProbe(sessionId, location, pdfView)
            }
        }

        private func lookupFallback(from location: CGPoint, in pdfView: PDFView) -> WordSelection? {
            MainActor.assumeIsolated {
                onOCRLookup(location, pdfView)
            }
        }

        private func performDeferredOCRFallback(
            from location: CGPoint,
            in pdfView: PDFView,
            delay: TimeInterval? = nil,
            lookupSessionId: UInt64,
            allowLateDelivery: Bool = false
        ) {
            let delay = delay ?? Timing.longPressInitialLookupFallbackDelay
            let sessionId = lookupSessionId
            let generation = documentLoadGeneration
            pendingLookupTask?.cancel()
            pendingLookupTask = Task { [weak self, weak pdfView] in
                defer {
                    Task { @MainActor in
                        self?.pendingLookupTask = nil
                    }
                }
                do {
                    let nanos = UInt64(delay * 1_000_000_000)
                    if nanos > 0 {
                        try await Task.sleep(nanoseconds: nanos)
                    }
                } catch {
                    return
                }

                guard let self else { return }
                guard generation == self.documentLoadGeneration else { return }
                guard !Task.isCancelled else { return }
                guard let pdfView else { return }
                guard !self.didLookupForCurrentLongPress else { return }
                if self.isLookupSessionUsable(sessionId) == false {
                    return
                }
                    if let fallback = self.lookupFallback(from: location, in: pdfView) {
                        let now = Date()
                        self.didLookupForCurrentLongPress = true
                        self.shouldDismissLookupArtifactsOnNextTap = true
                        self.lastSelectionAt = now
                        self.lastSuccessfulLongPressLookupAt = now

                        await MainActor.run {
                            if self.isLookupSessionUsable(sessionId) == false {
                                return
                            }
                            self.emitLookupSelection(
                                fallback,
                                in: pdfView,
                                lookupSessionId: sessionId,
                                allowLateDelivery: allowLateDelivery
                            )
                        }
                        return
                    }

                requestOCRLookupProbe(
                    sessionId: sessionId,
                    at: location,
                    in: pdfView,
                    allowLateDelivery: allowLateDelivery
                )
            }
        }

        private func lookupCandidateLimit(
            isFirstLookup: Bool,
            isColdStart: Bool
        ) -> Int {
            if isColdStart {
                return isFirstLookup ? 1 : LookupPoint.initialColdStartSampleCount
            }
            if isFirstLookup {
                return max(LookupPoint.initialSampleCount, LookupPoint.sampleCount - 3)
            }
            if longPressLookupAttemptCount <= 2 {
                return max(LookupPoint.initialSampleCount, LookupPoint.sampleCount - 6)
            }
            if longPressLookupAttemptCount <= 4 {
                return LookupPoint.sampleCount - 3
            }
            return LookupPoint.sampleCount
        }

        private func hasTextAtPressLocation(_ location: CGPoint, in pdfView: PDFView) -> Bool {
            guard let page = pdfView.page(for: location, nearest: false) else { return false }
            let pagePoint = pdfView.convert(location, to: page)
            let pageText = page.string ?? ""
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            let probeSize: CGFloat = 10
            let probeRect = CGRect(
                x: pagePoint.x - probeSize / 2,
                y: pagePoint.y - probeSize / 2,
                width: probeSize,
                height: probeSize
            )
            if let sel = page.selection(for: probeRect),
               let text = sel.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        }

        private func hasNearbyTextOnPage(at location: CGPoint, in pdfView: PDFView? = nil) -> Bool {
            guard let pdfView = pdfView ?? self.pdfView else { return false }
            guard let page = pdfView.page(for: location, nearest: false) else { return false }
            let pagePoint = pdfView.convert(location, to: page)
            let probeSize: CGFloat = 100
            let probeRect = CGRect(
                x: pagePoint.x - probeSize / 2,
                y: pagePoint.y - probeSize / 2,
                width: probeSize,
                height: probeSize
            )
            if let sel = page.selection(for: probeRect),
               let text = sel.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        }

        private func shouldAttemptLookupFallback(at location: CGPoint) -> Bool {
            guard hasNearbyTextOnPage(at: location) else { return false }
            let maxFallbackAttemptsInWindow = 2
            let now = Date()
            let probeKey = lookupPointKey(for: location)
            let isNewProbe = lastLookupFallbackProbePointKey != probeKey
            let windowExpired: Bool = {
                guard let windowStart = lastLookupFallbackWindowStartedAt else {
                    return true
                }
                return now.timeIntervalSince(windowStart) > longPressFallbackRetryWindow
            }()
            guard !isNewProbe && !windowExpired else {
                lastLookupFallbackProbePointKey = probeKey
                lastLookupFallbackWindowStartedAt = now
                lastLookupFallbackAttemptAt = now
                fallbackAttemptsInWindow = 1
                return true
            }
            guard fallbackAttemptsInWindow < maxFallbackAttemptsInWindow else {
                return false
            }
            fallbackAttemptsInWindow += 1
            lastLookupFallbackAttemptAt = now
            return true
        }

        private func lookupBounds(for page: PDFPage) -> CGRect? {
            let key = ObjectIdentifier(page)

            if pagesWithoutLookupBounds.contains(key) {
                return nil
            }
            if let cached = pageLookupBoundsCache[key] {
                return cached
            }

            let mediaBox = page.bounds(for: .mediaBox).integral
            let cropBox = page.bounds(for: .cropBox).integral
            let resolvedBounds = mediaBox.isEmpty == false ? mediaBox : cropBox

            if resolvedBounds.isEmpty {
                pagesWithoutLookupBounds.insert(key)
                return nil
            }

            pageLookupBoundsCache[key] = resolvedBounds
            return resolvedBounds
        }

        private func lookupCandidatePoints(
            around location: CGPoint,
            in bounds: CGRect,
            maxCount: Int
        ) -> [CGPoint] {
            guard bounds.width > 0, bounds.height > 0 else {
                return [location]
            }
            let maxCount = max(1, maxCount)

            let spacing = min(ReaderLookupLimits.longPressAllowableMovement, LookupPoint.maxMovementCap)
            var candidates: [CGPoint] = []
            var seenKeys: Set<UInt64> = []
            candidates.reserveCapacity(LookupPoint.sampleCount)
            seenKeys.reserveCapacity(LookupPoint.sampleCount)

            let baseKey = lookupPointKey(for: location)
            seenKeys.insert(baseKey)
            candidates.append(location)

            for baseDelta in LookupPoint.candidateDeltas {
                let delta = CGPoint(x: baseDelta.x * spacing, y: baseDelta.y * spacing)
                let raw = CGPoint(x: location.x + delta.x, y: location.y + delta.y)
                let clamped = CGPoint(
                    x: min(max(raw.x, 0), bounds.width),
                    y: min(max(raw.y, 0), bounds.height)
                )
                let pointKey = lookupPointKey(for: clamped)
                guard seenKeys.insert(pointKey).inserted else { continue }
                candidates.append(clamped)
                if candidates.count >= maxCount {
                    break
                }
            }
            return candidates
        }

        @inline(__always)
        private func lookupPointKey(for point: CGPoint) -> UInt64 {
            let x = max(0, Int64(lookupSignatureQuantizedCoordinate(point.x)))
            let y = max(0, Int64(lookupSignatureQuantizedCoordinate(point.y)))
            let xBits = UInt64(bitPattern: x)
            let yBits = UInt64(UInt32(truncatingIfNeeded: y))
            return (xBits << 32) ^ yBits
        }

        @inline(__always)
        private func lookupSignatureQuantizedCoordinate(_ value: CGFloat) -> Int {
            guard value.isFinite else { return 0 }
            let clamped = max(0, value)
            return Int((clamped / LookupPoint.signatureQuantization).rounded(.towardZero))
        }

        @inline(__always)
        private func lookupSignatureComponentString(_ point: CGPoint) -> String {
            "\(lookupSignatureQuantizedCoordinate(point.x))|\(lookupSignatureQuantizedCoordinate(point.y))"
        }

        private func performLookupCandidate(
            in pdfView: PDFView,
            page: PDFPage,
            pagePoint: CGPoint,
            originalPagePoint: CGPoint? = nil,
            lookupBounds: CGRect,
            pageIndex: Int,
            lookupSessionId: UInt64
        ) -> WordSelection? {
            if lookupBounds.isEmpty == false &&
                lookupBounds.insetBy(dx: -LookupPoint.lookupBoundsInset, dy: -LookupPoint.lookupBoundsInset).contains(pagePoint) == false {
                #if DEBUG
                if shouldEmitDebug(tag: "lookupCandidate", signature: "\(pagePoint.x),\(pagePoint.y)|\(lookupBounds.origin.x),\(lookupBounds.origin.y)|\(lookupBounds.width),\(lookupBounds.height)") {
                    print("[LongPressDebug] performLookupCandidate: point \(pagePoint) outside lookupBounds \(lookupBounds)")
                }
                #endif
                return nil
            }
            // `selection(for: CGPoint, tolerance:)` isn't available on iOS; use word-level selection instead.
            if let selection = pickWordSelectionFromPoint(in: page, around: pagePoint) {
              let rawText = (ReaderSelectionFilter.filteredText(from: selection) ?? selection.string) ?? ""
              let selectedText = ReaderSelectionFilter.normalizedLookupText(rawText)
              guard selectedText.isEmpty == false else {
                return nil
              }
                let rectOnPage = selection.bounds(for: page)
                guard rectOnPage.isNull == false,
                      rectOnPage.width > 0,
                      rectOnPage.height > 0 else { return nil }
                if let origPt = originalPagePoint {
                    let originalPaddedRect = rectOnPage.insetBy(dx: -10, dy: -10)
                    guard originalPaddedRect.contains(origPt) else { return nil }
                }
                let isWithinTextHitDistance = ReaderSelectionFilter.isWithinLookupHitDistance(
                    point: pagePoint,
                    rect: rectOnPage,
                    profile: .textSelection
                )
                let isWithinOCRHitDistance = ReaderSelectionFilter.isWithinLookupHitDistance(
                    point: pagePoint,
                    rect: rectOnPage,
                    profile: .ocrSelection
                )
                let isWithinOCRHitDistanceRelaxed = ReaderSelectionFilter.isWithinLookupHitDistanceRelaxed(
                    point: pagePoint,
                    rect: rectOnPage,
                    profile: .ocrSelection
                )
                guard isWithinTextHitDistance || isWithinOCRHitDistance || isWithinOCRHitDistanceRelaxed else {
                    #if DEBUG
                    if shouldEmitDebug(
                      tag: "lookupCandidate",
                      signature: "reject-distance|\(ReaderSelectionFilter.distance(from: pagePoint, to: rectOnPage))|\(ReaderLookupLimits.lookupHitDistanceThreshold(for: rectOnPage))|\(pageIndex)"
                    ) {
                        print(
                          "[LongPressDebug] performLookupCandidate: point "
                          + "\(pagePoint.x),\(pagePoint.y) too far from "
                          + "selection rect \(rectOnPage.origin.x),\(rectOnPage.origin.y),"
                          + "\(rectOnPage.width),\(rectOnPage.height)"
                        )
                    }
                    #endif
                    return nil
                }

                // CJK single-character expansion: if PDFKit returned only 1-2 Han characters,
                // use line-level selection + NLTokenizer to find the full word.
                var expandedSelectedText = selectedText
                var effectiveRectOnPage = rectOnPage
                if ReaderSelectionFilter.containsHan(selectedText) && selectedText.count <= 2 {
                    if let lineSelection = page.selectionForLine(at: pagePoint),
                       let lineText = lineSelection.string,
                       !lineText.isEmpty {
                        let lineRect = lineSelection.bounds(for: page)
                        if let segment = ReaderSelectionFilter.expandCJKWordFromLine(
                            selectedText: selectedText,
                            lineText: lineText,
                            selectedRect: rectOnPage,
                            lineRect: lineRect
                        ) {
                            expandedSelectedText = segment.word
                            // Update rect to cover the expanded word within the line.
                            effectiveRectOnPage = CGRect(
                                x: lineRect.minX + lineRect.width * segment.xRange.lowerBound,
                                y: rectOnPage.minY,
                                width: lineRect.width * (segment.xRange.upperBound - segment.xRange.lowerBound),
                                height: rectOnPage.height
                            )
                        }
                    }
                }

                let rectOnView = pdfView.convert(effectiveRectOnPage, from: page)
                let boundedText = ReaderView.boundedLookupText(expandedSelectedText, maxWordCount: ReaderLookupLimits.maxPopupWordCount)
                let pressXRatio = rectOnPage.width > 0 ? (pagePoint.x - rectOnPage.minX) / rectOnPage.width : LookupPoint.fallbackPressXRatio
                let corrected = ReaderSelectionFilter.correctMergedEnglishWordIfNeeded(
                    boundedText.text,
                    pressXRatio: pressXRatio
                )
                // Fallback: if spellcheck-based splitting failed but the token looks merged,
                // try extracting the longest valid word at the press position.
                // CJK path: segment Chinese text into words using NLTokenizer.
                let resolvedSegment: ReaderSelectionFilter.WordSegment? = corrected ?? {
                    if ReaderSelectionFilter.containsHan(boundedText.text) && boundedText.text.count > 4 {
                        return ReaderSelectionFilter.extractCJKWordAtPress(
                            from: boundedText.text,
                            pressXRatio: pressXRatio
                        )
                    }
                    guard ReaderSelectionFilter.isMergedToken(boundedText.text) else { return nil }
                    return ReaderSelectionFilter.extractWordByPressPosition(
                        boundedText.text,
                        pressXRatio: pressXRatio
                    )
                }()
                let effectiveText = resolvedSegment?.word ?? expandedSelectedText
                if effectiveText.isEmpty { return nil }
                let wordSignature = [
                    "\(pageIndex)",
                    "\(effectiveText.lowercased())",
                    lookupSignatureComponentString(pagePoint)
                ].joined(separator: "|")
                if wordSignature == lastLookupWordSignature {
                    return nil
                }
                lastLookupWordSignature = wordSignature
                let anchorRect: CGRect = {
                    guard let segment = resolvedSegment else { return rectOnView }
                    return CGRect(
                        x: rectOnView.minX + rectOnView.width * segment.xRange.lowerBound,
                        y: rectOnView.minY,
                        width: rectOnView.width * (segment.xRange.upperBound - segment.xRange.lowerBound),
                        height: rectOnView.height
                    )
                }()
                let anchor = CGPoint(
                    x: anchorRect.midX,
                    y: max(anchorRect.minY - Gesture.popupYOffset, Gesture.popupMinY)
                )
                let sentence = ReaderView.boundedLookupText(
                    ReaderSelectionFilter.contextSentence(from: selection) ?? effectiveText,
                    maxWordCount: ReaderLookupLimits.maxPopupContextWordCount
                ).text

                let correctedRectOnPage: CGRect = {
                    guard let segment = resolvedSegment else { return effectiveRectOnPage }
                    return CGRect(
                        x: effectiveRectOnPage.minX + effectiveRectOnPage.width * segment.xRange.lowerBound,
                        y: effectiveRectOnPage.minY,
                        width: effectiveRectOnPage.width * (segment.xRange.upperBound - segment.xRange.lowerBound),
                        height: effectiveRectOnPage.height
                    )
                }()
                let selection = WordSelection(
                    text: effectiveText,
                    sentence: sentence,
                    anchor: anchor,
                    pageIndex: pageIndex,
                    highlightRect: anchorRect,
                    rectOnPage: correctedRectOnPage,
                    page: page
                )
                return selection
            }
            return nil
        }

        private func pickWordSelectionFromPoint(
            in page: PDFPage,
            around pagePoint: CGPoint
        ) -> PDFSelection? {
            let offsets: [CGPoint] = [
                .zero,
                CGPoint(x: 1.2, y: 0),
                CGPoint(x: -1.2, y: 0),
                CGPoint(x: 0, y: 1.2),
                CGPoint(x: 0, y: -1.2),
                CGPoint(x: 1.8, y: 1.8),
                CGPoint(x: -1.8, y: 1.8),
                CGPoint(x: 1.8, y: -1.8),
                CGPoint(x: -1.8, y: -1.8),
                CGPoint(x: 3.0, y: 0),
                CGPoint(x: -3.0, y: 0),
                CGPoint(x: 0, y: 3.0),
                CGPoint(x: 0, y: -3.0)
            ]
            var bestSelection: PDFSelection?
            var bestDistance = CGFloat.greatestFiniteMagnitude

            for offset in offsets {
                let candidatePoint = CGPoint(
                    x: pagePoint.x + offset.x,
                    y: pagePoint.y + offset.y
                )
                guard let selection = page.selectionForWord(at: candidatePoint) else { continue }
                let rect = selection.bounds(for: page)
                guard rect.isNull == false else { continue }
                let distance = ReaderSelectionFilter.distance(from: pagePoint, to: rect)
                if distance < bestDistance {
                    bestDistance = distance
                    bestSelection = selection
                    if distance <= 1.2 {
                        break
                    }
                }
            }

            // Fallback: if selectionForWord returned nil for all candidates,
            // try line-level selection. This handles CJK text where PDFKit
            // cannot detect word boundaries due to the absence of spaces.
            if bestSelection == nil {
                if let lineSelection = page.selectionForLine(at: pagePoint) {
                    let lineRect = lineSelection.bounds(for: page)
                    if !lineRect.isNull && lineRect.width > 0 && lineRect.height > 0 {
                        let paddedRect = lineRect.insetBy(dx: -8, dy: -8)
                        if paddedRect.contains(pagePoint) {
                            bestSelection = lineSelection
                        }
                    }
                }
            }

            if let best = bestSelection {
                let rect = best.bounds(for: page)
                let paddedRect = rect.insetBy(dx: -8, dy: -8)
                if !paddedRect.contains(pagePoint) {
                    return nil
                }
            }
            return bestSelection
        }

        private func emitLookupSelection(
            _ selection: WordSelection,
            in pdfView: PDFView,
            lookupSessionId: UInt64,
            allowLateDelivery: Bool = false
        ) {
            _ = allowLateDelivery
            emitLongPressLookupHaptic()
            Task { @MainActor in
                if self.isLookupSessionUsable(lookupSessionId) == false {
                    #if DEBUG
                    if self.shouldEmitDebug(tag: "lookupSession", signature: "skip-emit:\(lookupSessionId)") {
                        print("[LongPressDebug] emitLookupSelection stale session=\(lookupSessionId)")
                    }
                    #endif
                    return
                }
                onSelection(selection, pdfView)
            }
        }

        func updateLayoutIfNeeded(using pdfView: PDFView) {
            self.pdfView = pdfView

            let size = quantizedSize(pdfView.bounds.size)
            let isLandscape = size.width > size.height
            let signature = LayoutSignature(size: size, isLandscape: isLandscape)
            guard signature != lastLayoutSignature else { return }
            lastLayoutSignature = signature

            let desiredDisplayMode: PDFDisplayMode = isLandscape ? .twoUp : .singlePage
            let desiredAsBook = isLandscape
            let layoutChanged = (pdfView.displayMode != desiredDisplayMode) || (pdfView.displaysAsBook != desiredAsBook)

            if layoutChanged {
                if isLandscape {
                    // usePageViewController doesn't support twoUp — disable it and use custom swipe gestures.
                    (pdfView as? ReadTapPDFView)?.restoreScrollViewDefaults()
                    pdfView.usePageViewController(false, withViewOptions: nil)
                    pdfView.displayMode = desiredDisplayMode
                    pdfView.displaysAsBook = desiredAsBook
                    (pdfView as? ReadTapPDFView)?.installLandscapeSwipeGestures()
                } else {
                    (pdfView as? ReadTapPDFView)?.removeLandscapeSwipeGestures()
                    pdfView.usePageViewController(true, withViewOptions: nil)
                    pdfView.displayMode = desiredDisplayMode
                    pdfView.displaysAsBook = desiredAsBook
                }
            }
            if pdfView.displayDirection != .horizontal {
                pdfView.displayDirection = .horizontal
            }

            // In twoUp mode, enable page breaks with minimal margins for a book-spread feel.
            pdfView.displaysPageBreaks = isLandscape
            if isLandscape {
                pdfView.pageBreakMargins = UIEdgeInsets(
                    top: 0,
                    left: Layout.landscapePageBreakInset,
                    bottom: 0,
                    right: Layout.landscapePageBreakInset
                )
            } else {
                pdfView.pageBreakMargins = .zero
            }

            let fit = pdfView.scaleFactorForSizeToFit
            if fit > 0 {
                cachedFitScale = fit

                // Calculate and cache fit-to-width scale for portrait mode
                if !isLandscape {
                    let ftw = fitToWidthScale(for: pdfView)
                    if ftw > 0 { cachedFitToWidthScale = ftw }
                } else {
                    cachedFitToWidthScale = 0
                }

                pdfView.minScaleFactor = fit * minZoomRatio
                pdfView.maxScaleFactor = fit * maxZoomRatio
                if pdfView.autoScales {
                    pdfView.autoScales = false
                }

                // In portrait, apply fit-to-width as the default zoom level
                if !isLandscape, cachedFitToWidthScale > 0 {
                    let ftwRatio = cachedFitToWidthScale / fit
                    let currentRatio = resolvedZoomRatio(using: pdfView, fallback: zoomRatio.wrappedValue)
                    // Apply fit-to-width on layout change or if still at default (fit-to-page) zoom
                    if layoutChanged || currentRatio <= minZoomRatio + snapToFitThreshold {
                        let ratio = clampedZoomRatio(ftwRatio)
                        applyZoomRatio(ratio, resetPosition: true)
                    } else {
                        let ratio = normalizedZoomRatio(currentRatio)
                        applyZoomRatio(ratio, resetPosition: layoutChanged)
                    }
                } else {
                    let ratioSource = resolvedZoomRatio(using: pdfView, fallback: zoomRatio.wrappedValue)
                    let ratio = normalizedZoomRatio(ratioSource)
                    applyZoomRatio(ratio, resetPosition: layoutChanged)
                }
            }

            if layoutChanged {
                let shouldRecollect = expectedGestureMode() == .readingSingleTap
                scheduleRefreshLongPressEnabled(recollect: shouldRecollect, delay: Timing.layoutLongPressRefreshDelay)
            }
            scheduleBindingSyncIfNeeded(using: pdfView)
        }

        private func scheduleLookupPressRecovery(timeout: TimeInterval) {
            pendingLookupReset?.cancel()
            pendingLookupReset = nil
            lookupPressRecovery?.cancel()

            if timeout <= 0 {
                resetLookupPressState(force: true, preserveDismissHint: shouldDismissLookupArtifactsOnNextTap)
                return
            }

            let preserveDismissHint = shouldDismissLookupArtifactsOnNextTap
            let task = Task { [weak self] in
                defer {
                    Task { @MainActor in
                        self?.pendingLookupReset = nil
                        self?.lookupPressRecovery = nil
                    }
                }
                do {
                    let nanos = UInt64(timeout * 1_000_000_000)
                    if nanos > 0 {
                        try await Task.sleep(nanoseconds: nanos)
                    }
                } catch {
                    return
                }
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.resetLookupPressState(force: true, preserveDismissHint: preserveDismissHint)
            }
            pendingLookupReset = task
            lookupPressRecovery = task
        }

        private func resetLookupPressState(force: Bool = false, preserveDismissHint: Bool = false) {
            cancelLookupSessionEndTimer()
            endLookupSession()
            pendingLookupTask?.cancel()
            pendingLookupTask = nil
            pendingLookupReset?.cancel()
            pendingLookupReset = nil
            cancelInitialLongPressLookupDelay()
            lookupPressRecovery?.cancel()
            lookupPressRecovery = nil
            didLookupForCurrentLongPress = false
            isFirstLongPressLookup = false
            isPrimingFirstLongPressLookup = false
            firstLongPressWarmupAttemptsLeft = 0
            lastLookupChangedAt = nil
            longPressLookupAttemptCount = 0
            lastLookupFallbackProbePointKey = nil
            lastLookupFallbackAttemptAt = nil
            if !preserveDismissHint {
                shouldDismissLookupArtifactsOnNextTap = false
            }
            lastLookupWordSignature = nil
            lastLookupProbePointKey = nil
            didEmitLongPressHaptic = false

            guard singleTap != nil else {
                isLookupActive = false
                return
            }

            isLookupActive = false
            if force {
                lastLookupPressAt = nil
                suppressSingleTapUntil = nil
                clearSingleTapSuppression()
            }
            guard let pdfView else { return }
            transitionGestureRuntime(to: desiredGestureRuntimePhase(), using: pdfView)
        }

        private func cancelLookupTransitionState() {
            endLookupSession()
            cancelLookupSessionEndTimer()
            pendingLongPressRefresh?.cancel()
            pendingLongPressRefresh = nil
            pendingLookupReset?.cancel()
            pendingLookupReset = nil
            lookupPressRecovery?.cancel()
            lookupPressRecovery = nil
            pendingLookupTask?.cancel()
            pendingLookupTask = nil
            cancelInitialLongPressLookupDelay()
        }

        private func forceResetLookupInteractions() {
            pendingLookupTask?.cancel()
            pendingLookupTask = nil
            resetLookupPressState(force: true)
        }

        private func scheduleInitialLongPressLookupDelay(
            with pdfView: PDFView,
            gesture: UILongPressGestureRecognizer,
            lookupSessionId: UInt64
        ) {
            cancelInitialLongPressLookupDelay()
            let sessionId = lookupSessionId
            let task = Task { [weak self, weak pdfView, weak gesture] in
                defer {
                    Task { @MainActor in
                        self?.pendingFirstLongPressLookup = nil
                    }
                }
                do {
                    let nanos = UInt64(Timing.longPressFirstLookupDeferralDelay * 1_000_000_000)
                    if nanos > 0 {
                        try await Task.sleep(nanoseconds: nanos)
                    }
                } catch {
                    return
                }
                guard let self else { return }
                guard let pdfView, let gesture else { return }
                guard !Task.isCancelled else { return }
                guard self.isLookupActive else { return }
                guard gesture.state == .began || gesture.state == .changed else { return }
                guard self.isLookupSessionCurrent(sessionId) else {
                    #if DEBUG
                    if self.shouldEmitDebug(tag: "lookupSession", signature: "skip-initial-delay:\(sessionId)") {
                        print("[LongPressDebug] scheduleInitialLongPressLookupDelay skip stale session=\(sessionId)")
                    }
                    #endif
                    return
                }
                await MainActor.run {
                    _ = self.performLookupForLongPress(
                        with: pdfView,
                        gesture: gesture,
                        lookupSessionId: sessionId
                    )
                }
            }
            pendingFirstLongPressLookup = task
        }

        private func cancelInitialLongPressLookupDelay() {
            pendingFirstLongPressLookup?.cancel()
            pendingFirstLongPressLookup = nil
        }

        private func emitLongPressLookupHaptic() {
            guard !didEmitLongPressHaptic else { return }
            didEmitLongPressHaptic = true
            longPressLookupHapticGenerator.impactOccurred()
        }

        func loadDocumentAsync(
            from url: URL,
            into pdfView: PDFView,
            onLoadFailed: (() -> Void)?,
            onPDFReady: (() -> Void)?
        ) {
            if isDocumentLoadInFlight && documentLoadInFlightURL == url {
                #if DEBUG
                print("[ReaderPDFLoad] skip duplicate in-flight load for \(url.lastPathComponent)")
                #endif
                return
            }

            let requestToken = documentLoadGeneration + 1
            documentLoadGeneration = requestToken
            isDocumentLoadInFlight = true
            documentLoadInFlightURL = url
            resetGestureStateBeforeDocumentReload(using: pdfView)
            pendingDocumentLoad?.cancel()
            pendingDocumentLoadRetry?.cancel()
            pendingDocumentLoad = nil
            pendingDocumentLoadRetry = nil
            pendingReadySignal?.cancel()
            pendingReadySignal = nil
            pendingOpenPrefetchWork?.cancel()
            pendingOpenPrefetchWork = nil
            pendingGeometryWarmup?.cancel()
            pendingLookupBoundsWarmup?.cancel()
            pendingGeometryWarmup = nil
            pendingLookupBoundsWarmup = nil
            pendingOpenWarmupTask?.cancel()
            pendingOpenWarmupTask = nil
            cancelPendingPagePrefetch()
            prefetchedPageIndexes.removeAll(keepingCapacity: true)
            cancelInitialLongPressLookupDelay()
            lastLookupTaskReset()
            isFirstLongPressAfterLoad = true
            hasDeferredInitialLongPressLookup = false
            hasCompletedInitialLookupWarmup = false
            hasBypassedInitialLookupWarmup = false
            pageLookupBoundsCache.removeAll()
            pagesWithoutLookupBounds.removeAll()
            systemLongPressCollectionGeneration = -1
            cancelSingleTapReadiness()
            cancelLookupPressReadiness()
            cancelInitialInteractionReadiness()
            isSingleTapGesturesReady = false
            isLookupGesturesReady = false
            didCollectSystemLongPressesForCurrentView = false
            readyDocumentLoadGeneration = 0
            lookupPress?.minimumPressDuration = ReaderLookupLimits.longPressFirstTouchMinimumPressDuration

            let maxAttempts = 2
            let requestQueue = documentLoadQueue
            let requestURL = url

            func bind(_ document: PDFDocument) {
                #if DEBUG
                let pageCount = document.pageCount
                let firstPageAvailable = document.page(at: 0) != nil
                print(
                    "[ReaderPDFLoad] token=\(requestToken) "
                    + "bind document url=\(requestURL.lastPathComponent) "
                    + "pages=\(pageCount) "
                    + "firstPage=\(firstPageAvailable)"
                )
                #endif
                self.lastBoundDocumentRef = nil
                self.lastBoundPageCount = -1
                self.lastBoundCurrentPage = -1
                self.lastObservedZoomRatio = normalizedZoomRatio(clampedZoomRatio(self.zoomRatio.wrappedValue))

                if pdfView.document !== document {
                    pdfView.document = nil
                    pdfView.document = document
                }
                self.lastDocumentURL = url
                self.clearDocumentLoadInFlight(for: requestToken)
                self.pageLookupBoundsCache.removeAll()
                self.pagesWithoutLookupBounds.removeAll()
                if pdfView.currentPage == nil, let firstPage = document.page(at: 0) {
                    pdfView.go(to: firstPage)
                }
                pdfView.setNeedsDisplay()
                self.isInteractionReady = true
                #if DEBUG
                if shouldEmitDebug(tag: "bindComplete", signature: "\(self.hostLongPressEnabled)|\(self.expectedGestureMode())|\(self.lookupPress?.isEnabled ?? false)") {
                    print("[LongPressDebug] bind() complete: interactionReady=true lookupPress.isEnabled=\(self.lookupPress?.isEnabled ?? false) hostLongPressEnabled=\(self.hostLongPressEnabled) gestureMode=\(self.expectedGestureMode())")
                }
                #endif
                self.suppressSingleTapTemporarily(Timing.singleTapPostOpenSuppression)
                self.scheduleInitialInteractionReadiness(
                    delay: Timing.singleTapReadinessDelay,
                    generation: requestToken,
                    using: pdfView
                )
                self.needsGestureReactivation = true
                self.schedulePDFReadySignal(
                    requestToken: requestToken,
                    onPDFReady: onPDFReady,
                    for: pdfView,
                    document: document
                )
            }

                if let cached = PDFDocumentCache.shared.document(for: url) {
                    if cached.pageCount > 0, cached.page(at: 0) != nil {
                        PDFDocumentCache.shared.set(cached, for: url)
                        PDFDocumentCache.shared.logSummaryIfNeeded(reason: "cache-hit")
                        #if DEBUG
                        print("[ReaderPDFLoad] token=\(requestToken) cache-hit url=\(requestURL.lastPathComponent) pages=\(cached.pageCount)")
                        #endif
                        guard requestToken == self.documentLoadGeneration else { return }
                        bind(cached)
                        return
                    }
                    PDFDocumentCache.shared.recordStaleHit()
                    PDFDocumentCache.shared.remove(url)
                    #if DEBUG
                print("[ReaderPDFLoad] token=\(requestToken) cache-stale-or-empty url=\(requestURL.lastPathComponent)")
                #endif
            }

            func loadDocumentFromDisk() -> PDFDocument? {
                let urlBased = autoreleasepool { () -> PDFDocument? in
                    PDFDocument(url: requestURL)
                }
                if let doc = urlBased, doc.pageCount > 0, doc.page(at: 0) != nil {
                    #if DEBUG
                    print("[ReaderPDFLoad] token=\(requestToken) attempt-source=url pages=\(doc.pageCount)")
                    #endif
                    return doc
                }
                #if DEBUG
                print("[ReaderPDFLoad] token=\(requestToken) attempt-source=url failed for \(requestURL.lastPathComponent)")
                #endif

                do {
                    let data = try Data(contentsOf: requestURL)
                    let dataBased = autoreleasepool { () -> PDFDocument? in
                        PDFDocument(data: data)
                    }
                    if let doc = dataBased, doc.pageCount > 0, doc.page(at: 0) != nil {
                        #if DEBUG
                        print("[ReaderPDFLoad] token=\(requestToken) attempt-source=data pages=\(doc.pageCount)")
                        #endif
                        return doc
                    }
                    #if DEBUG
                    print("[ReaderPDFLoad] token=\(requestToken) attempt-source=data failed for \(requestURL.lastPathComponent)")
                    #endif
                } catch {
                    #if DEBUG
                    print("[ReaderPDFLoad] token=\(requestToken) data-read-failed for \(requestURL.lastPathComponent): \(error)")
                    #endif
                }
                return nil
            }

            func scheduleLoadAttempt(_ attempt: Int) {
                guard attempt < maxAttempts else {
                    if requestToken == documentLoadGeneration {
                        self.onLoadFailedMainThread(
                            onLoadFailed: onLoadFailed,
                            requestToken: requestToken,
                            requestURL: url,
                            pdfView: pdfView
                        )
                    }
                    return
                }

                let work = DispatchWorkItem { [weak self, weak pdfView] in
                    guard let self else { return }
                    guard requestToken == self.documentLoadGeneration else { return }

                    guard FileManager.default.fileExists(atPath: requestURL.path) else {
                        #if DEBUG
                        print("[ReaderPDFLoad] token=\(requestToken) file-missing path=\(requestURL.path)")
                        #endif
                        if attempt + 1 < maxAttempts {
                            let retryWork = DispatchWorkItem { [weak self] in
                                guard let self else { return }
                                guard requestToken == self.documentLoadGeneration else { return }
                                scheduleLoadAttempt(attempt + 1)
                            }
                            self.pendingDocumentLoadRetry = retryWork
                            requestQueue.asyncAfter(deadline: .now() + Timing.fileLoadRetryDelay, execute: retryWork)
                        } else {
                            if requestToken == self.documentLoadGeneration {
                                self.onLoadFailedMainThread(
                                    onLoadFailed: onLoadFailed,
                                    requestToken: requestToken,
                                    requestURL: url,
                                    pdfView: pdfView
                                )
                            }
                        }
                        return
                    }

                    let loadedDocument = loadDocumentFromDisk()
                    guard requestToken == self.documentLoadGeneration else { return }
                    guard let document = loadedDocument, document.pageCount > 0 else {
                        let retryWork = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            guard requestToken == self.documentLoadGeneration else { return }
                            scheduleLoadAttempt(attempt + 1)
                        }
                        self.pendingDocumentLoadRetry = retryWork
                        requestQueue.asyncAfter(deadline: .now() + Timing.fileLoadRetryDelay, execute: retryWork)
                        return
                    }

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard requestToken == self.documentLoadGeneration else { return }
                        #if DEBUG
                        print("[ReaderPDFLoad] token=\(requestToken) bind-ready pages=\(document.pageCount) attempt=\(attempt+1)")
                        #endif
                        self.clearDocumentLoadInFlight(for: requestToken)
                        guard requestToken == self.documentLoadGeneration else {
                            return
                        }
                        PDFDocumentCache.shared.set(document, for: requestURL)
                        PDFDocumentCache.shared.logSummaryIfNeeded(reason: "load-complete")
                        bind(document)
                    }
                }
                self.pendingDocumentLoad = work
                requestQueue.async(execute: work)
            }
            scheduleLoadAttempt(0)
        }

        private func onLoadFailedMainThread(
            onLoadFailed: (() -> Void)?,
            requestToken: Int,
            requestURL: URL,
            pdfView: PDFView?
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard requestToken == self.documentLoadGeneration else { return }
                self.clearDocumentLoadInFlight(for: requestToken)
                pdfView?.document = nil
                onLoadFailed?()
            }
        }

        private func schedulePDFReadySignal(
            requestToken: Int,
            onPDFReady: (() -> Void)?,
            for pdfView: PDFView,
            document: PDFDocument
        ) {
            // Keep interaction readiness separated from boundary warmup.
            // This allows UI gestures to become active quickly while any expensive
            // geometry/long-press scan tasks continue in the background.
            pendingReadySignal?.cancel()
            let interactionWork = DispatchWorkItem { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                guard requestToken == self.documentLoadGeneration else { return }
                guard self.readyDocumentLoadGeneration != requestToken else { return }

                self.readyDocumentLoadGeneration = requestToken
                onPDFReady?()
                let lookupWarmupDelay = document.pageCount >= PagePrefetch.largeDocumentPageCountThreshold
                    ? PagePrefetch.largeDocumentLookupWarmupDelay
                    : Timing.geometryWarmupDelay
                self.startOpenWarmupSequence(
                    requestToken: requestToken,
                    pdfView: pdfView,
                    document: document,
                    lookupWarmupDelay: lookupWarmupDelay
                )
            }

            pendingReadySignal = interactionWork
            scheduleWork(delay: Timing.pdfReadyStabilizationDelay, workItem: interactionWork)
        }

        private func startOpenWarmupSequence(
            requestToken: Int,
            pdfView: PDFView,
            document: PDFDocument,
            lookupWarmupDelay: TimeInterval
        ) {
            pendingOpenWarmupTask?.cancel()
            let task = Task { @MainActor [weak self] in
                defer {
                    self?.pendingOpenWarmupTask = nil
                }
                guard let self else { return }
                if Task.isCancelled { return }
                guard requestToken == self.documentLoadGeneration else { return }

                do {
                    try await self.runOpenWarmupGeometry(
                        requestToken: requestToken,
                        page: document.page(at: 0),
                        using: pdfView,
                        delay: Timing.geometryWarmupDelay
                    )
                    try await self.runOpenWarmupLookupBounds(
                        requestToken: requestToken,
                        for: document,
                        using: pdfView,
                        delay: lookupWarmupDelay
                    )
                    if Task.isCancelled { return }
                    if Timing.geometryToGestureWarmupDelay > 0 {
                        try await Task.sleep(for: .seconds(Timing.geometryToGestureWarmupDelay))
                    }
                    guard requestToken == documentLoadGeneration else { return }
                    self.scheduleBindingSyncIfNeeded(using: pdfView)
                    self.scheduleRefreshLongPressEnabled(
                        recollect: true,
                        delay: 0
                    )
                    try await self.runOpenPhasePagePrefetchAsync(
                        requestToken: requestToken,
                        using: document
                    )
                } catch {
                    return
                }
            }
            pendingOpenWarmupTask = task
        }

        private func runOpenWarmupGeometry(
            requestToken: Int,
            page: PDFPage?,
            using pdfView: PDFView,
            delay: TimeInterval
        ) async throws {
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            guard requestToken == documentLoadGeneration else { return }
            if Task.isCancelled { return }
            if isLookupActive {
                return
            }

            self.pdfView = pdfView
            if let page {
                self.ensureDisplayBoxValid(for: page)
            } else if let resolved = pdfView.currentPage {
                self.ensureDisplayBoxValid(for: resolved)
            }

            let fit = pdfView.scaleFactorForSizeToFit
            if fit > 0 {
                cachedFitScale = fit
                // In portrait, default to fit-to-width scale on initial load
                let isPortrait = pdfView.bounds.width <= pdfView.bounds.height
                let resolvedRatio = self.resolvedZoomRatio(using: pdfView, fallback: self.zoomRatio.wrappedValue)
                let clampedRatio: CGFloat
                if isPortrait, resolvedRatio <= minZoomRatio + Threshold.tiny {
                    let ftwRatio = fitToWidthZoomRatio(using: pdfView)
                    clampedRatio = max(1.0, min(ftwRatio, 6.0))
                } else {
                    clampedRatio = max(1.0, min(resolvedRatio, 6.0))
                }
                let targetScale = fit * clampedRatio
                let targetMinScale = fit
                let targetMaxScale = fit * 6.0
                if pdfView.minScaleFactor != targetMinScale {
                    pdfView.minScaleFactor = targetMinScale
                }
                if pdfView.maxScaleFactor != targetMaxScale {
                    pdfView.maxScaleFactor = targetMaxScale
                }
                if abs(pdfView.scaleFactor - targetScale) > 0.0001 {
                    pdfView.scaleFactor = targetScale
                }
            }
        }

        private func runOpenWarmupLookupBounds(
            requestToken: Int,
            for document: PDFDocument,
            using pdfView: PDFView,
            delay: TimeInterval
        ) async throws {
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            guard requestToken == documentLoadGeneration else { return }
            guard document.pageCount > 0 else { return }
            if Task.isCancelled { return }

            let total = document.pageCount
            let warmupIndexes: Set<Int> = {
                var candidates: Set<Int> = []
                if let current = pdfView.currentPage {
                    let currentIndex = document.index(for: current)
                    candidates.insert(currentIndex)
                    candidates.insert(max(0, currentIndex - 1))
                    candidates.insert(min(total - 1, currentIndex + 1))
                } else {
                    candidates.insert(0)
                }
                return candidates
            }()

            for index in warmupIndexes {
                guard requestToken == documentLoadGeneration else { return }
                guard index >= 0 && index < total else { continue }
                guard let page = document.page(at: index) else { continue }
                if isLookupActive {
                    await Task.yield()
                    continue
                }
                _ = self.lookupBounds(for: page)
                self.prewarmLongPressLookup(on: page, using: pdfView)
                await Task.yield()
                if Task.isCancelled { return }
            }

            self.hasCompletedInitialLookupWarmup = true
        }

        private func runOpenPhasePagePrefetchAsync(
            requestToken: Int,
            using document: PDFDocument
        ) async throws {
            let preloadRadius = document.pageCount >= PagePrefetch.largeDocumentPageCountThreshold
                ? PagePrefetch.largeDocumentOpenRadius
                : PagePrefetch.initialRadius
            guard preloadRadius > 0 else {
                return
            }

            let delay = document.pageCount >= PagePrefetch.largeDocumentPageCountThreshold
                ? PagePrefetch.largeDocumentOpenBackgroundDelay
                : PagePrefetch.openBackgroundDelay
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            guard requestToken == documentLoadGeneration else { return }
            if Task.isCancelled { return }
            if isLookupActive {
                return
            }
            if hasBypassedInitialLookupWarmup {
                return
            }

            schedulePagePrefetchWindow(
                requestToken: requestToken,
                around: 0,
                using: document,
                delay: PagePrefetch.initialDelay,
                radius: preloadRadius
            )
        }

        private func scheduleOpenPhasePagePrefetch(
            requestToken: Int,
            using document: PDFDocument
        ) {
            pendingOpenPrefetchWork?.cancel()

            let preloadRadius = document.pageCount >= PagePrefetch.largeDocumentPageCountThreshold
                ? PagePrefetch.largeDocumentOpenRadius
                : PagePrefetch.initialRadius
            guard preloadRadius > 0 else {
                return
            }

            let delay = document.pageCount >= PagePrefetch.largeDocumentPageCountThreshold
                ? PagePrefetch.largeDocumentOpenBackgroundDelay
                : PagePrefetch.openBackgroundDelay

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard requestToken == self.documentLoadGeneration else { return }
                self.schedulePagePrefetchWindow(
                    requestToken: requestToken,
                    around: 0,
                    using: document,
                    delay: PagePrefetch.initialDelay,
                    radius: preloadRadius
                )
            }
            pendingOpenPrefetchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func cancelPendingPagePrefetch() {
            pendingPagePrefetch?.cancel()
            pendingPagePrefetch = nil
        }

        private func schedulePagePrefetchWindow(
            requestToken: Int,
            around pageIndex: Int,
            using document: PDFDocument,
            delay: TimeInterval,
            radius: Int? = nil
        ) {
            let effectiveRadius = radius ?? PagePrefetch.initialRadius
            guard requestToken == documentLoadGeneration else { return }
            let total = document.pageCount
            guard total > 1 else { return }

            let isLargeDocument = total >= PagePrefetch.largeDocumentPageCountThreshold
            let effectiveDelay = isLargeDocument ? (delay + PagePrefetch.largeDocumentExtraDelay) : delay
            let finalRadius = isLargeDocument ? 1 : effectiveRadius
            let effectiveMaxPages = isLargeDocument
                ? PagePrefetch.largeDocumentMaxPagesPerPass
                : PagePrefetch.maxPagesPerPass
            let effectiveInterDelay = isLargeDocument
                ? PagePrefetch.largeDocumentInterPageDelay
                : PagePrefetch.interPageDelay

            let clampedPageIndex = max(0, min(pageIndex, total - 1))
            let warmupRadius = max(1, min(finalRadius, 2))
            let candidates = prefetchCandidateIndexes(
                center: clampedPageIndex,
                total: total,
                radius: warmupRadius
            ).filter { !prefetchedPageIndexes.contains($0) }
            let boundedCandidates = Array(candidates.prefix(effectiveMaxPages))
            guard !boundedCandidates.isEmpty else { return }

            cancelPendingPagePrefetch()
            schedulePagePrefetchStep(
                requestToken: requestToken,
                using: document,
                indexes: boundedCandidates,
                step: 0,
                delay: max(0, effectiveDelay),
                interPageDelay: effectiveInterDelay
            )
        }

        private func prefetchCandidateIndexes(center: Int, total: Int, radius: Int) -> [Int] {
            guard radius > 0, total > 1 else { return [] }
            var candidates: [Int] = []
            for offset in 1...radius {
                let next = center + offset
                if next < total {
                    candidates.append(next)
                }
                let prev = center - offset
                if prev >= 0 {
                    candidates.append(prev)
                }
                if candidates.count >= PagePrefetch.maxPagesPerPass {
                    break
                }
            }
            return candidates
        }

        private func schedulePagePrefetchStep(
            requestToken: Int,
            using document: PDFDocument,
            indexes: [Int],
            step: Int,
            delay: TimeInterval,
            interPageDelay: TimeInterval
        ) {
            guard step < indexes.count else { return }
            guard requestToken == documentLoadGeneration else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard requestToken == self.documentLoadGeneration else { return }
                guard step < indexes.count else { return }
                if self.isLookupActive || self.hasBypassedInitialLookupWarmup {
                    self.schedulePagePrefetchStep(
                        requestToken: requestToken,
                        using: document,
                        indexes: indexes,
                        step: step,
                        delay: max(interPageDelay, 0.05),
                        interPageDelay: interPageDelay
                    )
                    return
                }

                let pageIndex = indexes[step]
                if let page = document.page(at: pageIndex) {
                    _ = page.bounds(for: .mediaBox)
                    _ = page.bounds(for: .cropBox)
                    self.prefetchedPageIndexes.insert(pageIndex)
                }

                let nextStep = step + 1
                guard nextStep < indexes.count else { return }

                self.schedulePagePrefetchStep(
                    requestToken: requestToken,
                    using: document,
                    indexes: indexes,
                    step: nextStep,
                    delay: interPageDelay,
                    interPageDelay: interPageDelay
                )
            }
            pendingPagePrefetch = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func scheduleWork(delay: TimeInterval, workItem: DispatchWorkItem) {
            guard delay > 0 else {
                if Thread.isMainThread {
                    workItem.perform()
                } else {
                    DispatchQueue.main.async(execute: workItem)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func cancelSingleTapReadiness() {
            pendingSingleTapReadiness?.cancel()
            pendingSingleTapReadiness = nil
        }

        private func cancelInitialInteractionReadiness() {
            pendingInitialInteractionReadiness?.cancel()
            pendingInitialInteractionReadiness = nil
        }

        private func scheduleInitialInteractionReadiness(
            delay: TimeInterval,
            generation: Int,
            using pdfView: PDFView
        ) {
            cancelInitialInteractionReadiness()
            cancelSingleTapReadiness()
            cancelLookupPressReadiness()
            isSingleTapGesturesReady = false
            isLookupGesturesReady = false

            let task = Task { [weak self, weak pdfView] in
                defer {
                    if let self {
                        self.pendingInitialInteractionReadiness = nil
                    }
                }
                if delay > 0 {
                    let nanos = UInt64(delay * 1_000_000_000)
                    if nanos > 0 {
                        do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                    }
                }
                guard let self, let pdfView else { return }
                guard !Task.isCancelled else { return }
                guard generation == self.documentLoadGeneration else { return }
                guard self.readerMode.wrappedValue == .reading else { return }
                guard self.isInteractionReady else { return }

                self.isSingleTapGesturesReady = true
                self.isLookupGesturesReady = self.longPressEnabled()
                    && (self.hasCompletedInitialLookupWarmup || self.hasBypassedInitialLookupWarmup)
                self.applyGestureMode(using: pdfView, recollect: false)
                self.transitionGestureRuntime(to: self.desiredGestureRuntimePhase(), using: pdfView)
            }
            pendingInitialInteractionReadiness = task
        }

        private func scheduleSingleTapReadiness(
            delay: TimeInterval,
            generation: Int,
            using pdfView: PDFView
        ) {
            scheduleSingleTapReadiness(
                delay: delay,
                generation: generation,
                using: pdfView,
                onReady: nil
            )
        }

        private func scheduleSingleTapReadiness(
            delay: TimeInterval,
            generation: Int,
            using pdfView: PDFView,
            onReady: (() -> Void)?
        ) {
            guard readerMode.wrappedValue == .reading else {
                isSingleTapGesturesReady = false
                onReady?()
                return
            }
            cancelSingleTapReadiness()
            isSingleTapGesturesReady = false

            let workReady = onReady
            let task = Task { [weak self, weak pdfView] in
                defer {
                    if let self {
                        self.pendingSingleTapReadiness = nil
                    }
                }
                if delay > 0 {
                    let nanos = UInt64(delay * 1_000_000_000)
                    if nanos > 0 {
                        do { try await Task.sleep(nanoseconds: nanos) } catch {
                            return
                        }
                    }
                }
                guard let self, let pdfView else { return }
                guard !Task.isCancelled else { return }
                guard generation == self.documentLoadGeneration else {
                    workReady?()
                    return
                }
                guard self.readerMode.wrappedValue == .reading else {
                    workReady?()
                    return
                }
                guard self.isInteractionReady else {
                    workReady?()
                    return
                }

                self.isSingleTapGesturesReady = true
                // Don't reset isLookupGesturesReady based on lookupInteractionReady;
                // the lookup gesture should stay enabled whenever longPressEnabled() is true
                // so users can long-press even while OCR is running on a new page.
                self.applyGestureMode(using: pdfView, recollect: false)
                self.transitionGestureRuntime(to: self.desiredGestureRuntimePhase(), using: pdfView)
                workReady?()
            }
            pendingSingleTapReadiness = task
        }

        private func cancelLookupPressReadiness() {
            pendingLookupPressReadiness?.cancel()
            pendingLookupPressReadiness = nil
        }

        private func resetGestureStateBeforeDocumentReload(using pdfView: PDFView) {
            cancelSingleTapReadiness()
            cancelLookupPressReadiness()
            cancelInitialInteractionReadiness()
            cancelLookupTransitionState()
            clearSingleTapSuppression()

            isInteractionReady = false
            isSingleTapGesturesReady = false
            isLookupGesturesReady = false
            gestureRuntimePhase = .inactive
            didCollectSystemLongPressesForCurrentView = false
            systemLongPressCollectionViewID = nil
            systemLongPressCollectionGeneration = -1
            lastSystemLongPressScanAt = .distantPast
            systemLongPresses.removeAll()

            isFirstLongPressLookup = false
            isFirstLongPressAfterLoad = true
            hasCompletedInitialLookupWarmup = false
            hasBypassedInitialLookupWarmup = false
            hasDeferredInitialLongPressLookup = false
            isPrimingFirstLongPressLookup = false
            firstLongPressWarmupAttemptsLeft = 0
            longPressLookupAttemptCount = 0

            isLookupActive = false
            isApplyingProgrammaticScale = false
            isHandlingPageChange = false
            didEmitLongPressHaptic = false
            shouldDismissLookupArtifactsOnNextTap = false
            didLookupForCurrentLongPress = false

            lastSingleTapAt = nil
            lastTwoFingerTapAt = nil
            lastLookupPressAt = nil
            lastLookupGestureAt = nil
            lastLookupSelectionSignature = nil
            lastLookupWordSignature = nil
            lastLookupProbePointKey = nil
            lastLookupFallbackProbePointKey = nil
            lastLookupFallbackAttemptAt = nil
            lastLookupChangedAt = nil
            lastSuccessfulLongPressLookupAt = nil
            lastSelectionAt = nil
            lastLayoutSignature = nil
            lastPageBoxSize = nil
            cachedFitScale = 0
            cachedFitToWidthScale = 0
            lastDisplayBox = nil
            lastObservedZoomRatio = nil

            lastAppliedGestureState = nil
            lastAppliedGestureViewID = nil
            lastScheduledGestureRefreshSignature = nil
            lastAppliedGestureRefreshSignature = nil
            lastGestureRefreshAt = .distantPast

            queueBindingValue(hasTextSelection, to: false)
            pdfView.clearSelection()
            if let readerPDFView = pdfView as? ReadTapPDFView {
                readerPDFView.forceClearSelection()
                readerPDFView.clearLookupHighlight(immediate: true)
            }
            resetLookupPressState(force: true, preserveDismissHint: false)
            applyGestureMode(using: pdfView, recollect: true)
        }

        private func scheduleLookupPressReadiness(
            delay: TimeInterval,
            generation: Int,
            using pdfView: PDFView
        ) {
            scheduleLookupPressReadiness(
                delay: delay,
                generation: generation,
                using: pdfView,
                onReady: nil
            )
        }

        private func scheduleLookupPressReadiness(
            delay: TimeInterval,
            generation: Int,
            using pdfView: PDFView,
            onReady: (() -> Void)?
        ) {
            guard longPressEnabled() else {
                isLookupGesturesReady = false
                onReady?()
                return
            }
            cancelLookupPressReadiness()

            let workReady = onReady
            let task = Task { [weak self, weak pdfView] in
                defer {
                    if let self {
                        self.pendingLookupPressReadiness = nil
                    }
                }
                if delay > 0 {
                    let nanos = UInt64(delay * 1_000_000_000)
                    if nanos > 0 {
                        do { try await Task.sleep(nanoseconds: nanos) } catch {
                            return
                        }
                    }
                }
                guard let self, let pdfView else { return }
                guard !Task.isCancelled else { return }
                guard generation == self.documentLoadGeneration else {
                    workReady?()
                    return
                }
                guard self.readerMode.wrappedValue == .reading else {
                    workReady?()
                    return
                }
                guard self.isInteractionReady else {
                    workReady?()
                    return
                }
                if !self.hasCompletedInitialLookupWarmup && !self.hasBypassedInitialLookupWarmup {
                    workReady?()
                    try? await Task.sleep(for: .seconds(Timing.boundaryWarmupDelay))
                    self.scheduleLookupPressReadiness(
                        delay: 0,
                        generation: generation,
                        using: pdfView
                    )
                    return
                }
                guard self.longPressEnabled() else {
                    self.isLookupGesturesReady = false
                    workReady?()
                    self.applyGestureMode(using: pdfView, recollect: false)
                    return
                }

                self.isLookupGesturesReady = true
                self.applyGestureMode(using: pdfView, recollect: false)
                self.transitionGestureRuntime(to: self.desiredGestureRuntimePhase(), using: pdfView)
                workReady?()
            }
            pendingLookupPressReadiness = task
        }

        fileprivate func scheduleBindingSyncIfNeeded(using pdfView: PDFView) {
            guard let doc = pdfView.document else { return }
            let docRef = ObjectIdentifier(doc)
            let pageCount = doc.pageCount
            let currentPageIndex = pdfView.currentPage.flatMap { doc.index(for: $0) } ?? 0
            let shouldSync = lastBoundDocumentRef == nil
                || lastBoundDocumentRef != docRef
                || lastBoundPageCount != pageCount
                || lastBoundCurrentPage != currentPageIndex

            guard shouldSync else {
                return
            }

            lastBoundDocumentRef = docRef
            lastBoundPageCount = pageCount
            lastBoundCurrentPage = currentPageIndex
            pendingBindingSync?.cancel()
            let delay = UInt64(0.003 * 1_000_000_000)
            let task = Task { [weak self, weak pdfView] in
                defer {
                    Task { @MainActor in
                        self?.pendingBindingSync = nil
                    }
                }
                do {
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: delay)
                    }
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard let pdfView else { return }
                guard let doc = pdfView.document else { return }

                let pageCount = doc.pageCount
                if pageCount > 0, self.totalPages.wrappedValue != pageCount {
                    self.queueBindingValue(self.totalPages, to: pageCount)
                }
                if let page = pdfView.currentPage {
                    let index = doc.index(for: page)
                    if self.currentPageIndex.wrappedValue != index {
                        self.queueBindingValue(self.currentPageIndex, to: index)
                    }
                }
            }
            pendingBindingSync = task
        }

        func scheduleGeometryWarmup(for page: PDFPage?, using pdfView: PDFView, delay: TimeInterval) {
            pendingGeometryWarmup?.cancel()
            let task = Task { @MainActor [weak self, weak pdfView] in
                defer {
                    Task { @MainActor in
                        self?.pendingGeometryWarmup = nil
                    }
                }
                do {
                    let delayNanos = UInt64(delay * 1_000_000_000)
                    if delayNanos > 0 {
                        try await Task.sleep(nanoseconds: delayNanos)
                    }
                }
                catch {
                    return
                }
                guard let self else { return }
                guard let pdfView else { return }
                self.pdfView = pdfView

                if let page = page {
                    self.ensureDisplayBoxValid(for: page)
                } else if let resolved = pdfView.currentPage {
                    self.ensureDisplayBoxValid(for: resolved)
                }

                let fit = pdfView.scaleFactorForSizeToFit
                if fit > 0 {
                    let clampedRatio = max(1.0, min(self.resolvedZoomRatio(using: pdfView, fallback: self.zoomRatio.wrappedValue), 6.0))
                    let targetScale = fit * clampedRatio
                    let targetMinScale = fit
                    let targetMaxScale = fit * 6.0
                    if pdfView.minScaleFactor != targetMinScale {
                        pdfView.minScaleFactor = targetMinScale
                    }
                    if pdfView.maxScaleFactor != targetMaxScale {
                        pdfView.maxScaleFactor = targetMaxScale
                    }
                    if abs(pdfView.scaleFactor - targetScale) > 0.0001 {
                        pdfView.scaleFactor = targetScale
                    }
                }
            }
            pendingGeometryWarmup = task
        }

        private func scheduleLookupBoundsWarmup(
            for document: PDFDocument,
            using pdfView: PDFView,
            delay: TimeInterval,
            generation: Int
        ) {
            pendingLookupBoundsWarmup?.cancel()
            let task = Task { @MainActor [weak self, weak pdfView] in
                defer {
                    Task { @MainActor in
                        self?.pendingLookupBoundsWarmup = nil
                    }
                }
                do {
                    let delayNanos = UInt64(delay * 1_000_000_000)
                    if delayNanos > 0 {
                        try await Task.sleep(nanoseconds: delayNanos)
                    }
                } catch {
                    return
                }
                guard let self else { return }
                guard generation == self.documentLoadGeneration else { return }
                guard let pdfView else { return }
                guard document.pageCount > 0 else { return }

                let total = document.pageCount
                let warmupIndexes: Set<Int> = {
                    var candidates: Set<Int> = []
                    if let current = pdfView.currentPage {
                        let currentIndex = document.index(for: current)
                        candidates.insert(currentIndex)
                        candidates.insert(max(0, currentIndex - 1))
                        candidates.insert(min(total - 1, currentIndex + 1))
                    } else {
                        candidates.insert(0)
                    }
                    return candidates
                }()

                for index in warmupIndexes {
                    guard index >= 0 && index < total else { continue }
                    guard let page = document.page(at: index) else { continue }
                    _ = self.lookupBounds(for: page)
                    self.prewarmLongPressLookup(on: page, using: pdfView)
                    await Task.yield()
                }

                self.hasCompletedInitialLookupWarmup = true
            }
            pendingLookupBoundsWarmup = task
        }

        private func prewarmLongPressLookup(
            on page: PDFPage,
            using pdfView: PDFView
        ) {
            let pageBounds = page.bounds(for: .cropBox)
            let pageBoundsOnView = pdfView.convert(pageBounds, from: page)
            guard pageBoundsOnView.isNull == false,
                  pageBoundsOnView.width.isFinite,
                  pageBoundsOnView.height.isFinite else {
                return
            }

            let visibleBounds = pageBoundsOnView.intersection(pdfView.bounds)
            if visibleBounds.isEmpty || visibleBounds.isNull {
                return
            }

            let xPositions: [CGFloat] = [
                visibleBounds.minX + visibleBounds.width * 0.2,
                visibleBounds.midX,
                visibleBounds.maxX - visibleBounds.width * 0.2
            ]
            let yPositions: [CGFloat] = [
                visibleBounds.minY + visibleBounds.height * 0.3,
                visibleBounds.midY,
                visibleBounds.maxY - visibleBounds.height * 0.3
            ]

            for x in xPositions {
                for y in yPositions {
                    let seedPoint = CGPoint(x: x, y: y)
                    for warmupPoint in lookupCandidatePoints(
                        around: seedPoint,
                        in: visibleBounds,
                        maxCount: 3
                    ) {
                        let pointOnPage = pdfView.convert(warmupPoint, to: page)
                        guard pointOnPage.x.isFinite && pointOnPage.y.isFinite else { continue }
                        _ = page.selectionForWord(at: pointOnPage)
                        _ = page.selectionForLine(at: pointOnPage)
                    }
                }
            }

            _ = page.characterBounds(at: 0)
        }

        func ensureDisplayBoxValid(for page: PDFPage) {
            guard let pdfView else { return }
            let crop = page.bounds(for: .cropBox)
            let media = page.bounds(for: .mediaBox)
            let cropArea = crop.width * crop.height
            let mediaArea = media.width * media.height

            let target: PDFDisplayBox
            if cropArea < 1 || (mediaArea > 0 && cropArea < mediaArea * 0.2) {
                target = .mediaBox
            } else {
                target = .cropBox
            }

            guard target != lastDisplayBox else { return }
            lastDisplayBox = target
            pdfView.displayBox = target
            cachedFitScale = 0
            cachedFitToWidthScale = 0
        }

        private func scheduleRefreshLongPressEnabled(recollect: Bool, delay: TimeInterval) {
            let signature = GestureRefreshSignature(
                from: self,
                recollect: recollect,
                viewID: pdfView.map { ObjectIdentifier($0) }
            )
            if pendingLongPressRefresh != nil,
               signature == lastScheduledGestureRefreshSignature {
                return
            }

            lastScheduledGestureRefreshSignature = signature
            pendingLongPressRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingLongPressRefresh = nil
                self.lastScheduledGestureRefreshSignature = nil
                self.refreshLongPressEnabledNow(recollect: recollect)
            }
            pendingLongPressRefresh = work
            scheduleWork(delay: delay, workItem: work)
        }

        private func refreshLongPressEnabledNow(recollect: Bool) {
            let signature = GestureRefreshSignature(
                from: self,
                recollect: recollect,
                viewID: pdfView.map { ObjectIdentifier($0) }
            )

            guard signature != lastAppliedGestureRefreshSignature else {
                return
            }
            #if DEBUG
            let logSignature = [
                "mode=\(expectedGestureMode())",
                "interactionReady=\(isInteractionReady)",
                "singleTapReady=\(isSingleTapGesturesReady)",
                "lookupReady=\(isLookupGesturesReady)",
                "hostLongPress=\(hostLongPressEnabled)",
                "applyingProgrammaticScale=\(isApplyingProgrammaticScale)",
                "handlingPageChange=\(isHandlingPageChange)",
                "readerMode=\(readerMode.wrappedValue)",
                "suppressSingleTap=\(shouldSuppressSingleTap)"
            ].joined(separator: "|")
            if shouldEmitDebug(tag: "refreshConfig", signature: logSignature) {
                debugLongPressState("refreshConfig")
            }
            #endif
            guard let pdfView, pdfView.window != nil else { return }
            guard Date().timeIntervalSince(lastGestureRefreshAt) > Timing.longPressStateRefreshThrottle || recollect else {
                return
            }
            lastGestureRefreshAt = Date()
            lastAppliedGestureRefreshSignature = signature
            applyGestureMode(using: pdfView, recollect: recollect)
        }

        private func expectedGestureMode() -> GestureMode {
            if readerMode.wrappedValue != .reading {
                return .nonReading
            }
            return hostLongPressEnabled ? .readingLongPress : .readingSingleTap
        }

        private func isLongPressMode() -> Bool {
            expectedGestureMode() == .readingLongPress
        }

        private func canHandleSingleTapGesture() -> Bool {
            if shouldDismissLookupArtifactsOnNextTap {
                return true
            }

            if isApplyingProgrammaticScale || shouldSuppressSingleTap {
                return false
            }

            if isInteractionReady == false {
                return false
            }

            if isSingleTapGesturesReady {
                return true
            }

            if let pdfView = pdfView, pendingSingleTapReadiness == nil {
                scheduleSingleTapReadiness(
                    delay: Timing.singleTapReadinessDelay,
                    generation: documentLoadGeneration,
                    using: pdfView
                )
            }
            return true
        }

        private func shouldDropDuplicateSingleTapEvent(
            at view: PDFView,
            timestamp now: Date,
            location: CGPoint?
        ) -> Bool {
            let currentLocation = location ?? .zero
            guard
                let lastAt = lastSingleTapDeliveryAt,
                now.timeIntervalSince(lastAt) <= Timing.singleTapEventReentryWindow,
                let lastPoint = lastSingleTapDeliveryPoint,
                let lastViewID = lastSingleTapDeliveryViewID
            else {
                return false
            }
            guard ObjectIdentifier(view) == lastViewID else {
                return false
            }
            let dx = currentLocation.x - lastPoint.x
            let dy = currentLocation.y - lastPoint.y
            let distance = (dx * dx + dy * dy).squareRoot()
            return distance <= Timing.singleTapEventDuplicateDistance
        }

        private func recordSingleTapDelivery(
            at view: PDFView,
            timestamp now: Date,
            location: CGPoint?
        ) {
            lastSingleTapDeliveryAt = now
            lastSingleTapDeliveryPoint = location
            lastSingleTapDeliveryViewID = ObjectIdentifier(view)
        }

        private func canHandleLookupPressGesture() -> Bool {
            guard shouldAllowLookupFlow() else { return false }
            if !isLookupGesturesReady {
                ensureLookupPressReadinessIfNeeded()
            }
            return isLookupGesturesReady
        }

        private func ensureLookupPressReadinessIfNeeded() {
            guard longPressEnabled() else { return }
            guard isInteractionReady else { return }
            guard let pdfView else { return }
            guard !isLookupGesturesReady else { return }
            scheduleLookupPressReadiness(
                delay: Timing.longPressReadinessDelay,
                generation: documentLoadGeneration,
                using: pdfView
            )
        }

        private func canHandleLookupLongPressMode() -> Bool {
            guard shouldAllowLookupFlow() else { return false }
            if !isLookupGesturesReady {
                ensureLookupPressReadinessIfNeeded()
            }
            return isLookupGesturesReady
        }

        private func applyGestureMode(using pdfView: PDFView, recollect: Bool) {
            let mode = expectedGestureMode()
            let modeChanged = lastAppliedGestureMode != mode
            lastAppliedGestureMode = mode
            let readingMode = readerMode.wrappedValue == .reading
            let interactionAllowed = readingMode && isInteractionReady
            let shouldUseLongPress = mode == .readingLongPress
            // Single tap only while the gesture runtime permits it.
            let shouldEnableSingleTap = isSingleTapRuntimeEnabled()
            let shouldEnableLookupPress = shouldAllowLookupFlow()
                && shouldUseLongPress
                && longPressEnabled()
                && !isApplyingProgrammaticScale

            let viewID = ObjectIdentifier(pdfView)
            var desiredSingleTapEnabled = false
            var desiredTwoFingerEnabled = false
            var desiredLookupEnabled = false
            switch mode {
            case .readingLongPress:
                desiredSingleTapEnabled = shouldEnableSingleTap
                desiredTwoFingerEnabled = readingMode && interactionAllowed
                desiredLookupEnabled = shouldEnableLookupPress
            case .readingSingleTap:
                desiredSingleTapEnabled = shouldEnableSingleTap
                desiredTwoFingerEnabled = readingMode && interactionAllowed
            case .nonReading:
                desiredTwoFingerEnabled = false
                desiredSingleTapEnabled = false
                desiredLookupEnabled = false
            }

            let desiredState = GestureState(
                mode: mode,
                interactionAllowed: interactionAllowed,
                singleTapEnabled: desiredSingleTapEnabled,
                twoFingerEnabled: desiredTwoFingerEnabled,
                lookupPressEnabled: desiredLookupEnabled,
                pinchEnabled: interactionAllowed,
                navigationEnabled: interactionAllowed,
                systemLongPressEnabled: interactionAllowed && readingMode && !shouldUseLongPress
            )

            let shouldRefreshForViewChange = lastAppliedGestureViewID != viewID
            let shouldRecollectSystemPresses = recollect
                || shouldRefreshForViewChange
                || modeChanged
                || systemLongPresses.isEmpty
            let recognizerStateDrift = (
                (singleTap?.isEnabled != desiredSingleTapEnabled)
                || (twoFingerTap?.isEnabled != desiredTwoFingerEnabled)
                || (lookupPress?.isEnabled != desiredLookupEnabled)
            )
            if !recollect,
               let lastState = lastAppliedGestureState,
               let lastViewID = lastAppliedGestureViewID,
               lastViewID == viewID,
               lastState == desiredState,
               !recognizerStateDrift {
                return
            }

            lastAppliedGestureState = desiredState
            lastAppliedGestureViewID = viewID
            pinchSnap?.isEnabled = interactionAllowed
            (pdfView as? ReadTapPDFView)?.setNavigationEnabled(interactionAllowed)
            (pdfView as? ReadTapPDFView)?.setLookupSelectionEnabled(!(readingMode && shouldUseLongPress))

            @inline(__always)
            func setIfChanged(_ recognizer: UIGestureRecognizer?, _ enabled: Bool) {
                guard recognizer?.isEnabled != enabled else { return }
                recognizer?.isEnabled = enabled
            }
            @inline(__always)
            func setIfChangedLongPressCancels(_ enabled: Bool) {
                guard let lookupPress, lookupPress.cancelsTouchesInView != enabled else { return }
                lookupPress.cancelsTouchesInView = enabled
            }

            let shouldEnableSystemLongPress = interactionAllowed && readingMode && !shouldUseLongPress
            setSystemLongPresses(enabled: shouldEnableSystemLongPress, in: pdfView, recollect: shouldRecollectSystemPresses)
            setIfChangedLongPressCancels(false)

            setIfChanged(singleTap, desiredSingleTapEnabled)
            setIfChanged(twoFingerTap, desiredTwoFingerEnabled)
            setIfChanged(lookupPress, desiredLookupEnabled)
            #if DEBUG
            if lookupPress?.isEnabled != desiredLookupEnabled {
                if shouldEmitDebug(tag: "applyGestureMode", signature: "\(lookupPress?.isEnabled ?? false)->\(desiredLookupEnabled)|\(mode)|\(interactionAllowed)|\(shouldEnableLookupPress)|\(gestureRuntimePhase)") {
                    print("[LongPressDebug] applyGestureMode lookupPress.isEnabled=\(lookupPress?.isEnabled ?? false) desired=\(desiredLookupEnabled) mode=\(mode) interactionAllowed=\(interactionAllowed) shouldAllowLookup=\(shouldEnableLookupPress) runtimePhase=\(gestureRuntimePhase)")
                }
            }
            #endif
            guard interactionAllowed else {
                if isLookupActive {
                    resetLookupPressState(force: true)
                }
                return
            }

            switch mode {
            case .readingLongPress:
                break
            case .readingSingleTap:
                if isLookupActive {
                    resetLookupPressState(force: true)
                }
            case .nonReading:
                if isLookupActive {
                    resetLookupPressState(force: true)
                }
            }
        }

        private func setSystemLongPresses(enabled: Bool, in pdfView: PDFView, recollect: Bool) {
            let shouldRefreshSystemLongPresses = recollect
                || !didCollectSystemLongPressesForCurrentView
                || !enabled
                || systemLongPresses.isEmpty
            refreshSystemLongPresses(in: pdfView, force: shouldRefreshSystemLongPresses)
            guard !systemLongPresses.isEmpty else { return }
            systemLongPresses.forEach { recognizer in
                if recognizer.isEnabled != enabled {
                    recognizer.isEnabled = enabled
                }
            }
        }

        private func refreshSystemLongPresses(in pdfView: PDFView, force: Bool = false) {
            if !force && didCollectSystemLongPressesForCurrentView {
                return
            }
            if !force {
                let now = Date()
                if now.timeIntervalSince(lastSystemLongPressScanAt) < 0.08 {
                    return
                }
            }
            let collectionViewID = ObjectIdentifier(pdfView)
            if !force,
               let scannedViewID = systemLongPressCollectionViewID,
               scannedViewID == collectionViewID,
               systemLongPressCollectionGeneration == documentLoadGeneration,
               didCollectSystemLongPressesForCurrentView {
                return
            }
            lastSystemLongPressScanAt = Date()
            var presses = collectLongPressRecognizers(in: pdfView, maxDepth: Gesture.longPressFastScanDepth)
                .filter { $0 !== lookupPress }

            if presses.isEmpty {
                presses = collectLongPressRecognizers(in: pdfView, maxDepth: Gesture.longPressAreaScanDepth)
                    .filter { $0 !== lookupPress }
            }
            systemLongPresses = presses
            systemLongPressCollectionViewID = collectionViewID
            systemLongPressCollectionGeneration = documentLoadGeneration
            didCollectSystemLongPressesForCurrentView = true
        }

        private func queueProgrammaticPageTurn(_ direction: PendingPageTurn.Direction, preserving ratio: CGFloat, for pdfView: PDFView) {
            pendingProgrammaticPageTurnTimeout?.cancel()
            let token = UUID()
            pendingProgrammaticPageTurn = PendingPageTurn(token: token, intendedZoomRatio: ratio, direction: direction)

            let timeout = DispatchWorkItem { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                guard let pending = self.pendingProgrammaticPageTurn, pending.token == token else { return }

                if let doc = pdfView.document, let current = pdfView.currentPage {
                    let index = doc.index(for: current)
                    let targetIndex: Int
                    switch pending.direction {
                    case .next:
                        targetIndex = min(doc.pageCount - 1, index + 1)
                    case .previous:
                        targetIndex = max(0, index - 1)
                    }
                    if targetIndex != index, let target = doc.page(at: targetIndex) {
                        pdfView.go(to: target)
                        return
                    }
                }

                self.pendingProgrammaticPageTurn = nil
                self.isHandlingPageChange = false
            }
            pendingProgrammaticPageTurnTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.programmaticPageTurnTimeout, execute: timeout)
        }

        private func suppressSingleTapTemporarily(_ delay: TimeInterval? = nil) {
            let delay = delay ?? Timing.singleTapReenableDebounce
            let until = Date().addingTimeInterval(delay)
            suppressSingleTapUntil = until
            singleTapReenableWorkItem?.cancel()

            let task = Task { [weak self] in
                let nanos = UInt64(delay * 1_000_000_000)
                if nanos > 0 {
                    do { try await Task.sleep(nanoseconds: nanos) } catch {
                        return
                    }
                }
                guard let self else { return }
                guard !Task.isCancelled else { return }
                guard self.suppressSingleTapUntil == until else { return }
                self.suppressSingleTapUntil = nil
                if let pdfView = self.pdfView {
                    self.applyGestureMode(using: pdfView, recollect: false)
                }
                self.singleTapReenableWorkItem = nil
            }
            singleTapReenableWorkItem = task
        }

        private func suppressSingleTap(for duration: TimeInterval) {
            suppressSingleTapUntil = Date().addingTimeInterval(duration)
        }

        private var shouldSuppressSingleTap: Bool {
            guard let until = suppressSingleTapUntil else { return false }
            return Date() < until
        }

        private func collectLongPressRecognizers(in view: UIView, maxDepth: Int) -> [UILongPressGestureRecognizer] {
            var result: [UILongPressGestureRecognizer] = []
            var stack: [(UIView, Int)] = [(view, 0)]
            result.reserveCapacity(12)
            stack.reserveCapacity(32)
            while let (current, depth) = stack.popLast() {
                if let gestures = current.gestureRecognizers, !gestures.isEmpty {
                    for gesture in gestures {
                        guard
                            let longPress = gesture as? UILongPressGestureRecognizer,
                            longPress !== lookupPress
                        else { continue }
                        result.append(longPress)
                    }
                }
                guard depth < maxDepth else { continue }
                if !current.subviews.isEmpty {
                    for index in stride(from: current.subviews.count - 1, through: 0, by: -1) {
                        stack.append((current.subviews[index], depth + 1))
                    }
                }
            }
            return result
        }

        private func clearSelectionIfNeeded(on pdfView: PDFView) {
            guard pdfView.currentSelection != nil else { return }
            guard !isProgrammaticSelectionClear else { return }

            isProgrammaticSelectionClear = true
            pdfView.clearSelection()
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticSelectionClear = false
            }
        }

        private func longPressEnabled() -> Bool {
            return hostLongPressEnabled
        }

        private func isSingleTapEnabled() -> Bool {
            return readerMode.wrappedValue == .reading
                && isInteractionReady
                && isSingleTapGesturesReady
                && !shouldSuppressSingleTap
        }

        private func clearSingleTapSuppression() {
            suppressSingleTapUntil = nil
            singleTapReenableWorkItem?.cancel()
            singleTapReenableWorkItem = nil
        }

        private func autoSaveEnabled() -> Bool {
            UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true
        }

        #if DEBUG
        private let isReaderDebugLoggingEnabled = false

        private func shouldEmitDebug(tag: String, signature: String, throttle: TimeInterval? = nil) -> Bool {
            guard isReaderDebugLoggingEnabled else { return false }
            guard UserDefaults.standard.object(forKey: "ReaderDebugLoggingEnabled") as? Bool == true else {
                return false
            }
            let now = Date()
            let minimumInterval = throttle ?? debugGestureLogThrottle
            if let lastSignature = lastDebugLogSignatureByTag[tag],
               let lastAt = lastDebugLogAtByTag[tag],
               lastSignature == signature,
               now.timeIntervalSince(lastAt) < minimumInterval {
                return false
            }
            lastDebugLogSignatureByTag[tag] = signature
            lastDebugLogAtByTag[tag] = now
            return true
        }

        private func debugLongPressState(_ tag: String) {
            let coordPtr = Unmanaged.passUnretained(self).toOpaque()
            let store = BookDrawingStore.shared
            let singleTapState = singleTap?.isEnabled ?? false
            let lookupPressState = lookupPress?.isEnabled ?? false
            print(
                "[ReaderGesture][\(tag)] "
                + "coord=\(coordPtr) "
                + "lookupEnabled=\(longPressEnabled()) "
                + "singleTap=\(singleTapState) "
                + "lookupPress=\(lookupPressState) "
                + "storeId=\(ObjectIdentifier(store))"
            )
        }

        private func debugSingleTapState(_ tag: String) {
            let coordPtr = Unmanaged.passUnretained(self).toOpaque()
            let store = BookDrawingStore.shared
            let autoSave = UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true
            print(
                "[ReaderGesture][\(tag)] "
                + "coord=\(coordPtr) "
                + "mode=\(readerMode.wrappedValue) "
                + "autoSave=\(autoSave) "
                + "storeId=\(ObjectIdentifier(store))"
            )
        }
        #endif

        private func currentZoomRatio(from pdfView: PDFView) -> CGFloat {
            let fit = cachedFitScale > 0 ? cachedFitScale : pdfView.scaleFactorForSizeToFit
            guard fit > 0 else { return zoomRatio.wrappedValue }
            cachedFitScale = fit
            return normalizedZoomRatio(clampedZoomRatio(pdfView.scaleFactor / fit))
        }

        private func syncZoomRatioFromView(_ pdfView: PDFView) {
            let liveRatio = currentZoomRatio(from: pdfView)
            if liveRatio > 0 {
                lastObservedZoomRatio = liveRatio
            }
            guard abs(zoomRatio.wrappedValue - liveRatio) > Threshold.small else { return }
            queueBindingValue(zoomRatio, to: liveRatio)
        }

        private func quantizedSize(_ size: CGSize) -> CGSize {
            CGSize(width: round(size.width * 2) / 2, height: round(size.height * 2) / 2)
        }

        private func resolvedZoomRatio(using pdfView: PDFView, fallback: CGFloat) -> CGFloat {
            if let observed = lastObservedZoomRatio, observed > 0 {
                return normalizedZoomRatio(observed)
            }
            let liveRatio = currentZoomRatio(from: pdfView)
            if liveRatio > 0 {
                return normalizedZoomRatio(liveRatio)
            }
            return normalizedZoomRatio(fallback)
        }
    }
}
