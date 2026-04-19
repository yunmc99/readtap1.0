import SwiftUI

// MARK: - Premium Comparison Promo (Concept B — Swipe Reveal)

struct PremiumComparisonPromoSheet: View {
  let lookupCount: Int
  let onUpgrade: () -> Void
  let onDismiss: () -> Void
  var onDontShowToday: (() -> Void)? = nil

  @ObservedObject private var subscription = SubscriptionManager.shared
  @EnvironmentObject private var appSettings: AppSettings
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var hSizeClass

  @State private var dividerFraction: CGFloat = 0.45
  @State private var isStartingTrial = false
  @State private var trialError: String?
  @State private var measuredHeight: CGFloat = 700

  private var theme: LibraryTheme { appSettings.theme }
  private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
  private var isRegular: Bool { hSizeClass == .regular }
  private var scale: CGFloat { DSLayout.fontScale }

  private var isTrialNotStarted: Bool {
    if case .notStarted = subscription.trialState { return true }
    return false
  }
  private var showTrialButton: Bool {
    isTrialNotStarted && !subscription.isTrialOfferDisabled
  }

  var body: some View {
    GeometryReader { geo in
      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 0) {
          headerSection
          swipeComparisonCard
            .padding(.horizontal, DSLayout.screenHorizontal)
            .padding(.bottom, cardBottomPadding)
          featuresList
          Spacer(minLength: 12)
          ctaSection
        }
        .frame(maxWidth: DSLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .frame(minHeight: geo.size.height)
      }
      .background(Color(uiColor: .systemBackground))
      .onAppear {
        if measuredHeight != geo.size.height {
          measuredHeight = geo.size.height
        }
      }
      .onChange(of: geo.size.height) { _, newValue in
        measuredHeight = newValue
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationBackground(Color(uiColor: .systemBackground))
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(spacing: 6 * scale) {
      Text("PREMIUM")
        .font(.system(size: 10 * scale, weight: .bold))
        .tracking(1.5)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
          Capsule()
            .fill(
              LinearGradient(
                colors: [palette.accent, palette.accent.opacity(0.8)],
                startPoint: .leading,
                endPoint: .trailing)
            )
        )

      Text(AppText.L(
        "Compare for yourself",
        "직접 비교해 보세요",
        "亲自对比一下"))
        .font(.system(size: 22 * scale, weight: .heavy))
        .foregroundStyle(palette.text)

      Text(AppText.L(
        "Drag the slider to see the difference",
        "슬라이더를 드래그해서 차이를 확인하세요",
        "拖动滑块查看区别"))
        .font(.system(size: 12 * scale, weight: .regular))
        .foregroundStyle(palette.muted)
    }
    .multilineTextAlignment(.center)
    .padding(.top, headerVerticalPadding)
    .padding(.bottom, headerVerticalPadding)
  }

  private var headerVerticalPadding: CGFloat {
    // 20pt on compact iPhones, up to ~36pt on large iPhones / iPad
    let extra = max(0, (measuredHeight - 700)) * 0.04
    return 20 + min(extra, 16)
  }

  private var cardBottomPadding: CGFloat {
    // Scale the gap below the comparison card with available height
    let extra = max(0, (measuredHeight - 700)) * 0.04
    return (16 * scale) + min(extra, 18)
  }

  // MARK: - Swipe Comparison

  private var swipeComparisonCard: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = comparisonHeight

      ZStack {
        // Right side (Premium) — full width, behind
        premiumSide(width: w)
          .frame(width: w, height: h)
          .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))

        // Left side (Free) — clipped to divider position
        freeSide(width: w)
          .frame(width: w, height: h)
          .clipShape(
            HorizontalClip(fraction: dividerFraction)
          )
          .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))

        // Draggable divider with wide hit area
        Color.clear
          .frame(width: 44, height: h)
          .contentShape(Rectangle())
          .position(x: w * dividerFraction, y: h / 2)
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                let fraction = value.location.x / w
                dividerFraction = min(max(fraction, 0.0), 1.0)
              }
          )

        // Divider visual (non-interactive)
        dividerLine(containerWidth: w, containerHeight: h)
          .allowsHitTesting(false)
      }
      .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
          .stroke(palette.muted.opacity(0.12), lineWidth: 1)
      )
    }
    .frame(height: comparisonHeight)
  }

  private var comparisonHeight: CGFloat {
    if isRegular {
      // iPad: grow with screen, cap to stay visually balanced
      return min(max(340, measuredHeight * 0.42), 520)
    } else {
      // iPhone: scale with screen height so tall devices fill more
      return min(max(260, measuredHeight * 0.34), 360)
    }
  }

  // MARK: - Free Side

  private func freeSide(width: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      Rectangle()
        .fill(colorScheme == .dark
              ? Color(uiColor: .secondarySystemBackground)
              : Color(red: 0.98, green: 0.97, blue: 0.96))

      ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          Text(AppText.L("NOW", "현재", "当前"))
            .font(.system(size: 9 * scale, weight: .bold))
            .tracking(1.5)
            .foregroundStyle(palette.muted)
            .padding(.bottom, 12)

          Text("serendipity")
            .font(.system(size: 18 * scale, weight: .heavy, design: .rounded))
            .foregroundStyle(palette.text)
            .padding(.bottom, 8)

          Text(AppText.L(
            "Fortunate discovery, luck",
            "우연한 발견, 행운",
            "偶然的发现，幸运"))
            .font(.system(size: 11 * scale, weight: .regular))
            .foregroundStyle(palette.muted)
            .padding(.bottom, 20)

          // Locked indicator
          HStack(spacing: 4) {
            Image(systemName: "lock.fill")
              .font(.system(size: 8 * scale))
            Text(AppText.L(
              "Synonyms & sentence translation are Premium",
              "유의어·문장번역은 Premium",
              "同义词·句子翻译为Premium功能"))
              .font(.system(size: 8 * scale, weight: .semibold))
          }
          .foregroundStyle(palette.muted.opacity(0.6))
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            Capsule()
              .fill(palette.muted.opacity(0.06))
          )
        }
        .padding(20)
        .frame(width: width, alignment: .leading)
      }
    }
  }

  // MARK: - Premium Side

  private func premiumSide(width: CGFloat) -> some View {
    ZStack(alignment: .topLeading) {
      Rectangle()
        .fill(
          LinearGradient(
            colors: [
              palette.accent.opacity(colorScheme == .dark ? 0.08 : 0.04),
              colorScheme == .dark
                ? Color(uiColor: .secondarySystemBackground)
                : Color.white
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        )

      ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 4) {
            Image(systemName: "sparkle")
              .font(.system(size: 8 * scale, weight: .bold))
            Text("PREMIUM")
              .font(.system(size: 9 * scale, weight: .bold))
              .tracking(1.5)
          }
          .foregroundStyle(palette.accent)
          .padding(.bottom, 12)

          Text("serendipity")
            .font(.system(size: 18 * scale, weight: .heavy, design: .rounded))
            .foregroundStyle(palette.text)
            .padding(.bottom, 6)

          // POS badge
          Text("Noun")
            .font(.system(size: 9 * scale, weight: .bold))
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(palette.accent.opacity(0.1))
            )
            .padding(.bottom, 6)

          Text(AppText.L(
            "The ability or luck of finding good things by chance; an unexpected pleasant discovery",
            "우연히 좋은 것을 발견하는 능력이나 행운; 예기치 않은 기쁜 발견",
            "偶然发现美好事物的能力或运气；意外的惊喜发现"))
            .font(.system(size: 11 * scale, weight: .regular))
            .foregroundStyle(palette.text.opacity(0.8))
            .padding(.bottom, 10)

          // Sentence translation box
          VStack(alignment: .leading, spacing: 3) {
            Text(AppText.L("SENTENCE", "문장 번역", "句子翻译"))
              .font(.system(size: 7 * scale, weight: .bold))
              .tracking(1)
              .foregroundStyle(palette.accent)

            Group {
              switch AppLanguage.current() {
              case .korean:
                Text("It was pure ") + Text("serendipity").bold().foregroundColor(palette.accent) +
                Text(" that they met → 그들이 만난 것은 순전한 ") + Text("우연").bold().foregroundColor(palette.accent) +
                Text("이었다")
              case .chinese:
                Text("It was pure ") + Text("serendipity").bold().foregroundColor(palette.accent) +
                Text(" → 这纯粹是") + Text("缘分").bold().foregroundColor(palette.accent)
              default:
                Text("It was pure ") + Text("serendipity").bold().foregroundColor(palette.accent) +
                Text(" that they met → 그들이 만난 것은 순전한 ") + Text("우연").bold().foregroundColor(palette.accent) +
                Text("이었다")
              }
            }
            .font(.system(size: 9 * scale))
            .foregroundStyle(palette.muted)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(palette.accent.opacity(0.04))
              .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .stroke(palette.accent.opacity(0.1), lineWidth: 0.5)
              )
          )
          .padding(.bottom, 10)

          // Synonyms
          VStack(alignment: .leading, spacing: 4) {
            Text(AppText.L("SYNONYMS", "유의어", "同义词"))
              .font(.system(size: 7 * scale, weight: .bold))
              .tracking(1)
              .foregroundStyle(palette.accent.opacity(0.7))

            FlowLayout(spacing: 4) {
              ForEach(["fortune", "luck", "chance", "fate"], id: \.self) { word in
                Text(word)
                  .font(.system(size: 8 * scale, weight: .semibold))
                  .foregroundStyle(palette.accent)
                  .padding(.horizontal, 7)
                  .padding(.vertical, 3)
                  .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                      .fill(palette.accent.opacity(0.06))
                      .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                          .stroke(palette.accent.opacity(0.12), lineWidth: 0.5)
                      )
                  )
              }
            }
          }
          .padding(.bottom, 10)

          // Antonyms
          VStack(alignment: .leading, spacing: 4) {
            Text(AppText.L("ANTONYMS", "반의어", "反义词"))
              .font(.system(size: 7 * scale, weight: .bold))
              .tracking(1)
              .foregroundStyle(Color(red: 0.77, green: 0.35, blue: 0.19).opacity(0.7))

            FlowLayout(spacing: 4) {
              ForEach(["misfortune", "design"], id: \.self) { word in
                Text(word)
                  .font(.system(size: 8 * scale, weight: .semibold))
                  .foregroundStyle(Color(red: 0.77, green: 0.35, blue: 0.19))
                  .padding(.horizontal, 7)
                  .padding(.vertical, 3)
                  .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                      .fill(Color(red: 0.87, green: 0.39, blue: 0.25).opacity(0.06))
                      .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                          .stroke(Color(red: 0.87, green: 0.39, blue: 0.25).opacity(0.12), lineWidth: 0.5)
                      )
                  )
              }
            }
          }
        }
        .padding(20)
        .frame(width: width, alignment: .leading)
      }
    }
  }

  // MARK: - Divider Handle

  private func dividerLine(containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
    let x = containerWidth * dividerFraction
    return ZStack {
      // Vertical line
      Rectangle()
        .fill(
          LinearGradient(
            colors: [palette.accent.opacity(0), palette.accent, palette.accent.opacity(0)],
            startPoint: .top,
            endPoint: .bottom)
        )
        .frame(width: 2)

      // Handle circle
      Circle()
        .fill(palette.accent)
        .frame(width: 36, height: 36)
        .shadow(color: palette.accent.opacity(0.35), radius: 8, y: 2)
        .overlay(
          HStack(spacing: 3) {
            Image(systemName: "chevron.left")
              .font(.system(size: 9, weight: .bold))
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .bold))
          }
          .foregroundStyle(.white)
        )
    }
    .frame(height: containerHeight)
    .position(x: x, y: containerHeight / 2)
  }

  // MARK: - Features List

  private var featuresList: some View {
    VStack(spacing: 0) {
      featureRow(
        icon: "sparkles",
        title: AppText.L("AI Accurate Translation", "AI 정확 번역", "AI精准翻译"),
        subtitle: AppText.L(
          "Natural, context-aware meanings",
          "문맥에 맞는 자연스러운 뜻",
          "符合语境的自然释义"))
      featureRow(
        icon: "arrow.triangle.branch",
        title: AppText.L("Synonyms & Antonyms", "유의어 · 반의어", "同义词·反义词"),
        subtitle: AppText.L(
          "Learn related vocabulary together",
          "관련 어휘를 함께 학습",
          "一起学习相关词汇"))
      featureRow(
        icon: "text.quote",
        title: AppText.L("Sentence Translation", "문장 번역", "句子翻译"),
        subtitle: AppText.L(
          "Translate the sentence containing the word",
          "선택한 단어가 포함된 문장도 번역",
          "翻译包含该单词的句子"))
    }
    .padding(.bottom, 8)
  }

  @ViewBuilder
  private func featureRow(icon: String, title: String, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(palette.accent.opacity(0.08))
          .frame(width: 32 * scale, height: 32 * scale)
        Image(systemName: icon)
          .font(.system(size: 14 * scale, weight: .medium))
          .foregroundStyle(palette.accent)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13 * scale, weight: .bold))
          .foregroundStyle(palette.text)
        Text(subtitle)
          .font(.system(size: 10 * scale, weight: .regular))
          .foregroundStyle(palette.muted)
      }

      Spacer()
    }
    .padding(.horizontal, DSLayout.screenHorizontal + 4)
    .padding(.vertical, isRegular ? 13 : 9)
  }

  // MARK: - CTA

  private var ctaSection: some View {
    VStack(spacing: 8) {
      if showTrialButton {
        Button {
          startTrial()
        } label: {
          HStack(spacing: 6) {
            if isStartingTrial {
              ProgressView()
                .tint(.white)
                .scaleEffect(0.8)
            }
            Text(AppText.L("Start 7-Day Free Trial", "7일 무료 체험 시작", "开始7天免费试用"))
              .font(.system(size: 15 * scale, weight: .bold))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 15)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(palette.accent)
              .shadow(color: palette.accent.opacity(0.3), radius: 12, y: 4)
          )
          .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(isStartingTrial)
        .padding(.horizontal, DSLayout.screenHorizontal)

        Button(action: onUpgrade) {
          Text(AppText.L("View plans", "요금제 보기", "查看套餐"))
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
        .buttonStyle(.plain)
      } else {
        Button(action: onUpgrade) {
          Text(AppText.L("Subscribe Now", "지금 구독하기", "立即订阅"))
            .font(.system(size: 15 * scale, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.accent)
                .shadow(color: palette.accent.opacity(0.3), radius: 12, y: 4)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSLayout.screenHorizontal)
      }

      // Trial error
      if let error = trialError {
        Text(error)
          .font(.caption)
          .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.22))
          .multilineTextAlignment(.center)
          .padding(.horizontal, DSLayout.screenHorizontal)
      }

      Text(AppText.L(
        "No charge after free trial · Cancel anytime",
        "무료 체험 후 자동 결제 없음",
        "免费试用后无自动扣费"))
        .font(.system(size: 10 * scale))
        .foregroundStyle(palette.muted.opacity(0.6))

      Button(action: onDismiss) {
        Text(AppText.L("Maybe later", "나중에", "以后再说"))
          .font(.system(size: 12 * scale, weight: .medium))
          .foregroundStyle(palette.muted)
          .padding(.vertical, 4)
      }
      .buttonStyle(.plain)

      if let dontShow = onDontShowToday {
        Button(action: dontShow) {
          Text(AppText.L("Don't show today", "오늘 그만 보기", "今天不再显示"))
            .font(.system(size: 10 * scale))
            .foregroundStyle(palette.muted.opacity(0.5))
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.top, 8)
    .padding(.bottom, 20)
  }

  // MARK: - Trial Logic

  private func startTrial() {
    isStartingTrial = true
    trialError = nil
    Task {
      let result = await subscription.startTrialAndSync()
      await MainActor.run {
        isStartingTrial = false
        switch result {
        case .success:
          onDismiss()
        case .deviceAlreadyUsed:
          trialError = AppText.L(
            "Free trial has already been used on this device.",
            "이 기기에서 이미 무료 체험을 사용했습니다.",
            "此设备已使用过免费试用。")
        case .trialAlreadyStarted:
          trialError = AppText.L(
            "Free trial has already been started.",
            "이미 무료 체험이 시작되었습니다.",
            "免费试用已经开始。")
        case .failed(let msg):
          trialError = AppText.L(
            "An error occurred: \(msg)",
            "오류가 발생했습니다: \(msg)",
            "发生错误：\(msg)")
        }
      }
    }
  }
}

// MARK: - Horizontal Clip Shape

private struct HorizontalClip: Shape {
  var fraction: CGFloat

  var animatableData: CGFloat {
    get { fraction }
    set { fraction = newValue }
  }

  func path(in rect: CGRect) -> Path {
    Path(CGRect(x: 0, y: 0, width: rect.width * fraction, height: rect.height))
  }
}
