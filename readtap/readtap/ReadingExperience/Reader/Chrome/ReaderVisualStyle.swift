import SwiftUI
import UIKit

enum ReaderVisualStyleMode: String, CaseIterable {
    case classic
    case refined

    nonisolated static let storageKey = "readerVisualStyleMode"
    nonisolated static let defaultMode: ReaderVisualStyleMode = .refined

    nonisolated static func resolved(from rawValue: String?) -> ReaderVisualStyleMode {
        guard let rawValue, let mode = ReaderVisualStyleMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    nonisolated static var current: ReaderVisualStyleMode {
        resolved(from: UserDefaults.standard.string(forKey: storageKey))
    }

    nonisolated var isRefined: Bool {
        self == .refined
    }
}

enum ReaderRefinedPalette {
    private nonisolated static var isOcean: Bool { LibraryTheme.active == .ocean }

    nonisolated static var ink: Color { isOcean ? Color(red: 0.132, green: 0.192, blue: 0.278) : Color(red: 0.122, green: 0.153, blue: 0.200) }
    nonisolated static var inkMuted: Color { isOcean ? Color(red: 0.431, green: 0.510, blue: 0.592) : Color(red: 0.416, green: 0.455, blue: 0.510) }
    nonisolated static var accent: Color { isOcean ? Color(red: 0.400, green: 0.659, blue: 0.871) : Color(red: 0.122, green: 0.678, blue: 0.380) }
    nonisolated static var accentStrong: Color { isOcean ? Color(red: 0.271, green: 0.502, blue: 0.722) : Color(red: 0.090, green: 0.518, blue: 0.286) }
    nonisolated static var accentSoft: Color { accent.opacity(isOcean ? 0.14 : 0.11) }
    nonisolated static var mint: Color { isOcean ? Color(red: 0.514, green: 0.847, blue: 0.863) : Color(red: 0.341, green: 0.827, blue: 0.709) }
    nonisolated static var mintSoft: Color { mint.opacity(isOcean ? 0.20 : 0.18) }
    nonisolated static var pageBackground: Color { isOcean ? Color(red: 0.970, green: 0.983, blue: 0.990) : Color(red: 0.978, green: 0.986, blue: 0.988) }
    nonisolated static var canvasBackground: Color { isOcean ? Color(red: 0.914, green: 0.944, blue: 0.961) : Color(red: 0.929, green: 0.947, blue: 0.952) }
    nonisolated static var pageSurface: Color { isOcean ? Color(red: 0.991, green: 0.996, blue: 0.999) : Color(red: 0.992, green: 0.996, blue: 0.997) }
    nonisolated static var panelSurface: Color { Color.white.opacity(isOcean ? 0.92 : 0.88) }
    nonisolated static var panelSurfaceStrong: Color { Color.white.opacity(isOcean ? 0.97 : 0.95) }
    nonisolated static var warmSurface: Color { isOcean ? Color(red: 0.939, green: 0.973, blue: 0.980) : Color(red: 0.958, green: 0.980, blue: 0.970) }
    nonisolated static var subtleStroke: Color { Color.black.opacity(isOcean ? 0.09 : 0.08) }
    nonisolated static var strongerStroke: Color { Color.black.opacity(isOcean ? 0.14 : 0.12) }
    nonisolated static var shadow: Color { isOcean ? Color(red: 0.169, green: 0.271, blue: 0.365).opacity(0.14) : Color.black.opacity(0.09) }
    nonisolated static var overlayDim: Color { Color.black.opacity(isOcean ? 0.10 : 0.12) }
    nonisolated static var selectionFill: Color { accent.opacity(isOcean ? 0.20 : 0.18) }
    nonisolated static var selectionStroke: Color { accent.opacity(isOcean ? 0.56 : 0.52) }
    nonisolated static var selectionHandle: Color { accent }
    nonisolated static var actionSecondary: Color { Color.white.opacity(isOcean ? 0.95 : 0.92) }

    nonisolated static var lookupHighlightFill: UIColor {
        isOcean
            ? UIColor(red: 120 / 255, green: 208 / 255, blue: 216 / 255, alpha: 0.24)
            : UIColor(red: 87 / 255, green: 211 / 255, blue: 181 / 255, alpha: 0.24)
    }
    nonisolated static var lookupHighlightStroke: UIColor {
        isOcean
            ? UIColor(red: 102 / 255, green: 168 / 255, blue: 221 / 255, alpha: 0.45)
            : UIColor(red: 31 / 255, green: 169 / 255, blue: 100 / 255, alpha: 0.45)
    }
    nonisolated static var savedHighlightColor: Color {
        isOcean
            ? Color(red: 120 / 255, green: 208 / 255, blue: 216 / 255)
            : Color(red: 87 / 255, green: 211 / 255, blue: 181 / 255)
    }
    nonisolated static var savedHighlight: UIColor {
        isOcean
            ? UIColor(red: 120 / 255, green: 208 / 255, blue: 216 / 255, alpha: 0.34)
            : UIColor(red: 87 / 255, green: 211 / 255, blue: 181 / 255, alpha: 0.34)
    }
    nonisolated static var markupHighlight: UIColor {
        isOcean
            ? UIColor(red: 102 / 255, green: 168 / 255, blue: 221 / 255, alpha: 0.26)
            : UIColor(red: 31 / 255, green: 169 / 255, blue: 100 / 255, alpha: 0.26)
    }
    nonisolated static var canvasUIColor: UIColor {
        isOcean
            ? UIColor(red: 0.914, green: 0.944, blue: 0.961, alpha: 1)
            : UIColor(red: 0.929, green: 0.947, blue: 0.952, alpha: 1)
    }
    nonisolated static var pageCanvasUIColor: UIColor {
        isOcean
            ? UIColor(red: 0.958, green: 0.979, blue: 0.989, alpha: 1)
            : UIColor(red: 0.963, green: 0.975, blue: 0.978, alpha: 1)
    }
}
