//
//  ReaderLookupConfig.swift
//  readtap
//
//  Created by Codex.
//

import Foundation
import CoreGraphics

enum ReaderLookupLimits {
    static let maxPopupWordCount = 8
    static let maxPopupContextWordCount = 40
    static let maxPopupCharacterCount = 300
    static let maxPopupLineWordCount = 10
    static let maxAdjustRectWordCount = 4
    static let maxAdjustRectWordCountPremium = 6
    static let maxSelectionCandidateCount = 140
    static let longPressDuplicateDebounceInterval: TimeInterval = 0.22
    static let selectionChangeDebounceInterval: TimeInterval = 0.14
    static let longPressFirstTouchMinimumPressDuration: TimeInterval = 0.15
    static let longPressMinimumPressDuration: TimeInterval = 0.20
    static let longPressRecoverySeconds: TimeInterval = 1.0
    static let longPressAllowableMovement: CGFloat = 12
    static let lookupHitDistanceMin: CGFloat = 4
    static let lookupHitDistanceScale: CGFloat = 0.6
    static let lookupHitDistanceMax: CGFloat = 24
    static let pickWordMaxDistance: CGFloat = 14

    static func lookupHitDistanceThreshold(for rect: CGRect) -> CGFloat {
        let minSide = min(rect.width, rect.height)
        if minSide <= 0 { return lookupHitDistanceMin }
        return max(lookupHitDistanceMin, min(minSide * lookupHitDistanceScale, lookupHitDistanceMax))
    }

    static func adaptiveSelectionCandidateLimit(for availableWords: Int) -> Int {
        switch availableWords {
        case ...140:
            return maxSelectionCandidateCount
        case 141...260:
            return 100
        case 261...420:
            return 90
        default:
            return 80
        }
    }
}

enum ReaderAdjustLimits {
    static let contextWordLimitForAdjustedLookup = ReaderLookupLimits.maxPopupContextWordCount
    static let fallbackContextWordLimit = 10
}

enum ReaderLoadingUX {
    static let quickHintInterval: TimeInterval = 1.0
    static let gentleHintInterval: TimeInterval = 2.5
    static let delayHintInterval: TimeInterval = 6.0
    static let retryHintInterval: TimeInterval = 12.0
    static let loadingRetryLabelCooldown: TimeInterval = 0.3
    static let minimumLoadingVisibleDuration: TimeInterval = 0.35
    static let loadingOverlayShowDelay: TimeInterval = 0.08
    static let loadingTickerInterval: TimeInterval = 1.0
    static let loadingFallbackTimeout: TimeInterval = 10.0
}
