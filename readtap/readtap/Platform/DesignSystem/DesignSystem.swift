import SwiftUI

// MARK: - ReadTap Design System
// 앱 전체 디자인 기준점. 새 화면/컴포넌트 만들 때 여기서 가져다 쓰세요.
// 색상은 LibraryTheme.active에 따라 자동 전환됩니다.

// MARK: - Typography

/// 앱 전체 타이포그래피 스케일.
/// 사용: `Text("Hello").font(DS.Typography.title)`
enum DSTypography {
    /// 32pt heavy, -0.8 tracking — 스플래시, 온보딩 대제목
    static let display = Font.system(size: 32, weight: .heavy)

    /// 24pt heavy, -0.8 tracking — 섹션 대제목 (빈 상태 카드 등)
    static let heading1 = Font.system(size: 24, weight: .heavy)

    /// 20pt bold, -0.4 tracking — 카드 제목 (Zen Card 책 제목)
    static let heading2 = Font.system(size: 20, weight: .bold)

    /// 16pt bold, -0.3 tracking — 서브 제목
    static let heading3 = Font.system(size: 16, weight: .bold)

    /// 14pt bold — 버튼 텍스트, CTA
    static let button = Font.system(size: 14, weight: .bold)

    /// 14pt heavy — 링 퍼센트, 강조 숫자 (작은)
    static let ringLabel = Font.system(size: 14, weight: .heavy)

    /// 24pt heavy — 스탯 숫자 (Zen Card 내부)
    static let statLarge = Font.system(size: 24, weight: .heavy)

    /// 13pt semibold — 일반 본문 (약간 강조)
    static let body = Font.system(size: 13, weight: .semibold)

    /// 13pt regular — 일반 본문
    static let bodyRegular = Font.system(size: 13, weight: .regular)

    /// 12pt medium — 메타 정보 (페이지, 날짜)
    static let caption = Font.system(size: 12, weight: .medium)

    /// 11pt semibold — 서브 정보, 날짜 라벨
    static let subcaption = Font.system(size: 11, weight: .semibold)

    /// 10pt bold, uppercase, tracking 1.5 — 섹션 아이브로우 라벨
    static let eyebrow = Font.system(size: 10, weight: .bold)

    /// 9pt semibold, uppercase — 스탯 라벨 (SAVED, REVIEW)
    static let micro = Font.system(size: 9, weight: .semibold)
}

// MARK: - Spacing

/// 앱 전체 간격 스케일.
/// 사용: `.padding(DS.Spacing.cardPadding)` 또는 `VStack(spacing: DS.Spacing.sm)`
enum DSSpacing {
    /// 4pt — 텍스트 내부 미세 간격
    static let xs: CGFloat = 4

    /// 8pt — 컴팩트 요소 간격
    static let sm: CGFloat = 8

    /// 12pt — 기본 요소 간격
    static let md: CGFloat = 12

    /// 16pt — 섹션 내 간격, HStack/VStack 기본
    static let lg: CGFloat = 16

    /// 20pt — 카드 내 섹션 구분
    static let xl: CGFloat = 20

    /// 28pt — 큰 카드 내부 패딩 (Zen Card)
    static let cardPadding: CGFloat = 28

    /// 20pt — 일반 카드 내부 패딩
    static let cardPaddingCompact: CGFloat = 20

    /// 16pt — 화면 좌우 수평 패딩
    static let screenHorizontal: CGFloat = 16

    /// 20pt — 화면 좌우 여유 패딩
    static let screenHorizontalWide: CGFloat = 20
}

// MARK: - Radius

/// 코너 반경 스케일. 모두 `.continuous` 스타일 사용.
/// 사용: `.clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))`
enum DSRadius {
    /// 4pt — 아주 작은 요소 (OCR 박스, 인라인 뱃지)
    static let xs: CGFloat = 4

    /// 8pt — 작은 뱃지, 칩
    static let sm: CGFloat = 8

    /// 12pt — 텍스트필드, 작은 카드
    static let md: CGFloat = 12

    /// 14pt — 커버 이미지, 폴더 아이템
    static let cover: CGFloat = 14

    /// 16pt — 버튼, 중간 카드
    static let button: CGFloat = 16

    /// 20pt — 일반 카드, 패널
    static let card: CGFloat = 20

    /// 28pt — 메인 카드 (Zen Card, 히어로)
    static let cardLarge: CGFloat = 28
}

// MARK: - Elevation (Shadow)

/// 그림자/깊이 스케일.
/// 사용: `.modifier(DS.Elevation.card)`
enum DSElevation {
    /// 미세한 떠있음 — 뱃지, 칩
    static let subtle = ElevationModifier(color: .black.opacity(0.03), radius: 4, y: 2)

    /// 기본 카드 — 스탯 카드, 리스트 아이템
    static let card = ElevationModifier(color: .black.opacity(0.04), radius: 10, y: 6)

    /// 강조 카드 — Zen Card, 히어로 카드
    static let prominent = ElevationModifier(color: .black.opacity(0.06), radius: 20, y: 8)

    /// 다이얼로그, 모달
    static let dialog = ElevationModifier(color: .black.opacity(0.08), radius: 24, y: 10)

    /// CTA 버튼 (테마 악센트 색상 사용)
    static func accentGlow(color: Color) -> ElevationModifier {
        ElevationModifier(color: color.opacity(0.2), radius: 12, y: 8)
    }
}

struct ElevationModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        content.shadow(color: color, radius: radius, x: 0, y: y)
    }
}

// MARK: - Colors (Theme-Adaptive)

/// 앱 전체 색상 토큰. LibraryTheme.active에 따라 자동 전환.
/// 사용: `Text("Hello").foregroundStyle(DS.Colors.ink)`
enum DSColors {
    private static var theme: LibraryTheme { LibraryTheme.active }

    // ── Text ──

    /// 기본 텍스트 (제목, 본문)
    static var ink: Color {
        switch theme {
        case .studio: return Color(red: 0.122, green: 0.153, blue: 0.200)
        case .ocean:  return Color(red: 0.132, green: 0.192, blue: 0.278)
        case .paper:  return Color(red: 0.239, green: 0.180, blue: 0.122)
        case .dusk:   return Color(red: 0.929, green: 0.910, blue: 0.980)
        case .mint:   return Color(red: 0.110, green: 0.157, blue: 0.141)
        }
    }

    /// 보조 텍스트 (메타, 캡션)
    static var muted: Color {
        switch theme {
        case .studio: return Color(red: 0.416, green: 0.455, blue: 0.510)
        case .ocean:  return Color(red: 0.431, green: 0.510, blue: 0.592)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.627, green: 0.565, blue: 0.816)
        case .mint:   return Color(red: 0.380, green: 0.440, blue: 0.408)
        }
    }

    /// 아이브로우/섹션 라벨
    static var eyebrow: Color {
        switch theme {
        case .studio: return Color(red: 0.500, green: 0.553, blue: 0.608)
        case .ocean:  return Color(red: 0.494, green: 0.584, blue: 0.667)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.706, green: 0.604, blue: 1.000)
        case .mint:   return Color(red: 0.420, green: 0.561, blue: 0.494)
        }
    }

    /// 강조 라벨 (버튼 내부 텍스트 등)
    static var labelStrong: Color {
        switch theme {
        case .studio: return Color(red: 0.282, green: 0.333, blue: 0.392)
        case .ocean:  return Color(red: 0.290, green: 0.353, blue: 0.439)
        case .paper:  return Color(red: 0.290, green: 0.220, blue: 0.155)
        case .dusk:   return Color(red: 0.839, green: 0.816, blue: 0.929)
        case .mint:   return Color(red: 0.180, green: 0.260, blue: 0.220)
        }
    }

    // ── Accent ──

    /// 테마 메인 색 (버튼, 링, 강조)
    static var accent: Color {
        switch theme {
        case .studio: return Color(red: 0.122, green: 0.678, blue: 0.380)
        case .ocean:  return Color(red: 0.400, green: 0.659, blue: 0.871)
        case .paper:  return Color(red: 0.706, green: 0.424, blue: 0.282)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000)
        case .mint:   return Color(red: 0.239, green: 0.420, blue: 0.337)
        }
    }

    /// 테마 딥 악센트 (그라데이션 끝)
    static var accentDeep: Color {
        switch theme {
        case .studio: return Color(red: 0.090, green: 0.518, blue: 0.286)
        case .ocean:  return Color(red: 0.271, green: 0.502, blue: 0.722)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200)
        case .dusk:   return Color(red: 0.431, green: 0.294, blue: 0.860)
        case .mint:   return Color(red: 0.165, green: 0.310, blue: 0.243)
        }
    }

    /// 경고/위험 색 (삭제, 에러)
    static var danger: Color {
        Color(red: 0.94, green: 0.20, blue: 0.20)
    }

    /// 보류/복습 필요 (앰버)
    static var amber: Color {
        switch theme {
        case .studio: return Color(red: 0.788, green: 0.612, blue: 0.373)
        case .ocean:  return Color(red: 0.863, green: 0.690, blue: 0.475)
        case .paper:  return Color(red: 0.769, green: 0.510, blue: 0.282)
        case .dusk:   return Color(red: 0.910, green: 0.478, blue: 0.627)
        case .mint:   return Color(red: 0.420, green: 0.490, blue: 0.455)
        }
    }

    // ── Surfaces ──

    /// 화면 배경 그라데이션
    static var background: LinearGradient {
        switch theme {
        case .studio: return LinearGradient(colors: [Color(red: 0.966, green: 0.973, blue: 0.980), Color(red: 0.916, green: 0.936, blue: 0.952)], startPoint: .top, endPoint: .bottom)
        case .ocean:  return LinearGradient(colors: [Color(red: 0.950, green: 0.978, blue: 0.995), Color(red: 0.906, green: 0.947, blue: 0.980)], startPoint: .top, endPoint: .bottom)
        case .paper:  return LinearGradient(colors: [Color(red: 0.980, green: 0.960, blue: 0.933), Color(red: 0.941, green: 0.910, blue: 0.863)], startPoint: .top, endPoint: .bottom)
        case .dusk:   return LinearGradient(colors: [Color(red: 0.102, green: 0.082, blue: 0.188), Color(red: 0.141, green: 0.090, blue: 0.251)], startPoint: .top, endPoint: .bottom)
        case .mint:   return LinearGradient(colors: [Color(red: 0.961, green: 0.969, blue: 0.965), Color(red: 0.910, green: 0.929, blue: 0.920)], startPoint: .top, endPoint: .bottom)
        }
    }

    /// 카드 채우기 (반투명 흰색 or Dusk 다크)
    static var cardFill: Color {
        switch theme {
        case .dusk: return Color(red: 0.120, green: 0.100, blue: 0.210).opacity(0.90)
        default:    return Color.white.opacity(theme == .ocean ? 0.88 : 0.84)
        }
    }

    /// 메인 카드 채우기 (불투명 — Zen Card, 다이얼로그)
    static var cardFillSolid: Color {
        switch theme {
        case .dusk: return Color(red: 0.120, green: 0.100, blue: 0.210).opacity(0.95)
        default:    return .white
        }
    }

    /// 비활성 필 (위크 도트, 빈 바)
    static var fillMuted: Color {
        switch theme {
        case .studio: return Color(red: 0.922, green: 0.937, blue: 0.944)
        case .ocean:  return Color(red: 0.925, green: 0.945, blue: 0.958)
        case .paper:  return Color(red: 0.955, green: 0.935, blue: 0.905)
        case .dusk:   return Color(red: 0.150, green: 0.125, blue: 0.235)
        case .mint:   return Color(red: 0.925, green: 0.940, blue: 0.933)
        }
    }

    /// 진행 링 트랙 (빈 부분)
    static var ringTrack: Color {
        switch theme {
        case .studio: return Color(red: 0.922, green: 0.933, blue: 0.944)
        case .ocean:  return Color(red: 0.910, green: 0.936, blue: 0.955)
        case .paper:  return Color(red: 0.940, green: 0.920, blue: 0.895)
        case .dusk:   return Color(red: 0.180, green: 0.155, blue: 0.280)
        case .mint:   return Color(red: 0.910, green: 0.925, blue: 0.918)
        }
    }

    /// 뱃지/태그 배경
    static var badgeFill: Color {
        accent.opacity(0.12)
    }

    // ── Borders ──

    /// 기본 카드/패널 보더
    static var border: Color {
        switch theme {
        case .studio: return Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.06)
        case .ocean:  return Color(red: 0.169, green: 0.271, blue: 0.365).opacity(0.08)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200).opacity(0.08)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.15)
        case .mint:   return Color(red: 0.176, green: 0.314, blue: 0.255).opacity(0.06)
        }
    }

    /// 악센트 틴트 보더 (히어로 카드)
    static var borderAccent: Color { accent.opacity(0.08) }

    // ── Gradients ──

    /// CTA 버튼 그라데이션
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 히어로/빈 상태 카드 배경
    static var heroGradient: LinearGradient {
        let top: Color
        let bottom: Color
        switch theme {
        case .studio: top = Color(red: 0.932, green: 0.955, blue: 0.944); bottom = Color(red: 0.906, green: 0.933, blue: 0.920)
        case .ocean:  top = Color(red: 0.909, green: 0.956, blue: 0.990); bottom = Color(red: 0.877, green: 0.934, blue: 0.975)
        case .paper:  top = Color(red: 0.972, green: 0.950, blue: 0.920); bottom = Color(red: 0.955, green: 0.930, blue: 0.895)
        case .dusk:   top = Color(red: 0.130, green: 0.108, blue: 0.218); bottom = Color(red: 0.110, green: 0.090, blue: 0.195)
        case .mint:   top = Color(red: 0.940, green: 0.955, blue: 0.948); bottom = Color(red: 0.920, green: 0.938, blue: 0.930)
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Component Styles

/// 재사용 가능한 컴포넌트 스타일 모디파이어들.
enum DSComponents {

    /// 기본 카드 스타일 (반투명 배경, 보더, 그림자)
    struct Card: ViewModifier {
        var radius: CGFloat = DSRadius.card

        func body(content: Content) -> some View {
            content
                .background(DSColors.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(DSColors.border, lineWidth: 1)
                )
                .modifier(DSElevation.card)
        }
    }

    /// 메인 카드 스타일 (불투명, 큰 반경, 강한 그림자)
    struct CardProminent: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(DSColors.cardFillSolid)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.cardLarge, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.cardLarge, style: .continuous)
                        .stroke(DSColors.border, lineWidth: 1)
                )
                .modifier(DSElevation.prominent)
        }
    }

    /// CTA 버튼 스타일 (악센트 그라데이션, 흰 텍스트)
    struct CTAButton: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(DSTypography.button)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(DSColors.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous))
                .modifier(DSElevation.accentGlow(color: DSColors.accent))
        }
    }

    /// 아이브로우 라벨 스타일 (작은 대문자 섹션 제목)
    struct Eyebrow: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(DSTypography.eyebrow)
                .foregroundStyle(DSColors.eyebrow)
                .textCase(.uppercase)
                .tracking(1.5)
        }
    }

    /// 진행 링 뷰
    struct ProgressRing: View {
        let percent: Int
        var size: CGFloat = 64
        var lineWidth: CGFloat = 5

        var body: some View {
            let fraction = Double(percent) / 100.0
            ZStack {
                Circle()
                    .stroke(DSColors.ringTrack, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(DSColors.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)%")
                    .font(size >= 64 ? DSTypography.ringLabel : .system(size: 10, weight: .heavy))
                    .foregroundStyle(DSColors.accent)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - iPad Adaptive Layout

/// iPad에서 컨텐츠가 너무 작아보이지 않도록 적응형 레이아웃 값을 제공합니다.
enum DSLayout {
    /// iPad 여부
    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 화면 주요 콘텐츠 최대 너비 (iPad에서 너무 넓게 퍼지지 않도록)
    static var contentMaxWidth: CGFloat {
        isPad ? 720 : .infinity
    }

    /// 홈/Words 등 메인 탭 콘텐츠 최대 너비
    static var mainContentMaxWidth: CGFloat {
        isPad ? 680 : .infinity
    }

    /// 화면 좌우 수평 패딩
    static var screenHorizontal: CGFloat {
        isPad ? 32 : 16
    }

    /// 그리드 컬럼 수 (홈 책 그리드)
    static var bookGridColumns: Int {
        isPad ? 3 : 2
    }

    /// 카드 내부 패딩
    static var cardPadding: CGFloat {
        isPad ? 32 : 20
    }

    /// 위크 스트립 높이
    static var weekStripHeight: CGFloat {
        isPad ? 90 : 64
    }

    /// 위크 스트립 날짜 셀 너비
    static var weekStripPillWidth: CGFloat {
        isPad ? 88 : 72
    }

    /// 폰트 스케일 팩터 (iPad에서 약간 키움)
    static var fontScale: CGFloat {
        isPad ? 1.15 : 1.0
    }

    /// 그리드 아이템 간격
    static var gridSpacing: CGFloat {
        isPad ? 20 : 14
    }

    /// 세그먼트 피커 높이
    static var segmentHeight: CGFloat {
        isPad ? 48 : 38
    }

    // MARK: 그리드 카드 (Library gridCard)

    static var gridCoverHeight: CGFloat { isPad ? 240 : 200 }
    static var gridCardSpacing: CGFloat { isPad ? 20 : 14 }

    // MARK: 리스트 카드 (Library listCard, completedCompactCard)

    static var listCoverWidth: CGFloat { isPad ? 74 : 64 }
    static var listCoverHeight: CGFloat { isPad ? 99 : 86 }
    static var listCardPadding: CGFloat { isPad ? 16 : 14 }
    static var listCardSpacing: CGFloat { isPad ? 16 : 14 }
    static var listCardCornerRadius: CGFloat { isPad ? 23 : 20 }

    // MARK: By-book 아코디언 커버

    static var accordionCoverWidth: CGFloat { isPad ? 64 : 56 }
    static var accordionCoverHeight: CGFloat { isPad ? 85 : 74 }
    static var accordionCircleSize: CGFloat { isPad ? 42 : 36 }

    // MARK: 칩 (폴더 칩, 필터 칩)

    static var chipFontSize: CGFloat { isPad ? 14 : 12 }
    static var chipHPadding: CGFloat { isPad ? 16 : 14 }
    static var chipVPadding: CGFloat { isPad ? 10 : 8 }
    static var chipCornerRadius: CGFloat { isPad ? 12 : 10 }

    // MARK: 리스트 아이템 폰트

    static var listTitleSize: CGFloat { isPad ? 17 : 15 }
    static var listSubtitleSize: CGFloat { isPad ? 14 : 12 }
    static var listBadgeSize: CGFloat { isPad ? 12 : 10 }
    static var listPercentSize: CGFloat { isPad ? 15 : 13 }
    static var listDateSize: CGFloat { isPad ? 12 : 10 }
    static var listCaptionSize: CGFloat { isPad ? 13 : 11 }

    // MARK: 섹션 헤더

    static var sectionTitleSize: CGFloat { isPad ? 21 : 18 }
    static var sectionSubheadSize: CGFloat { isPad ? 15 : 13 }
    static var eyebrowSize: CGFloat { isPad ? 13 : 11 }

    // MARK: 기타

    static var progressBarHeight: CGFloat { isPad ? 4 : 3 }
    static var chevronSize: CGFloat { isPad ? 14 : 12 }
    static var smallBadgeIconSize: CGFloat { isPad ? 10 : 9 }
    static var smallBadgeLabelSize: CGFloat { isPad ? 12 : 10 }

    // MARK: 캘린더

    /// 월간 캘린더 카드 패딩
    static var calendarPadding: CGFloat { isPad ? 16 : 12 }
    /// 월간 캘린더 카드 코너
    static var calendarCornerRadius: CGFloat { isPad ? 20 : 16 }
    /// 캘린더 헤더 버튼 크기
    static var calendarNavButton: CGFloat { isPad ? 36 : 30 }
    /// 캘린더 헤더 타이틀 폰트
    static var calendarTitleSize: CGFloat { isPad ? 18 : 16 }
    /// 캘린더 그리드 셀 높이
    static var calendarCellHeight: CGFloat { isPad ? 42 : 36 }
    /// 캘린더 그리드 간격
    static var calendarGridSpacing: CGFloat { isPad ? 10 : 8 }
    /// 캘린더 날짜 폰트
    static var calendarDaySize: CGFloat { isPad ? 16 : 14 }
    /// 캘린더 배지 크기
    static var calendarBadgeSize: CGFloat { isPad ? 16 : 14 }
    /// 캘린더 배지 아이콘 폰트
    static var calendarBadgeIconSize: CGFloat { isPad ? 8 : 7 }
    /// 캘린더 골 서클 크기
    static var calendarGoalCircle: CGFloat { isPad ? 40 : 34 }
    /// 캘린더 골 닷 크기
    static var calendarGoalDot: CGFloat { isPad ? 9 : 8 }
    /// 캘린더 투데이 링 크기
    static var calendarTodayRing: CGFloat { isPad ? 42 : 36 }
    /// 레전드 닷 크기
    static var calendarLegendDot: CGFloat { isPad ? 18 : 16 }
    /// 스트릭 캘린더 셀 크기
    static var streakCellSize: CGFloat { isPad ? 44 : 38 }
    /// 스트릭 캘린더 그리드 간격
    static var streakGridSpacing: CGFloat { isPad ? 12 : 10 }
    /// 스트릭 닫기 버튼
    static var streakCloseButton: CGFloat { isPad ? 32 : 28 }
    /// 스트릭 캘린더 오버레이 최대 너비
    static var streakOverlayMaxWidth: CGFloat { isPad ? 440 : 360 }
}

// MARK: - View Extensions

extension View {
    /// iPad에서 콘텐츠를 가운데 정렬하고 최대 너비를 제한
    func dsContentWidth(_ maxWidth: CGFloat = DSLayout.mainContentMaxWidth) -> some View {
        self.frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    /// 기본 카드 스타일 적용
    func dsCard(radius: CGFloat = DSRadius.card) -> some View {
        modifier(DSComponents.Card(radius: radius))
    }

    /// 메인 카드 스타일 적용 (Zen Card 등)
    func dsCardProminent() -> some View {
        modifier(DSComponents.CardProminent())
    }

    /// CTA 버튼 스타일 적용
    func dsCTA() -> some View {
        modifier(DSComponents.CTAButton())
    }

    /// 아이브로우 라벨 스타일 적용
    func dsEyebrow() -> some View {
        modifier(DSComponents.Eyebrow())
    }
}
