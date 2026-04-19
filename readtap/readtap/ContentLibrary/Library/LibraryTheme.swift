import SwiftUI
import UIKit

enum LibraryTheme: String, CaseIterable, Identifiable {
    case studio
    case ocean
    case paper
    case dusk
    case mint

    var id: String { rawValue }

    /// Free users see studio + ocean; premium users see all five themes.
    nonisolated static var allCases: [LibraryTheme] {
        let isPremium = MainActor.assumeIsolated { SubscriptionManager.shared.isEffectivelyPremium }
        return isPremium
            ? [.studio, .ocean, .paper, .mint]
            : [.studio, .ocean]
    }

    /// All themes including premium-locked ones, for displaying with lock icons.
    nonisolated static var allThemes: [LibraryTheme] {
        [.studio, .ocean, .paper, .mint]
    }

    /// Themes available only to premium subscribers.
    nonisolated static var premiumThemes: Set<LibraryTheme> {
        [.paper, .mint]
    }

    nonisolated static var `default`: LibraryTheme { .studio }
    nonisolated static var active: LibraryTheme {
        current(from: UserDefaults.standard.string(forKey: "libraryTheme"))
    }

    nonisolated static func current(from raw: String?) -> LibraryTheme {
        guard let raw, let resolved = LibraryTheme(rawValue: raw) else {
            return .default
        }
        // Dusk theme has been retired — fall back to default.
        if resolved == .dusk { return .default }
        let isPremium = MainActor.assumeIsolated { SubscriptionManager.shared.isEffectivelyPremium }
        if Self.premiumThemes.contains(resolved) && !isPremium {
            return .default
        }
        return resolved
    }

    var title: String {
        switch self {
        case .studio: return AppText.t(.themeStudio)
        case .ocean: return AppText.t(.themeOcean)
        case .paper: return AppText.t(.themePaper)
        case .dusk: return AppText.t(.themeDusk)
        case .mint: return AppText.t(.themeMint)
        }
    }

    // MARK: - Glass Properties

    var glassTint: Color {
        switch self {
        case .studio: return Color(uiColor: .secondaryLabel).opacity(0.16)
        case .ocean: return Color(red: 0.451, green: 0.733, blue: 0.902).opacity(0.16)
        case .paper: return Color(red: 0.706, green: 0.424, blue: 0.282).opacity(0.12)
        case .dusk: return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.14)
        case .mint: return Color(red: 0.239, green: 0.420, blue: 0.337).opacity(0.08)
        }
    }

    var cardSurface: Color {
        Color(UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            switch self {
            case .studio:
                return dark
                    ? UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)
                    : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
            case .ocean:
                return dark
                    ? UIColor(red: 0.15, green: 0.20, blue: 0.26, alpha: 1)
                    : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
            case .paper:
                return dark
                    ? UIColor(red: 0.160, green: 0.130, blue: 0.100, alpha: 1)
                    : UIColor(red: 1.0, green: 0.995, blue: 0.985, alpha: 1)
            case .dusk:
                return dark
                    ? UIColor(red: 0.090, green: 0.075, blue: 0.160, alpha: 1)
                    : UIColor(red: 0.157, green: 0.125, blue: 0.251, alpha: 1)
            case .mint:
                return dark
                    ? UIColor(red: 0.065, green: 0.078, blue: 0.071, alpha: 1)
                    : UIColor(red: 1.0, green: 1.0, blue: 0.997, alpha: 1)
            }
        })
    }

    var cardStroke: Color {
        switch self {
        case .ocean:
            return Color(red: 0.169, green: 0.271, blue: 0.365).opacity(0.22)
        case .paper:
            return Color(red: 0.561, green: 0.345, blue: 0.200).opacity(0.20)
        case .dusk:
            return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.25)
        case .mint:
            return Color(red: 0.176, green: 0.314, blue: 0.255).opacity(0.18)
        default:
            return Color(uiColor: .separator).opacity(0.35)
        }
    }

    var mutedText: Color {
        switch self {
        case .ocean:
            return Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.69, green: 0.77, blue: 0.86, alpha: 1)
                    : UIColor(red: 0.43, green: 0.51, blue: 0.60, alpha: 1)
            })
        case .paper:
            return Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.690, green: 0.565, blue: 0.455, alpha: 1)
                    : UIColor(red: 0.608, green: 0.478, blue: 0.361, alpha: 1)
            })
        case .dusk:
            return Color(red: 0.627, green: 0.565, blue: 0.816)
        case .mint:
            return Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.480, green: 0.540, blue: 0.510, alpha: 1)
                    : UIColor(red: 0.380, green: 0.440, blue: 0.408, alpha: 1)
            })
        default:
            return Color(uiColor: .secondaryLabel)
        }
    }

    var shelfSurface: Color {
        cardSurface
    }

    // MARK: - Background (adaptive light/dark)

    var background: AnyView {
        AnyView(AdaptiveThemeBackground(theme: self))
    }

    // MARK: - Legacy Properties (kept for compatibility, glass replaces these)

    var titleColor: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 235.0 / 255.0, green: 240.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 26.0 / 255.0, green: 37.0 / 255.0, blue: 52.0 / 255.0, alpha: 1)
        })
    }

    var subtitleColor: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 178.0 / 255.0, green: 188.0 / 255.0, blue: 204.0 / 255.0, alpha: 1)
            }
            return UIColor(red: 101.0 / 255.0, green: 115.0 / 255.0, blue: 131.0 / 255.0, alpha: 1)
        })
    }
}

struct CalendarPalette {
  let text: Color
  let muted: Color
  let offMonth: Color
  let accent: Color
  let highlight: Color
  let highlightStroke: Color
  let started: Color
  let finished: Color
  let goalBadge: Color
  let goalBadgeSymbol: Color
  let goalBadgePage: Color
  let startedBadgeFill: Color
  let startedBadgeSymbol: Color
  let startedBadgePage: Color
  let finishedBadgeFill: Color
  let finishedBadgeSymbol: Color
  let finishedBadgePage: Color
  let badgeStroke: Color
  let badgeShadow: Color
  let goalText: Color
  let icon: Color
  let todayRing: Color
  let danger: Color
  let dangerText: Color
  let dangerBackground: Color
  let badgeForeground: Color
}

extension CalendarPalette {
    var primary: Color {
        accent
    }
}

extension LibraryTheme {
  func calendarPalette(for colorScheme: ColorScheme) -> CalendarPalette {
    func makeBadgeStyle(for base: Color) -> (fill: Color, symbol: Color, page: Color, stroke: Color, shadow: Color) {
      // Create clean, vibrant badges directly from the base color
      // rather than shifting its hue/saturation unnecessarily.
      return (
        fill: base,
        symbol: .white,
        page: base.opacity(0.65),
        stroke: base.opacity(0.85),
        shadow: base.opacity(0.35)
      )
    }

    let text: Color
    let muted: Color
    let offMonth: Color
    let accent: Color
    let highlight: Color
    let highlightStroke: Color
    let started: Color
    let finished: Color
    let icon: Color
    let todayRing: Color

    if colorScheme == .dark {
      text = .white.opacity(0.98)
      muted = Color.white.opacity(0.55)
      offMonth = Color.white.opacity(0.20)
      todayRing = .white.opacity(0.85)

      switch self {
      case .studio:
        // Match ReadTap Green brand for the main theme
        accent = Color(red: 0.25, green: 0.82, blue: 0.50)
        // High visibility, warm Amber for Started
        started = Color(red: 0.98, green: 0.68, blue: 0.22)
      case .ocean:
        accent = Color(red: 0.47, green: 0.76, blue: 0.94)
        started = Color(red: 0.98, green: 0.74, blue: 0.48)
      case .paper:
        accent = Color(red: 0.800, green: 0.520, blue: 0.380)
        started = Color(red: 0.860, green: 0.650, blue: 0.510)
      case .dusk:
        accent = Color(red: 0.706, green: 0.604, blue: 1.000)
        started = Color(red: 0.910, green: 0.478, blue: 0.627)
      case .mint:
        accent = Color(red: 0.380, green: 0.580, blue: 0.490)
        started = Color(red: 0.520, green: 0.650, blue: 0.580)
      }
      icon = accent
      highlight = accent.opacity(0.22)
      highlightStroke = accent.opacity(0.45)
      // Use the brand color for 'Finished' instead of an arbitrary mint
      finished = accent
    } else {
      text = Color(red: 0.12, green: 0.14, blue: 0.20)
      muted = Color(red: 0.42, green: 0.46, blue: 0.52)
      offMonth = Color(red: 0.45, green: 0.52, blue: 0.63).opacity(0.25)
      
      switch self {
      case .studio:
        // Match ReadTap Green brand for the main theme
        accent = Color(red: 0.12, green: 0.68, blue: 0.38)
        // High visibility, warm Deep Orange for Started
        started = Color(red: 0.92, green: 0.52, blue: 0.12)
      case .ocean:
        accent = Color(red: 0.40, green: 0.66, blue: 0.87)
        started = Color(red: 0.93, green: 0.67, blue: 0.38)
      case .paper:
        accent = Color(red: 0.706, green: 0.424, blue: 0.282)
        started = Color(red: 0.769, green: 0.565, blue: 0.439)
      case .dusk:
        accent = Color(red: 0.549, green: 0.392, blue: 1.000)
        started = Color(red: 0.910, green: 0.478, blue: 0.627)
      case .mint:
        accent = Color(red: 0.239, green: 0.420, blue: 0.337)
        started = Color(red: 0.420, green: 0.561, blue: 0.494)
      }
      icon = accent
      highlight = accent.opacity(0.12)
      highlightStroke = accent.opacity(0.24)
      // Use the brand color for 'Finished' instead of an arbitrary mint
      finished = accent
      todayRing = accent.opacity(0.35)
    }

    let startedBadge = makeBadgeStyle(for: started)
    let finishedBadge = makeBadgeStyle(for: finished)
    let goalStyle = makeBadgeStyle(for: accent)

    return CalendarPalette(
      text: text,
      muted: muted,
      offMonth: offMonth,
      accent: accent,
      highlight: highlight,
      highlightStroke: highlightStroke,
      started: started,
      finished: finished,
      goalBadge: goalStyle.fill.opacity(colorScheme == .dark ? 0.30 : 0.26),
      goalBadgeSymbol: goalStyle.symbol,
      goalBadgePage: goalStyle.page,
      startedBadgeFill: startedBadge.fill,
      startedBadgeSymbol: startedBadge.symbol,
      startedBadgePage: startedBadge.page,
      finishedBadgeFill: finishedBadge.fill,
      finishedBadgeSymbol: finishedBadge.symbol,
      finishedBadgePage: finishedBadge.page,
      badgeStroke: startedBadge.stroke,
      badgeShadow: startedBadge.shadow,
      goalText: text,
      icon: icon,
      todayRing: todayRing,
      danger: Color(red: 0.94, green: 0.20, blue: 0.20),
      dangerText: Color(red: 1.0, green: 1.0, blue: 1.0),
      dangerBackground: Color(red: 0.98, green: 0.94, blue: 0.94),
      badgeForeground: startedBadge.symbol
    )
  }
}

// MARK: - Adaptive Background View

private struct AdaptiveThemeBackground: View {
    let theme: LibraryTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: gradientColors,
            startPoint: startPoint,
            endPoint: endPoint
        )
    }

    private var startPoint: UnitPoint {
        switch theme {
        case .paper: return .top
        case .ocean: return .topLeading
        default: return .topLeading
        }
    }

    private var endPoint: UnitPoint {
        switch theme {
        case .paper: return .bottom
        case .ocean: return .bottomTrailing
        default: return .bottomTrailing
        }
    }

    private var gradientColors: [Color] {
        if colorScheme == .dark {
            return darkColors
        } else {
            return lightColors
        }
    }

    private var lightColors: [Color] {
        switch theme {
        case .studio:
            return [Color(red: 0.96, green: 0.97, blue: 0.99), Color(red: 0.92, green: 0.95, blue: 0.98)]
        case .ocean:
            return [Color(red: 0.948, green: 0.978, blue: 0.995), Color(red: 0.900, green: 0.946, blue: 0.980)]
        case .paper:
            return [Color(red: 0.980, green: 0.960, blue: 0.933), Color(red: 0.941, green: 0.910, blue: 0.863)]
        case .dusk:
            return [Color(red: 0.102, green: 0.082, blue: 0.188), Color(red: 0.141, green: 0.090, blue: 0.251)]
        case .mint:
            return [Color(red: 0.961, green: 0.969, blue: 0.965), Color(red: 0.910, green: 0.929, blue: 0.920)]
        }
    }

    private var darkColors: [Color] {
        switch theme {
        case .studio:
            return [Color(red: 0.09, green: 0.11, blue: 0.15), Color(red: 0.13, green: 0.15, blue: 0.21)]
        case .ocean:
            return [Color(red: 0.10, green: 0.15, blue: 0.21), Color(red: 0.13, green: 0.19, blue: 0.26)]
        case .paper:
            return [Color(red: 0.160, green: 0.130, blue: 0.100), Color(red: 0.190, green: 0.155, blue: 0.125)]
        case .dusk:
            return [Color(red: 0.071, green: 0.055, blue: 0.133), Color(red: 0.110, green: 0.075, blue: 0.200)]
        case .mint:
            return [Color(red: 0.055, green: 0.067, blue: 0.059), Color(red: 0.090, green: 0.106, blue: 0.094)]
        }
    }
}
