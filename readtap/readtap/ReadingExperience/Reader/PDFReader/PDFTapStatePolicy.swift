import Foundation

struct PDFTapSingleTapDecision: Equatable {
    let shouldResetLookupArtifacts: Bool
    let shouldClearSelection: Bool
    let shouldEmitHaptic: Bool
    let shouldInvokeSingleTap: Bool
    let shouldDropEvent: Bool
    let reason: String
}

enum PDFTapSingleTapPolicy {
    static func decide(
        readerMode: ReaderInteractionMode,
        shouldDismissLookupArtifactsOnNextTap: Bool,
        isInteractionReady: Bool,
        isLookupActive: Bool,
        didLookupForCurrentLongPress: Bool,
        canHandleSingleTapGesture: Bool,
        now: Date,
        lastSingleTapAt: Date?,
        lastLookupPressAt: Date?,
        lastTwoFingerTapAt: Date?,
        singleTapDebounceInterval: TimeInterval,
        longPressToSingleTapCooldown: TimeInterval,
        twoFingerTapDebounceInterval: TimeInterval
    ) -> PDFTapSingleTapDecision {
        if readerMode != .reading {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: false,
                shouldClearSelection: false,
                shouldEmitHaptic: false,
                shouldInvokeSingleTap: false,
                shouldDropEvent: true,
                reason: "not_reading"
            )
        }

        if shouldDismissLookupArtifactsOnNextTap {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: true,
                shouldClearSelection: false,
                shouldEmitHaptic: false,
                shouldInvokeSingleTap: true,
                shouldDropEvent: false,
                reason: "dismiss_lookup_artifacts"
            )
        }

        if !isInteractionReady {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: false,
                shouldClearSelection: false,
                shouldEmitHaptic: true,
                shouldInvokeSingleTap: true,
                shouldDropEvent: false,
                reason: "interaction_not_ready_bootstrap"
            )
        }

        if !isLookupActive && !canHandleSingleTapGesture {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: false,
                shouldClearSelection: false,
                shouldEmitHaptic: false,
                shouldInvokeSingleTap: false,
                shouldDropEvent: true,
                reason: "single_tap_not_ready"
            )
        }

        if isLookupActive || didLookupForCurrentLongPress {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: true,
                shouldClearSelection: false,
                shouldEmitHaptic: false,
                shouldInvokeSingleTap: true,
                shouldDropEvent: false,
                reason: "active_lookup_clear"
            )
        }

        if let last = lastSingleTapAt, now.timeIntervalSince(last) < singleTapDebounceInterval {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: false,
                shouldClearSelection: false,
                shouldEmitHaptic: false,
                shouldInvokeSingleTap: false,
                shouldDropEvent: true,
                reason: "single_tap_debounce"
            )
        }

        if let last = lastLookupPressAt, now.timeIntervalSince(last) < longPressToSingleTapCooldown {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: false,
                shouldClearSelection: false,
                shouldEmitHaptic: false,
                shouldInvokeSingleTap: false,
                shouldDropEvent: true,
                reason: "lookup_to_single_tap_cooldown"
            )
        }

        if let last = lastTwoFingerTapAt, now.timeIntervalSince(last) < twoFingerTapDebounceInterval {
            return PDFTapSingleTapDecision(
                shouldResetLookupArtifacts: false,
                shouldClearSelection: false,
                shouldEmitHaptic: false,
                shouldInvokeSingleTap: false,
                shouldDropEvent: true,
                reason: "two_finger_tap_debounce"
            )
        }

        return PDFTapSingleTapDecision(
            shouldResetLookupArtifacts: false,
            shouldClearSelection: true,
            shouldEmitHaptic: true,
            shouldInvokeSingleTap: true,
            shouldDropEvent: false,
            reason: "normal_single_tap"
        )
    }
}
