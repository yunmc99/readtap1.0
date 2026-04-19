import Foundation

struct ReaderChromeToggleResult: Equatable {
    let nextChromeVisible: Bool
    let shouldCloseManualEntry: Bool
    let shouldCloseAdjustingBox: Bool
    let shouldCloseThumbnailPanel: Bool
    let shouldDropForFailedLoad: Bool
    let reason: String
}

enum ReaderChromeStateMachine {
    static func resolveSingleTapChrome(
        hasPopup: Bool,
        isManualEntryPresented: Bool,
        isAdjustingBox: Bool,
        isThumbnailPanelVisible: Bool,
        pdfLoadFailed: Bool,
        currentChromeVisible: Bool,
        force: Bool
    ) -> ReaderChromeToggleResult {
        if pdfLoadFailed && !force {
            return ReaderChromeToggleResult(
                nextChromeVisible: currentChromeVisible,
                shouldCloseManualEntry: false,
                shouldCloseAdjustingBox: false,
                shouldCloseThumbnailPanel: false,
                shouldDropForFailedLoad: true,
                reason: "pdf_load_failed"
            )
        }

        // When any overlay is being force-closed (popup, panel, manual entry, etc.),
        // restore chrome visibility so the user can interact with the bars immediately.
        let nextChromeVisible = force ? true : !currentChromeVisible

        return ReaderChromeToggleResult(
            nextChromeVisible: nextChromeVisible,
            shouldCloseManualEntry: isManualEntryPresented,
            shouldCloseAdjustingBox: isAdjustingBox,
            shouldCloseThumbnailPanel: isThumbnailPanelVisible,
            shouldDropForFailedLoad: false,
            reason: hasPopup ? "popup_then_toggle" : "toggle"
        )
    }
}
