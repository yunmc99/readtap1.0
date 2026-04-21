//
//  PaywallView.swift
//  readtap
//
//  Subscription paywall — Concept B (side-by-side plan cards).
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject private var manager = SubscriptionManager.shared
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    @State private var selectedProduct: Product? = nil
    @State private var productLoadFailed: Bool = false
    @State private var isStartingTrial = false
    @State private var trialError: String?
    @State private var showTermsSheet = false
    @State private var showPrivacySheet = false
    @State private var showManageSubscription = false

    private var isTrialNotStarted: Bool {
        if case .notStarted = manager.trialState { return true }
        return false
    }

    /// Whether this user is eligible to be offered the 7-day free trial.
    /// Guards against four independent disqualifiers:
    ///   1. Current active subscriber (already paying — don't downgrade UX).
    ///   2. Trial already started / expired locally.
    ///   3. Server-side trial kill switch on.
    ///   4. This Apple ID has *ever* had an auto-renewable subscription —
    ///      returning users who canceled shouldn't be re-offered a trial
    ///      they're no longer eligible for (misleading, soft App Store
    ///      Guideline 3.1.1 issue).
    private var canOfferTrial: Bool {
        !isCurrentSubscriber
            && isTrialNotStarted
            && !manager.isTrialOfferDisabled
            && !manager.hasEverSubscribed
    }

    /// Whether the user already has an active StoreKit subscription.
    private var isCurrentSubscriber: Bool {
        manager.activeSubscriptionProductId != nil
    }

    /// Whether the selected product differs from the current subscription.
    private var isChangingPlan: Bool {
        guard let current = manager.activeSubscriptionProductId,
              let selected = selectedProduct else { return false }
        return selected.id != current
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    planToggleSection
                    featuresSection
                    ctaSection
                    subscriptionDisclosureSection
                    termsSection
                }
                .padding(.horizontal, DSLayout.isPad ? 32 : 20)
                // Extra top padding on iPad because we present as
                // fullScreenCover (no drag indicator), so content shouldn't
                // crowd the status bar / close button.
                .padding(.top, DSLayout.isPad ? 48 : 16)
                .padding(.bottom, 30)
                // Cap the content column at a comfortable reading width so the
                // paywall doesn't stretch awkwardly on iPhone Pro Max / iPad
                // Pro. Phones at standard widths (≤ 460pt after horizontal
                // padding) are unaffected. iPad gets a wider cap (580) so the
                // subscription details block has enough room to display all
                // required information without excessive wrapping.
                .frame(maxWidth: DSLayout.isPad ? 580 : 460)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(DSLayout.isPad ? .title : .title2)
                    .foregroundStyle(palette.muted.opacity(0.5))
                    .padding(DSLayout.isPad ? 20 : 16)
            }
            .accessibilityLabel(AppText.L("Close", "닫기", "关闭"))
        }
        // iPhone bottom-sheet sizing. These are no-ops when PaywallView is
        // presented as a fullScreenCover on iPad.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await manager.loadProducts()
            if selectedProduct == nil {
                // Pre-select current plan for subscribers, yearly for new users
                if let currentId = manager.activeSubscriptionProductId {
                    selectedProduct = manager.products.first { $0.id == currentId }
                } else {
                    selectedProduct = manager.yearlyProduct
                }
            }
            if manager.products.isEmpty {
                productLoadFailed = true
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("ReadTap ")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(palette.text)
                Text("Premium")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(palette.accent)
            }

            // Subtitle precedence, top-down:
            //   1. Active StoreKit subscriber (possibly canceled)
            //   2. Premium via admin override / trial active (no StoreKit sub)
            //   3. Trial expired, not a subscriber
            //   4. Brand-new user (trial not started)
            //
            // Why the `isEffectivelyPremium` second tier: the original logic
            // only checked `isCurrentSubscriber` (= `activeSubscriptionProductId != nil`),
            // which was briefly `nil` during the StoreKit refresh window right
            // after app launch and for admin-overridden accounts. During that
            // window, paying subscribers saw "Your free trial has ended" —
            // misleading and unprofessional. Using `isEffectivelyPremium` as
            // a safety net ensures any premium user (subscriber, admin
            // override, active trial) never sees the trial-ended message.
            if isCurrentSubscriber {
                // If the user has canceled (auto-renewal off), surface the
                // end date so it's clear they'll revert to free tier, and
                // nudge them to resubscribe before that happens.
                if manager.isSubscriptionCanceled, let expiresAt = manager.subscriptionExpiresAt {
                    let formattedDate = expiresAt.formatted(date: .abbreviated, time: .omitted)
                    Text(AppText.L(
                        "Subscription ends on \(formattedDate)",
                        "\(formattedDate)에 구독이 종료돼요",
                        "订阅将于 \(formattedDate) 结束"))
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                } else {
                    Text(AppText.L(
                        "Change your plan anytime",
                        "언제든지 플랜을 변경할 수 있어요",
                        "随时更改您的方案"))
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                }
            } else if case .active(let days) = manager.trialState {
                Text(AppText.L(
                    "\(days) \(AppText.t(.premiumTrialDaysLeft))",
                    "무료 체험 \(days)\(AppText.t(.premiumTrialDaysLeft))",
                    "免费试用还剩\(days)天"
                ))
                    .font(.subheadline)
                    .foregroundStyle(palette.accent)
            } else if manager.isEffectivelyPremium {
                // Premium via admin override, or StoreKit state still catching
                // up post-purchase. Treat as a subscriber for copy purposes —
                // they should never see "trial ended" if they have premium.
                Text(AppText.L(
                    "Premium is active",
                    "프리미엄 이용 중이에요",
                    "高级版已启用"))
                    .font(.subheadline)
                    .foregroundStyle(palette.accent)
            } else if case .expired = manager.trialState {
                Text(AppText.t(.premiumTrialEnded))
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
            } else {
                Text(AppText.L(
                    "Choose the plan that's right for you",
                    "나에게 맞는 플랜을 선택하세요",
                    "选择适合您的方案"))
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 24)
    }

    // MARK: - Side-by-Side Plan Cards

    private var planToggleSection: some View {
        VStack(spacing: 10) {
            if manager.products.isEmpty && productLoadFailed {
                productLoadFailedView
            } else if manager.products.isEmpty {
                ProgressView()
                    .padding(.vertical, 40)
            } else {
                HStack(spacing: 10) {
                    if let monthly = manager.monthlyProduct {
                        planCard(
                            product: monthly,
                            periodLabel: AppText.L("Monthly", "월간", "月付"),
                            isYearly: false
                        )
                    }
                    if let yearly = manager.yearlyProduct {
                        planCard(
                            product: yearly,
                            periodLabel: AppText.L("Yearly", "연간", "年付"),
                            isYearly: true
                        )
                    }
                }
            }

            if case .purchasing = manager.purchaseState {
                ProgressView()
                    .padding(.top, 4)
            }
            if case .failed(let message) = manager.purchaseState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.bottom, 24)
    }

    private func planCard(product: Product, periodLabel: String, isYearly: Bool) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let isCurrent = manager.activeSubscriptionProductId == product.id

        return Button {
            selectedProduct = product
        } label: {
            VStack(spacing: 0) {
                // Subscription title (from StoreKit's localized displayName,
                // e.g. "Monthly Premium" / "Yearly Premium"). Required by
                // App Store Guideline 3.1.2(c): "Title of publication or service".
                Text(product.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.bottom, 4)

                // Period label
                HStack(spacing: 4) {
                    Text(periodLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? palette.accent : palette.muted)
                    if isCurrent {
                        Text(AppText.L("Current", "현재", "当前"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.accent.opacity(0.7)))
                    }
                }
                .padding(.bottom, 10)

                // Price — BILLED amount shown most prominently.
                // App Store Guideline 3.1.2(c) / Nov 2025 review feedback:
                // the total billed amount must be the most clear and
                // conspicuous pricing element. For monthly plans this is the
                // monthly price; for yearly plans this is the yearly price.
                // The calculated per-month equivalent on the yearly card is
                // kept below in a subordinate size.
                Text(product.displayPrice)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(palette.text)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                // Unit — matches the billed amount above (per year for yearly,
                // per month for monthly).
                Text(isYearly
                    ? AppText.L("per year", "년", "每年")
                    : AppText.L("per month", "월", "每月"))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                    .padding(.top, 2)

                if isYearly {
                    // Compare-vs-monthly strikethrough (subordinate to billed).
                    if let monthly = manager.monthlyProduct {
                        Text(annualEquivalent(monthly))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.muted.opacity(0.6))
                            .strikethrough()
                            .padding(.top, 6)
                    }

                    // Calculated per-month equivalent — subordinate in size
                    // and position to the billed annual price above.
                    Text(AppText.L(
                        "\(yearlyPerMonthFormatted(product)) / month equivalent",
                        "월 \(yearlyPerMonthFormatted(product)) 상당",
                        "相当于 \(yearlyPerMonthFormatted(product)) / 月"))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .padding(.top, 2)
                } else {
                    // Mirror the yearly card's two extra slots with invisible
                    // placeholders so both cards share the same intrinsic height.
                    Text(" ")
                        .font(.system(size: 11))
                        .padding(.top, 6)
                        .opacity(0)
                        .accessibilityHidden(true)
                    Text(" ")
                        .font(.system(size: 11))
                        .padding(.top, 2)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected
                        ? palette.accent.opacity(0.04)
                        : theme.cardSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                isSelected ? palette.accent : theme.cardStroke,
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .overlay(alignment: .top) {
                if isYearly, let pct = yearlySavingsPercent {
                    Text(AppText.L("Save \(pct)%", "\(pct)% 할인", "节省 \(pct)%"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.42, blue: 0.21), Color(red: 1.0, green: 0.30, blue: 0.15)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                        .offset(y: -10)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(spacing: 14) {
            featureRow(
                icon: "sparkles",
                title: AppText.t(.premiumFeatureAccurateTitle),
                subtitle: AppText.t(.premiumFeatureAccurateSubtitle)
            )
            featureRow(
                icon: "list.bullet.rectangle.fill",
                title: AppText.t(.premiumFeaturePosTitle),
                subtitle: AppText.t(.premiumFeaturePosSubtitle)
            )
            featureRow(
                icon: "arrow.triangle.branch",
                title: AppText.t(.premiumFeatureSynonymTitle),
                subtitle: AppText.t(.premiumFeatureSynonymSubtitle)
            )
            featureRow(
                icon: "paintpalette.fill",
                title: AppText.t(.premiumFeatureThemeTitle),
                subtitle: AppText.t(.premiumFeatureThemeSubtitle)
            )
        }
        .padding(.bottom, 24)
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(palette.accent.opacity(0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }

            Spacer()
        }
    }

    // MARK: - CTA

    private var ctaSection: some View {
        VStack(spacing: 8) {
            // Free trial button — see `canOfferTrial` for the full eligibility
            // matrix (trial not started, kill switch off, not a subscriber,
            // and the Apple ID has never subscribed before).
            if canOfferTrial {
                Button {
                    // Guest gate: trials and subscriptions must be tied to an account
                    // so they persist across devices and don't silently fail to claim.
                    if AuthManager.shared.isGuestMode {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            AuthManager.shared.guestGateReason = .subscribe
                        }
                        return
                    }
                    isStartingTrial = true
                    trialError = nil
                    Task {
                        let result = await manager.startTrialAndSync()
                        await MainActor.run {
                            isStartingTrial = false
                            switch result {
                            case .success:
                                dismiss()
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
                } label: {
                    HStack(spacing: 6) {
                        if isStartingTrial {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        }
                        Text(AppText.L("Start 7-Day Free Trial", "7일 무료 체험 시작", "开始7天免费试用"))
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.accent)
                            .shadow(color: palette.accent.opacity(0.25), radius: 8, y: 4)
                    )
                }
                .disabled(isStartingTrial)

                if let error = trialError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }

            // Subscribe / Change Plan button
            if let selected = selectedProduct {
                if isCurrentSubscriber && !isChangingPlan {
                    // Already on this plan — no action needed
                    Text(AppText.L("This is your current plan", "현재 이용 중인 플랜이에요", "这是您当前的方案"))
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                } else {
                    Button {
                        // Guest gate: purchases must be tied to an account because
                        // markCurrentUserAsSubscriptionOwner() requires a userId.
                        // Without this, a guest could complete a purchase through
                        // StoreKit but premium would never activate — a bug that
                        // previously caused App Store review rejections.
                        if AuthManager.shared.isGuestMode {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                AuthManager.shared.guestGateReason = .subscribe
                            }
                            return
                        }
                        Task { await manager.purchase(selected) }
                    } label: {
                        let isYearly = selected.id == SubscriptionManager.yearlyProductId
                        let label: String = {
                            if isChangingPlan {
                                let period = isYearly
                                    ? AppText.L("Yearly", "연간", "年付")
                                    : AppText.L("Monthly", "월간", "月付")
                                return AppText.L(
                                    "Change to \(period) — \(selected.displayPrice)",
                                    "\(period)(으)로 변경 — \(selected.displayPrice)",
                                    "更改为\(period) — \(selected.displayPrice)")
                            }
                            if canOfferTrial {
                                return AppText.L("Subscribe Now", "바로 구독하기", "立即订阅")
                            }
                            let period = isYearly
                                ? AppText.L("Yearly", "연간", "年付")
                                : AppText.L("Monthly", "월간", "月付")
                            return AppLanguage.current() == .english
                                ? "\(period) — \(selected.displayPrice)"
                                : "\(period) \(AppText.L("—", "구독 —", "订阅 —")) \(selected.displayPrice)"
                        }()

                        Text(label)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(
                                canOfferTrial
                                    ? palette.accent : .white
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(
                                        canOfferTrial
                                            ? Color.clear : palette.accent
                                    )
                                    .overlay(
                                        canOfferTrial
                                        ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(palette.accent, lineWidth: 1.5)
                                        : nil
                                    )
                            )
                    }
                    .disabled(manager.purchaseState == .purchasing)
                }
            }

            // Selected plan summary
            if let sel = selectedProduct, !isCurrentSubscriber || isChangingPlan {
                let isYearly = sel.id == SubscriptionManager.yearlyProductId
                Text(isYearly
                    ? "\(sel.displayPrice)\(AppText.L(" / year · Cancel anytime", " / 년 · 언제든 취소 가능", " / 年 · 随时可取消"))"
                    : "\(sel.displayPrice)\(AppText.L(" / month · Cancel anytime", " / 월 · 언제든 취소 가능", " / 月 · 随时可取消"))")
                    .font(.caption)
                    .foregroundStyle(palette.muted.opacity(0.7))
                    .padding(.top, 2)
            }

            if case .purchasing = manager.purchaseState {
            } else if case .purchased = manager.purchaseState {
                Text(AppText.L("Plan updated!", "플랜이 변경되었어요!", "方案已更新！"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.top, 4)
            }

            // Manage / Restore
            if isCurrentSubscriber {
                Button {
                    showManageSubscription = true
                } label: {
                    Text(AppText.L("Manage Subscription", "구독 관리", "管理订阅"))
                        .font(.subheadline)
                        .foregroundStyle(palette.accent)
                }
                .manageSubscriptionsSheet(isPresented: $showManageSubscription)
                // When the Apple-provided manage-subscription sheet closes,
                // the user may have canceled or changed plans. Force a
                // refresh so our UI (willAutoRenew, expiration date, plan id)
                // reflects the new state immediately rather than at the next
                // foreground transition.
                .onChange(of: showManageSubscription) { _, isShown in
                    if !isShown {
                        manager.refresh()
                    }
                }
                .padding(.top, 4)
            } else {
                Button {
                    // Guest gate: restore purchases claims an entitlement for the
                    // current user. Without a user account, the claim is silently
                    // dropped and premium features never unlock.
                    if AuthManager.shared.isGuestMode {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            AuthManager.shared.guestGateReason = .subscribe
                        }
                        return
                    }
                    Task { await manager.restorePurchases() }
                } label: {
                    Text(AppText.t(.premiumRestore))
                        .font(.subheadline)
                        .foregroundStyle(palette.accent)
                }
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Subscription Disclosure (Apple Guideline 3.1.2(c))
    //
    // This block explicitly surfaces ALL required subscription information
    // for the currently selected plan in one labeled place, so App Store
    // reviewers (and users) can see the title, length, price, and per-unit
    // price without having to infer anything from the plan cards above.

    private var subscriptionDisclosureSection: some View {
        Group {
            if let selected = selectedProduct {
                let isYearly = selected.id == SubscriptionManager.yearlyProductId

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppText.L("Subscription Details", "구독 정보", "订阅详情"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.text.opacity(0.85))
                        .padding(.bottom, 2)

                    disclosureRow(
                        label: AppText.L("Name", "이름", "名称"),
                        value: selected.displayName
                    )
                    disclosureRow(
                        label: AppText.L("Length", "기간", "时长"),
                        value: isYearly
                            ? AppText.L("1 year, auto-renewing", "1년, 자동 갱신", "1年，自动续订")
                            : AppText.L("1 month, auto-renewing", "1개월, 자동 갱신", "1个月，自动续订")
                    )
                    disclosureRow(
                        label: AppText.L("Price", "가격", "价格"),
                        value: isYearly
                            ? selected.displayPrice + AppText.L(" / year", " / 년", " / 年")
                            : selected.displayPrice + AppText.L(" / month", " / 월", " / 月")
                    )
                    disclosureRow(
                        label: AppText.L("Per unit", "단가", "单价"),
                        value: isYearly
                            ? AppText.L(
                                "\(yearlyPerMonthFormatted(selected)) per month (billed annually)",
                                "월 \(yearlyPerMonthFormatted(selected)) (연 단위 청구)",
                                "\(yearlyPerMonthFormatted(selected))/月（按年计费）")
                            : AppText.L(
                                "\(selected.displayPrice) per month",
                                "월 \(selected.displayPrice)",
                                "\(selected.displayPrice)/月")
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.muted.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(palette.muted.opacity(0.15), lineWidth: 1)
                        )
                )
                .padding(.bottom, 14)
            }
        }
    }

    private func disclosureRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.muted)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(palette.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Terms

    private var termsSection: some View {
        VStack(spacing: 4) {
            Text(AppText.L(
                "Payment will be charged to your Apple ID at confirmation of purchase. Subscriptions auto-renew unless canceled at least 24 hours before the end of the current period. Manage or cancel in Settings > Apple ID > Subscriptions.",
                "결제는 구매 확정 시점에 Apple ID로 청구됩니다. 구독은 현재 기간 종료 최소 24시간 전에 취소하지 않으면 자동 갱신됩니다. 설정 > Apple ID > 구독에서 관리 및 해지할 수 있습니다.",
                "付款将在确认购买时从您的 Apple ID 账户扣除。除非在当前周期结束前至少 24 小时取消，否则订阅将自动续订。可在「设置 > Apple ID > 订阅」中管理或取消。"))
                .font(.caption2)
                .foregroundStyle(palette.muted.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)

            HStack(spacing: 16) {
                Button(AppText.L("Terms of Use (EULA)", "이용약관 (EULA)", "使用条款 (EULA)")) {
                    showTermsSheet = true
                }
                Button(AppText.L("Privacy Policy", "개인정보 처리방침", "隐私政策")) {
                    showPrivacySheet = true
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(palette.accent)
        }
        .sheet(isPresented: $showTermsSheet) {
            TermsOfServiceView()
                .environmentObject(appSettings)
        }
        .sheet(isPresented: $showPrivacySheet) {
            PrivacyPolicyView()
                .environmentObject(appSettings)
        }
    }

    // MARK: - Product Load Failed

    private var productLoadFailedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(palette.muted)
            Text(AppText.L(
                "Could not load subscription options.\nPlease try again later.",
                "구독 정보를 불러오지 못했어요.\n잠시 후 다시 시도해 주세요.",
                "无法加载订阅选项。\n请稍后重试。"))
                .font(.subheadline)
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)

            // Surface the underlying error so App Review reviewers (and users)
            // can see what actually went wrong. Hidden when no error message
            // is set. Small caption size so it doesn't dominate the UI.
            if let errMsg = manager.lastProductLoadError {
                Text(errMsg)
                    .font(.caption2)
                    .foregroundStyle(palette.muted.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }

            Button {
                productLoadFailed = false
                Task {
                    await manager.loadProducts()
                    if selectedProduct == nil { selectedProduct = manager.yearlyProduct }
                    if manager.products.isEmpty { productLoadFailed = true }
                }
            } label: {
                Text(AppText.L("Try Again", "다시 시도", "重试"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Price Helpers

    /// Yearly savings percentage computed from actual StoreKit prices.
    private var yearlySavingsPercent: Int? {
        guard let monthly = manager.monthlyProduct,
              let yearly = manager.yearlyProduct else { return nil }
        let annualCost = monthly.price * 12
        guard annualCost > 0 else { return nil }
        let saved = annualCost - yearly.price
        let pct = (saved / annualCost * 100) as NSDecimalNumber
        let rounded = pct.intValue
        return rounded > 0 ? rounded : nil
    }

    /// Per-month price for the yearly plan (e.g. "$1.08").
    private func yearlyPerMonthFormatted(_ product: Product) -> String {
        let perMonth = product.price / 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = product.priceFormatStyle.currencyCode
        return formatter.string(from: perMonth as NSDecimalNumber) ?? ""
    }

    /// Annual equivalent of the monthly plan (e.g. "$23.88") for strikethrough.
    private func annualEquivalent(_ monthlyProduct: Product) -> String {
        let annual = monthlyProduct.price * 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = monthlyProduct.priceFormatStyle.currencyCode
        return formatter.string(from: annual as NSDecimalNumber) ?? ""
    }
}
