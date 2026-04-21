//
//  AdaptivePresentation.swift
//  readtap
//
//  Device-adaptive modal presentation helpers.
//

import SwiftUI

extension View {
    /// Subscription-sheet presentation that adapts to device. Used for both the
    /// full paywall (`PaywallView`) and the trial-offer promo (`PremiumComparisonPromoSheet`):
    /// - iPhone: bottom sheet (`.sheet`) — the content's own `.presentationDetents([.large])`
    ///   gives it near-full height.
    /// - iPad: full-screen cover (`.fullScreenCover`).
    ///
    /// Why split by device: on iPad, plain `.sheet` becomes a *form sheet* (centered,
    /// fixed ~540×620pt size) which causes two App Store Review problems:
    ///
    /// 1. **Guideline 3.1.2(c)** — the Subscription Details block and the payment
    ///    auto-renewal disclaimer get clipped below the form-sheet fold, so the
    ///    required disclosures are not "clear and conspicuous". The trial promo
    ///    also overflows (~790pt of content vs 620pt sheet) which obscures the
    ///    "No charge after free trial" disclosure and the trial CTA.
    /// 2. **Guideline 2.1(b)** — `Product.purchase()` invoked from inside a form
    ///    sheet on iPadOS 26 can silently fail to present StoreKit's purchase
    ///    sheet because the form sheet sits on top of the key-window scene
    ///    context that StoreKit needs to present onto. The reviewer sees nothing
    ///    happen after tapping "Subscribe" (this is what got us rejected).
    ///
    /// Full-screen cover on iPad resolves both: every required disclosure has
    /// room to render, and the sheet *is* the top-level presentation, so
    /// StoreKit's purchase sheet has an unambiguous scene to present over.
    /// The presented view is responsible for providing its own dismiss affordance
    /// (close button) since fullScreenCover has no drag-to-dismiss.
    @ViewBuilder
    func adaptivePaywallSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if DSLayout.isPad {
            self.fullScreenCover(isPresented: isPresented, content: content)
        } else {
            self.sheet(isPresented: isPresented, content: content)
        }
    }
}
