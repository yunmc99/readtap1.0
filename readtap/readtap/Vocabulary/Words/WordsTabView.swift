import SwiftUI

struct WordsTabView: View {
    @Binding var suppressRootPaging: Bool
    var isActive: Bool = true

    @EnvironmentObject private var appSettings: AppSettings
    @AppStorage("wordsDateMode") private var storedModeRaw: String = WordsDateMode.strip.rawValue

    @SceneStorage("words.selectedDayTS") private var selectedDayTS: Double = 0
    @SceneStorage("words.centerDayTS") private var centerDayTS: Double = 0
    @SceneStorage("words.monthDateTS") private var monthDateTS: Double = 0
    @SceneStorage("words.launchSessionId") private var launchSessionId: String = ""

    @State private var didHydrateState = false
    @State private var needsInitialTodayCentering = false
    @State private var mode: WordsDateMode = .strip
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var centerDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var monthDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var stripDays: [Date] = []
    @State private var dayCountCache: [String: Int] = [:]
    @State private var items: [VocabularyEntry] = []
    @State private var folders: [DayBookFolder] = []
    @State private var openRequest: OpenBookRequest?
    @State private var scrollRequestDay: Date? = nil
    @State private var isDeleteFoldersConfirmPresented = false
    @State private var pendingFolderDeleteIDs: [String] = []
    @State private var dontAskAgainToday = false
    @State private var renamingFolder: DayBookFolder?
    @State private var renameText: String = ""
    @State private var isRenamePresented = false
    @State private var openedFolder: DayBookFolder?
    @State private var stripStartedCounts: [String: Int] = [:]
    @State private var stripFinishedCounts: [String: Int] = [:]
    @State private var monthStartedCounts: [String: Int] = [:]
    @State private var monthFinishedCounts: [String: Int] = [:]
    @State private var folderSelection: Set<String> = []
    @State private var isFolderSelectionMode: Bool = false
    @State private var isBuildingStripDays: Bool = false
    @State private var isLoading: Bool = false
    @State private var reloadToken = UUID()
    @State private var stripBadgeToken = UUID()
    @State private var monthBadgeToken = UUID()
    @State private var needsReload: Bool = true
    @State private var needsStripBadges: Bool = true
    @State private var needsMonthBadges: Bool = true
    @State private var lastReloadDayKey: String?
    @State private var loadingDayKey: String?
    @State private var lastStripBadgeCenterKey: String?
    @State private var lastMonthKey: String?
    @State private var monthYearFormatter = DateFormatter()
    @Environment(\.rootTabBarHeight) private var rootTabBarHeight
    @AppStorage("skipFolderDeleteConfirmDayKey") private var skipFolderDeleteConfirmDayKey: String = ""

    private let calendar = Calendar.current
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var calendarPalette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var calendarTextColor: Color {
        calendarPalette.text
    }
    private var calendarMutedColor: Color {
        calendarPalette.muted
    }
    private var calendarAccentColor: Color {
        calendarPalette.accent
    }
    private var calendarHighlightColor: Color {
        calendarPalette.highlight
    }
    private var calendarStartedColor: Color {
        calendarPalette.started
    }
    private var calendarFinishedColor: Color {
        calendarPalette.finished
    }
    private var calendarDangerColor: Color {
        calendarPalette.danger
    }
    private var calendarDangerTextColor: Color {
        calendarPalette.dangerText
    }
    private var actionBarSurfaceColor: Color {
        colorScheme == .dark ? theme.cardSurface.opacity(0.94) : theme.cardSurface.opacity(0.95)
    }
    private var actionBarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }
    private var destructiveButtonFillColor: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.85, green: 0.22, blue: 0.22, alpha: 0.92)
                : UIColor(red: 0.82, green: 0.18, blue: 0.18, alpha: 0.94)
        })
    }
    private var destructiveButtonBorderColor: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0.40, blue: 0.40, alpha: 0.30)
                : UIColor(red: 0.70, green: 0.12, blue: 0.12, alpha: 0.25)
        })
    }
    private var destructiveButtonForegroundColor: Color {
        .white
    }
    private var destructiveButtonDisabledFillColor: Color {
        theme.cardSurface.opacity(colorScheme == .dark ? 0.72 : 0.66)
    }
    private var destructiveButtonDisabledBorderColor: Color {
        theme.cardStroke.opacity(colorScheme == .dark ? 0.78 : 0.60)
    }
    private var destructiveButtonDisabledForegroundColor: Color {
        calendarMutedColor
    }
    private var folderBookCoverColor: Color {
        colorScheme == .dark
            ? calendarAccentColor.opacity(0.68)
            : calendarAccentColor.opacity(0.58)
    }
    private var folderBookCoverSelectedColor: Color {
        colorScheme == .dark
            ? calendarStartedColor.opacity(0.86)
            : calendarStartedColor.opacity(0.72)
    }
    private var folderBookPageColor: Color {
        calendarPalette.startedBadgePage
    }
    private var folderCountTextColor: Color {
        colorScheme == .dark
            ? calendarPalette.text.opacity(0.98)
            : calendarTextColor
    }
    private var folderCountBadgeColor: Color {
        theme.cardSurface.opacity(colorScheme == .dark ? 0.74 : 0.72)
    }
    private var stripStepAnimation: Animation {
        // Smooth snap without noticeable bounce (reduces "stuttery" feel).
        .smooth(duration: 0.32, extraBounce: 0.0)
    }
    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            if isFolderSelectionMode {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        endFolderSelection()
                    }
            }

            VStack(spacing: DSLayout.isPad ? 10 : 6) {
                headerBar
                if mode == .strip {
                    weekStrip
                } else {
                    monthCalendar
                }
                legendRow
                contentList
            }
            .frame(maxWidth: DSLayout.isPad ? 680 : .infinity)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)

            if isDeleteFoldersConfirmPresented {
                theme.background
                    .opacity(colorScheme == .dark ? 0.58 : 0.46)
                    .ignoresSafeArea()
                    .onTapGesture { cancelDeleteFolderSelection() }
                    .zIndex(3)

                WordsTabDeleteFolderConfirmView(
                    dontAskAgainToday: $dontAskAgainToday,
                    folderCount: pendingFolderDeleteIDs.count,
                    onDelete: { confirmDeleteSelectedFolders() },
                    onCancel: { cancelDeleteFolderSelection() }
                )
                .frame(maxWidth: 340)
                .padding(.horizontal, 20)
                .zIndex(4)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $openRequest) { req in
            ReaderView(documentURL: req.fileURL, bookId: req.bookId, bookTitle: req.bookTitle, openPageIndex: req.pageIndex)
                .ignoresSafeArea()
        }
        .sheet(item: $openedFolder) { folder in
            NavigationStack {
                DayBookWordsView(
                    title: folder.title,
                    items: folder.items,
                    suppressRootPaging: $suppressRootPaging,
                    onOpenInBook: { req in
                        openRequest = req
                    }
                )
            }
        }
        .alert(renameTitle, isPresented: $isRenamePresented) {
            TextField(renamePlaceholder, text: $renameText)
            Button(AppText.t(.cancel), role: .cancel) {
                renamingFolder = nil
                renameText = ""
            }
            Button(renameSaveLabel) {
                let target = renamingFolder
                renamingFolder = nil
                renameText = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                let newTitle = renameText
                renameText = ""
                guard let folder = target else { return }
                renameBook(bookId: folder.bookId, newTitle: newTitle) {
                    applyRenamedTitle(bookId: folder.bookId, newTitle: newTitle)
                }
            }
        } message: {
            Text(renameMessage)
        }
        .onAppear {
                configureMonthYearFormatter()
                if !didHydrateState {
                    didHydrateState = true
                    mode = WordsDateMode(rawValue: storedModeRaw) ?? .strip

                    if selectedDayTS > 0 {
                        selectedDay = calendar.startOfDay(for: Date(timeIntervalSince1970: selectedDayTS))
                    } else {
                        let today = calendar.startOfDay(for: Date())
                        selectedDay = today
                        needsInitialTodayCentering = true
                    }

                    if monthDateTS > 0 {
                        monthDate = calendar.startOfDay(for: Date(timeIntervalSince1970: monthDateTS))
                    } else {
                        monthDate = selectedDay
                    }

                    if centerDayTS > 0 {
                        centerDay = calendar.startOfDay(for: Date(timeIntervalSince1970: centerDayTS))
                    } else if mode == .strip {
                        centerDay = selectedDay
                    }
                }

                if launchSessionId != AppWarmup.shared.sessionId {
                    // After a cold app launch, always start the Words tab on "today"
                    // (ignore the last restored day) so the strip/calendar feels predictable.
                    let today = calendar.startOfDay(for: Date())
                    selectedDay = today
                    centerDay = today
                    monthDate = today
                    scrollRequestDay = today
                    needsInitialTodayCentering = false
                    needsReload = true
                    needsStripBadges = true
                    needsMonthBadges = true
                    launchSessionId = AppWarmup.shared.sessionId
                }

                buildStripDaysIfNeeded()
                if isActive {
                    activateIfNeeded()
                }

                if needsInitialTodayCentering, mode == .strip {
                    let today = calendar.startOfDay(for: Date())
                    centerDay = today
                    scrollRequestDay = today
                    needsInitialTodayCentering = false
                }
            }
            .onChange(of: mode) { _, newValue in
                storedModeRaw = newValue.rawValue
            }
            .onChange(of: selectedDay) { _, newValue in
                needsReload = true
                if isActive { activateIfNeeded() }
                monthDate = newValue
                selectedDayTS = calendar.startOfDay(for: newValue).timeIntervalSince1970
            }
            .onChange(of: monthDate) { _, newValue in
                needsMonthBadges = true
                if isActive { activateIfNeeded() }
                monthDateTS = calendar.startOfDay(for: newValue).timeIntervalSince1970
            }
            .onChange(of: centerDay) { _, newValue in
                if let newValue {
                    let day = calendar.startOfDay(for: newValue)
                    if selectedDay != day {
                        selectedDay = day
                    }
                    needsStripBadges = true
                    if isActive { activateIfNeeded() }
                    centerDayTS = day.timeIntervalSince1970
                } else {
                    centerDayTS = 0
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readingStatusDidChange)) { _ in
                needsStripBadges = true
                needsMonthBadges = true
                needsReload = true
                if isActive { activateIfNeeded() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vocabularyDidChange)) { _ in
                dayCountCache.removeAll()
                needsReload = true
                if isActive { activateIfNeeded() }
            }
            .onChange(of: appSettings.language) { _, _ in
                configureMonthYearFormatter()
            }
            .onChange(of: isActive) { _, newValue in
                if !newValue {
                    if suppressRootPaging { suppressRootPaging = false }
                    return
                }
                activateIfNeeded()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isFolderSelectionMode {
                    folderSelectionActionBar
                        .padding(.bottom, folderSelectionBottomPad)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isFolderSelectionMode)
            .animation(.easeInOut(duration: 0.18), value: isDeleteFoldersConfirmPresented)
    }

    private func configureMonthYearFormatter() {
        let language = appSettings.language
        monthYearFormatter.calendar = calendar
        switch language {
        case .korean:
            monthYearFormatter.locale = Locale(identifier: "ko_KR")
            monthYearFormatter.dateFormat = "yyyy년 M월"
        case .chinese:
            monthYearFormatter.locale = Locale(identifier: "zh_CN")
            monthYearFormatter.dateFormat = "yyyy年M月"
        case .english:
            monthYearFormatter.locale = Locale(identifier: "en_US")
            monthYearFormatter.dateFormat = "MMMM yyyy"
        case .system:
            monthYearFormatter.locale = Locale.current
            monthYearFormatter.dateFormat = "MMMM yyyy"
        }
    }

    private func monthKey(for month: Date) -> String {
        let comps = calendar.dateComponents([.year, .month], from: month)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }

    private func activateIfNeeded() {
        guard isActive else { return }

        let dayKey = StreakStore.dayKey(selectedDay)
        if (needsReload || lastReloadDayKey != dayKey), loadingDayKey != dayKey {
            reload()
        }

        let around = calendar.startOfDay(for: centerDay ?? selectedDay)
        let centerKey = StreakStore.dayKey(around)
        if needsStripBadges || lastStripBadgeCenterKey != centerKey {
            refreshStripBadges(around: around)
        }

        let mKey = monthKey(for: monthDate)
        if needsMonthBadges || lastMonthKey != mKey {
            refreshMonthBadges(for: monthDate)
        }
    }

    private var headerBar: some View {
        let pad = DSLayout.isPad
        let leftControlWidth: CGFloat = pad ? 52 : 44
        let rightControlWidth: CGFloat = pad ? 88 : 72

        return ZStack(alignment: .center) {
            HStack(spacing: 10) {
                Button {
                    toggleMode()
                } label: {
                    Image(systemName: mode == .strip ? "calendar" : "list.bullet")
                        .font(.system(size: DSLayout.sectionSubheadSize, weight: .semibold))
                        .foregroundStyle(calendarTextColor)
                        .padding(pad ? 11 : 9)
                        .background(
                            Circle()
                                .fill(theme.cardSurface.opacity(0.9))
                        )
                        .overlay(
                            Circle().stroke(theme.cardStroke, lineWidth: 0.8)
                        )
                }
                .frame(width: leftControlWidth, alignment: .leading)
                .buttonStyle(.plain)
                .accessibilityLabel(mode == .strip ? AppText.t(.calendar) : modeStripTitle)

                Spacer(minLength: 8)

                Button {
                    let today = calendar.startOfDay(for: Date())
                    scrollRequestDay = today
                    centerDay = today
                    monthDate = today
                    selectedDay = today
                } label: {
                    Text(AppText.t(.today))
                        .font(.system(size: DSLayout.chipFontSize, weight: .semibold))
                        .foregroundStyle(calendarTextColor)
                        .padding(.horizontal, DSLayout.chipHPadding)
                        .padding(.vertical, DSLayout.chipVPadding)
                        .background(
                            Capsule()
                                .fill(theme.cardSurface)
                        )
                        .overlay(
                            Capsule().stroke(theme.cardStroke, lineWidth: 0.8)
                        )
                }
                .frame(width: rightControlWidth, alignment: .trailing)
                .buttonStyle(.plain)
            }

            Text(monthYearTitle)
                .font(.system(size: DSLayout.calendarTitleSize, weight: .semibold))
                .foregroundStyle(calendarTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, max(leftControlWidth, rightControlWidth))
        }
        .padding(.horizontal, DSLayout.listCardPadding + 2)
        .padding(.top, DSLayout.isPad ? 12 : 10)
        .padding(.bottom, DSLayout.isPad ? 8 : 6)
        .background(
            RoundedRectangle(cornerRadius: DSLayout.calendarCornerRadius, style: .continuous)
                .fill(theme.cardSurface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: DSLayout.calendarCornerRadius, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 0.8)
                )
        )
    }

    @ViewBuilder
    private var folderSelectionActionBar: some View {
        if isFolderSelectionMode {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderSelectionCountLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(calendarTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(folderDeleteHint)
                        .font(.caption)
                        .foregroundStyle(calendarMutedColor)
                }

                Spacer(minLength: 8)

                let deleteEnabled = folderSelection.isEmpty == false
                let folderDeleteFill: Color = deleteEnabled ? destructiveButtonFillColor : destructiveButtonDisabledFillColor
                let folderDeleteForeground: Color = deleteEnabled ? destructiveButtonForegroundColor : destructiveButtonDisabledForegroundColor
                let folderDeleteBorder: Color = deleteEnabled ? destructiveButtonBorderColor : destructiveButtonDisabledBorderColor
                Button(role: .destructive) {
                    beginDelete(Array(folderSelection))
                } label: {
                    Label(AppText.t(.delete), systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(folderDeleteForeground)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(folderDeleteFill)
                        .overlay(
                            Capsule().stroke(
                                folderDeleteBorder,
                                lineWidth: 1
                            )
                        )
                )
                .disabled(!deleteEnabled)
                .opacity(deleteEnabled ? 1 : 0.45)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(actionBarSurfaceColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(actionBarStrokeColor, lineWidth: 1)
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.2)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var modeStripTitle: String { AppText.t(.modeStripTitle) }

    private var folderSelectionBottomPad: CGFloat {
        let minimumReserved: CGFloat = 84
        let measured = rootTabBarHeight > 0 ? rootTabBarHeight : minimumReserved
        return max(minimumReserved, measured) + 4
    }

    private var folderDeleteHint: String {
        AppText.t(.folderDeleteHint)
    }

    private var folderSelectionCountLabel: String {
        let count = folderSelection.count
        return AppText.L("\(count) \(AppText.t(.selectedCount))", "\(count)\(AppText.t(.selectedCount))", "\(count)\(AppText.t(.selectedCount))")
    }

    private func toggleMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
            mode = (mode == .strip) ? .calendar : .strip
        }
        storedModeRaw = mode.rawValue
        if mode == .strip {
            let day = calendar.startOfDay(for: selectedDay)
            scrollRequestDay = day
            centerDay = day
        }
    }

    private func stripPill(for day: Date, using proxy: ScrollViewProxy, pillWidth: CGFloat = 72) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let key = StreakStore.dayKey(day)
        let didMeetGoal = isActive ? goalMet(day) : false
        let count = isActive ? countForDay(day) : 0
        let startedCount = isActive ? (stripStartedCounts[key] ?? 0) : 0
        let finishedCount = isActive ? (stripFinishedCounts[key] ?? 0) : 0
        let dayStart = calendar.startOfDay(for: day)
        let onTap = {
            centerDay = dayStart
            withAnimation(stripStepAnimation) { proxy.scrollTo(dayStart, anchor: .center) }
        }
        return DatePill(
            date: day,
            isSelected: isSelected,
            isDisabled: false,
            count: count,
            didMeetGoal: didMeetGoal,
            startedCount: startedCount,
            finishedCount: finishedCount
        ) { onTap() }
        .frame(width: pillWidth)
        .id(dayStart)
    }

    private var weekStrip: some View {
        ScrollViewReader { proxy in
            GeometryReader { geo in
                let pad = DSLayout.isPad
                let hPad: CGFloat = pad ? 16 : 8
                let spacing: CGFloat = pad ? 6 : 10
                let availableWidth = geo.size.width - hPad * 2
                // iPad: calculate pill width so exactly 7 fit the available width
                let pillWidth: CGFloat = pad ? max(60, (availableWidth - spacing * 6) / 7) : DSLayout.weekStripPillWidth

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(stripDays, id: \.self) { day in
                            stripPill(for: day, using: proxy, pillWidth: pillWidth)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 8)
                }
                .scrollDisabled(true)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            }
            .frame(height: DSLayout.weekStripHeight)
            .padding(.horizontal, DSLayout.isPad ? 16 : 12)
            .padding(.top, 2)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        let threshold: CGFloat = 30
                        let dx = value.predictedEndTranslation.width
                        let step: Int
                        if dx > threshold {
                            step = -1
                        } else if dx < -threshold {
                            step = 1
                        } else {
                            return
                        }

                        let current = calendar.startOfDay(for: centerDay ?? selectedDay)
                        guard let currentIndex = stripDays.firstIndex(where: { calendar.isDate($0, inSameDayAs: current) }) else {
                            return
                        }
                        guard !stripDays.isEmpty else { return }
                        let newIndex = min(max(currentIndex + step, 0), stripDays.count - 1)
                        let newDay = calendar.startOfDay(for: stripDays[newIndex])
                        centerDay = newDay
                        withAnimation(stripStepAnimation) { proxy.scrollTo(newDay, anchor: .center) }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !suppressRootPaging { suppressRootPaging = true }
                    }
                    .onEnded { _ in
                        if suppressRootPaging { suppressRootPaging = false }
                    }
            )
            .onAppear {
                let target = calendar.startOfDay(for: centerDay ?? selectedDay)
                if stripDays.contains(where: { calendar.isDate($0, inSameDayAs: target) }) {
                    DispatchQueue.main.async {
                        // When the strip is created (e.g. switching calendar <-> strip),
                        // avoid animating a potentially huge scroll distance (it looks like it "keeps rolling").
                        withAnimation(.none) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                } else if stripDays.isEmpty {
                    // If stripDays hasn't finished building yet, keep a pending request so we can
                    // center once days arrive.
                    scrollRequestDay = target
                }
            }
            .onChange(of: scrollRequestDay) { _, newValue in
                guard let newValue else { return }
                let day = calendar.startOfDay(for: newValue)
                if stripDays.contains(where: { calendar.isDate($0, inSameDayAs: day) }) {
                    DispatchQueue.main.async {
                        // Programmatic scroll requests (Today button / mode switch) should jump instantly.
                        withAnimation(.none) {
                            proxy.scrollTo(day, anchor: .center)
                        }
                        scrollRequestDay = nil
                    }
                } else if stripDays.isEmpty {
                    // Keep the request; we'll retry once stripDays is available.
                } else {
                    scrollRequestDay = nil
                }
            }
            .onChange(of: stripDays.count) { _, newCount in
                guard newCount > 0 else { return }
                guard let requested = scrollRequestDay else { return }
                let day = calendar.startOfDay(for: requested)
                guard stripDays.contains(where: { calendar.isDate($0, inSameDayAs: day) }) else { return }
                DispatchQueue.main.async {
                    withAnimation(.none) {
                        proxy.scrollTo(day, anchor: .center)
                    }
                    scrollRequestDay = nil
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardSurface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var monthCalendar: some View {
        WordsMonthCalendarView(
            monthDate: $monthDate,
            selectedDay: $selectedDay,
            startedCounts: monthStartedCounts,
            finishedCounts: monthFinishedCounts,
            goalMet: goalMet
        )
            .padding(.horizontal, 12)
            .padding(.top, 2)
    }

    private var legendRow: some View {
        let pad = DSLayout.isPad
        return HStack(spacing: pad ? 10 : 8) {
            // "Goal met" badge logic adapted to look exactly like the small capsules
            HStack(spacing: pad ? 5 : 4) {
                Circle()
                    .fill(calendarHighlightColor)
                    .frame(width: pad ? 9 : 8, height: pad ? 9 : 8)
                Text(legendGoalText)
                    .font(.system(size: DSLayout.smallBadgeLabelSize, weight: .semibold))
            }
            .foregroundStyle(calendarTextColor.opacity(0.8))
            .padding(.horizontal, pad ? 10 : 8)
            .padding(.vertical, pad ? 5 : 4)
            .background(
                Capsule()
                    .fill(calendarHighlightColor.opacity(0.12))
            )

            SmallBadge(kind: .started, count: 1)
            SmallBadge(kind: .finished, count: 1)

            Spacer()
        }
        .padding(.horizontal, DSLayout.screenHorizontal)
        .padding(.top, mode == .calendar ? 4 : 2)
        .padding(.bottom, 4)
    }

    private var legendGoalText: String { AppText.t(.legendGoalText) }

    private var legendStartedText: String { AppText.t(.legendStartedText) }

    private var legendFinishedText: String { AppText.t(.legendFinished) }

    private var contentList: some View {
        List {
            if folders.isEmpty {
                HStack {
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(AppText.t(.noWordsTitle))
                            .foregroundStyle(calendarMutedColor)
                    }
                    Spacer()
                }
                .padding(.vertical, 28)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(folders) { folder in
                    folderRow(for: folder)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: DSLayout.isPad ? 8 : 5, leading: DSLayout.isPad ? 20 : 12, bottom: DSLayout.isPad ? 8 : 5, trailing: DSLayout.isPad ? 20 : 12))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func folderRow(for folder: DayBookFolder) -> some View {
        let isSelected = folderSelection.contains(folder.id)
        
        let rowContent = HStack(spacing: DSLayout.isPad ? 16 : 12) {
            if isFolderSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isSelected ? calendarAccentColor : calendarMutedColor.opacity(0.35))
                    .font(.system(size: 22))
                    .frame(width: 26)
                    .transition(.scale.combined(with: .opacity))
                }
                
                // Book cover thumbnail
                BookCoverThumbnail(coverPath: folder.coverPath)
                
                VStack(alignment: .leading, spacing: 5) {
                    Text(folder.title)
                        .font(.system(size: DSLayout.sectionSubheadSize, weight: .semibold))
                        .foregroundStyle(calendarTextColor)
                        .lineLimit(1)

                    if !folder.subtitle.isEmpty {
                        Text(folder.subtitle)
                            .font(.system(size: DSLayout.listCaptionSize))
                            .foregroundStyle(calendarMutedColor)
                            .lineLimit(1)
                    }

                    if folder.totalCount > 0 {
                        let total = CGFloat(folder.totalCount)
                        let ratio = total > 0 ? CGFloat(folder.knownCount) / total : 0

                        VStack(alignment: .leading, spacing: 3) {
                            MasteryProgressBar(knownRatio: ratio)

                            Text(folder.masterySummaryText)
                                .font(.system(size: DSLayout.listBadgeSize))
                                .foregroundStyle(calendarMutedColor)
                                .lineLimit(1)
                        }
                    }
                }
                
                Spacer(minLength: 4)

                WordCountBadge(count: folder.items.count)
                
                HStack(spacing: 4) {
                    if folder.didStartOnSelectedDay {
                        SmallBadge(kind: SmallBadgeKind.started, count: 1)
                    }
                    if folder.didFinishOnSelectedDay {
                        SmallBadge(kind: SmallBadgeKind.finished, count: 1)
                    }
                }

                if !isFolderSelectionMode {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DSLayout.chevronSize, weight: .semibold))
                        .foregroundStyle(theme.cardStroke.opacity(0.8))
                        .padding(.leading, 2)
                }
            }
        let content = rowContent
            .padding(.vertical, DSLayout.isPad ? 14 : 12)
            .padding(.horizontal, DSLayout.isPad ? 14 : 12)
            .background(
                RoundedRectangle(cornerRadius: DSLayout.isPad ? 16 : 14, style: .continuous)
                    .fill(theme.cardSurface.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: DSLayout.isPad ? 16 : 14, style: .continuous)
                            .stroke(
                                isFolderSelectionMode && isSelected ? calendarAccentColor : theme.cardStroke,
                                lineWidth: isFolderSelectionMode && isSelected ? 2 : 1
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 16 : 14, style: .continuous))

        Group {
            if isFolderSelectionMode {
                Button {
                    toggleFolderSelection(folder.id)
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
                    .onTapGesture {
                        openBooks(for: folder)
                    }
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                            // Defer to the next run loop so the gesture completes
                            // before the view hierarchy swaps.
                            DispatchQueue.main.async {
                                startFolderSelection(with: folder.id)
                            }
                        }
                    )
            }
        }
    }

    private func startFolderSelection(with id: String) {
        isFolderSelectionMode = true
        folderSelection = [id]
    }

    private func openBooks(for folder: DayBookFolder) {
        openedFolder = folder
    }

    private func toggleFolderSelection(_ id: String) {
        if folderSelection.contains(id) {
            folderSelection.remove(id)
            if folderSelection.isEmpty {
                isFolderSelectionMode = false
            }
        } else {
            folderSelection.insert(id)
        }
    }

    private func endFolderSelection() {
        isFolderSelectionMode = false
        folderSelection.removeAll()
    }

    private func beginDelete(_ ids: [String]) {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return }
        pendingFolderDeleteIDs = uniqueIDs
        dontAskAgainToday = false
        if shouldSkipDeleteConfirmToday() {
            confirmDeleteSelectedFolders()
        } else {
            isDeleteFoldersConfirmPresented = true
        }
    }

    private func confirmDeleteSelectedFolders() {
        guard !pendingFolderDeleteIDs.isEmpty else { return }
        if dontAskAgainToday {
            skipFolderDeleteConfirmDayKey = StreakStore.dayKey(Date())
        }

        let targetIDs = Set(pendingFolderDeleteIDs)
        let selectedFolders = folders.filter { targetIDs.contains($0.id) }
        let processedIDs = Set(selectedFolders.map(\.id))
        let unresolvedIDs = targetIDs.subtracting(processedIDs)

        for folder in selectedFolders {
            VocabularyStore.shared.deleteByBookId(folder.bookId)
            let itemIds = folder.items.map(\.id)
            if !itemIds.isEmpty {
                VocabularyStore.shared.delete(ids: itemIds)
            }
            resetReadingStartIfNeeded(bookId: folder.bookId, deletedDay: nil)
        }

        for folderID in unresolvedIDs {
            let bookId = folderID == "unknown" ? "" : folderID
            VocabularyStore.shared.deleteByBookId(bookId)
            resetReadingStartIfNeeded(bookId: bookId, deletedDay: nil)
        }

        pendingFolderDeleteIDs.removeAll()
        isDeleteFoldersConfirmPresented = false
        endFolderSelection()
        reload()
    }

    private func cancelDeleteFolderSelection() {
        pendingFolderDeleteIDs.removeAll()
        isDeleteFoldersConfirmPresented = false
    }

    private func shouldSkipDeleteConfirmToday() -> Bool {
        skipFolderDeleteConfirmDayKey == StreakStore.dayKey(Date())
    }

    private func reload() {
        let token = UUID()
        reloadToken = token
        isLoading = true

        let day = selectedDay
        let dayKey = StreakStore.dayKey(day)
        loadingDayKey = dayKey
        DispatchQueue.global(qos: .userInitiated).async {
            let fetched = VocabularyStore.shared.fetchForDay(day, limit: 2000)
            let filtered = fetched.filter { $0.masteryState != MasteryState.known.rawValue }
            let built = makeFolders(from: filtered, on: day)
            DispatchQueue.main.async {
                guard reloadToken == token else { return }
                items = filtered
                folders = built
                isLoading = false
                loadingDayKey = nil
                needsReload = false
                lastReloadDayKey = StreakStore.dayKey(day)
            }
        }
    }

    private func buildStripDaysIfNeeded() {
        if !stripDays.isEmpty || isBuildingStripDays { return }
        isBuildingStripDays = true

        let today = calendar.startOfDay(for: Date())
        // Ensure the strip always has some room to scroll before today so "today" can be centered.
        let defaultPastStart = calendar.date(byAdding: .day, value: -120, to: today) ?? today
        let firstBookAddedAt = readFirstBookAddedAt()
        let startCandidate = min(firstBookAddedAt ?? today, defaultPastStart)
        let start = calendar.startOfDay(for: startCandidate)
        let futureEnd = calendar.date(byAdding: .day, value: 180, to: today) ?? today

        DispatchQueue.global(qos: .utility).async {
            var days: [Date] = []
            var cursor = start
            var guardCounter = 0
            while cursor <= futureEnd, guardCounter < 3000 {
                days.append(cursor)
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
                guardCounter += 1
            }
            DispatchQueue.main.async {
                if stripDays.isEmpty {
                    stripDays = days
                }
                if mode == .strip {
                    // Ensure we center correctly even if the first scroll request fired
                    // before stripDays was ready.
                    scrollRequestDay = calendar.startOfDay(for: centerDay ?? selectedDay)
                }
                isBuildingStripDays = false
            }
        }
    }

    private func readFirstBookAddedAt() -> Date? {
        let key = "firstBookAddedAt"
        if UserDefaults.standard.object(forKey: key) == nil { return nil }
        let ts = UserDefaults.standard.double(forKey: key)
        if ts <= 0 { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func countForDay(_ day: Date) -> Int {
        let key = StreakStore.dayKey(day)
        return dayCountCache[key] ?? 0
    }

    private func refreshStripBadges(around day: Date) {
        let token = UUID()
        stripBadgeToken = token
        let around = calendar.startOfDay(for: day)

        Task(priority: .utility) {
            guard let start = calendar.date(byAdding: .day, value: -60, to: around),
                  let end = calendar.date(byAdding: .day, value: 61, to: around) else {
                return
            }
            let started = await MainActor.run { BookReadingStatusStore.shared.startedCountsByDayKey(from: start, to: end) }
            let finished = await MainActor.run { BookReadingStatusStore.shared.finishedCountsByDayKey(from: start, to: end) }
            let counts = VocabularyStore.shared.fetchCountsByDayKey(from: start, to: end)

            await MainActor.run {
                guard stripBadgeToken == token else { return }
                stripStartedCounts = started
                stripFinishedCounts = finished
                dayCountCache = counts
                needsStripBadges = false
                lastStripBadgeCenterKey = StreakStore.dayKey(around)
            }
        }
    }

    private func refreshMonthBadges(for month: Date) {
        let token = UUID()
        monthBadgeToken = token
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? startOfMonth
        let mKey = monthKey(for: startOfMonth)

        Task(priority: .utility) {
            let started = await MainActor.run { BookReadingStatusStore.shared.startedCountsByDayKey(from: startOfMonth, to: endOfMonth) }
            let finished = await MainActor.run { BookReadingStatusStore.shared.finishedCountsByDayKey(from: startOfMonth, to: endOfMonth) }

            await MainActor.run {
                guard monthBadgeToken == token else { return }
                monthStartedCounts = started
                monthFinishedCounts = finished
                needsMonthBadges = false
                lastMonthKey = mKey
            }
        }
    }

    private func goalMet(_ day: Date) -> Bool {
        BookReadingStatusStore.shared.didMeetDailyGoal(on: day)
    }

    private var monthYearTitle: String {
        let base = (mode == .strip ? (centerDay ?? selectedDay) : monthDate)
        return monthYearFormatter.string(from: base)
    }

    private func makeFolders(from items: [VocabularyEntry], on day: Date) -> [DayBookFolder] {
        let grouped = Dictionary(grouping: items) { entry in
            entry.bookId ?? ""
        }

        let ids = grouped.keys.filter { !$0.isEmpty }
        let titlesById = BooksStore.shared.titles(forBookIds: ids)

        var result: [DayBookFolder] = []
        for (bookId, values) in grouped {
            let title: String
            if bookId.isEmpty {
                title = "Unknown"
            } else {
                title = titlesById[bookId] ?? "Unknown Book"
            }

            let latest = values.first?.createdAt ?? day
            var unknownCount = 0
            var knownCount = 0
            for entry in values {
                if entry.masteryState == MasteryState.known.rawValue {
                    knownCount += 1
                } else if entry.masteryState == MasteryState.none.rawValue || entry.masteryState == MasteryState.unknown.rawValue {
                    unknownCount += 1
                }
            }

            let (didStart, didFinish) = readingMarkers(bookId: bookId, on: day)
            let coverPath = bookId.isEmpty ? nil : BookStore.shared.coverImagePath(forBookId: bookId)

            result.append(DayBookFolder(
                bookId: bookId,
                title: title,
                latestAt: latest,
                items: values,
                unknownCount: unknownCount,
                knownCount: knownCount,
                didStartOnSelectedDay: didStart,
                didFinishOnSelectedDay: didFinish,
                coverPath: coverPath
            ))
        }
        result.sort { $0.latestAt > $1.latestAt }
        return result
    }

    private func readingMarkers(bookId: String, on day: Date) -> (Bool, Bool) {
        guard !bookId.isEmpty else { return (false, false) }
        let target = calendar.startOfDay(for: day)
        let started = BookReadingStatusStore.shared.startedAt(bookId: bookId).map { calendar.startOfDay(for: $0) == target } ?? false
        let finished = BookReadingStatusStore.shared.finishedAt(bookId: bookId).map { calendar.startOfDay(for: $0) == target } ?? false
        return (started, finished)
    }

    private func resetReadingStartIfNeeded(bookId: String, deletedDay: Date?) {
        guard !bookId.isEmpty else { return }
        guard let deletedDay else {
            BookReadingStatusStore.shared.resetStarted(bookId: bookId)
            return
        }
        guard let startedAt = BookReadingStatusStore.shared.startedAt(bookId: bookId) else { return }

        let targetDay = calendar.startOfDay(for: deletedDay)
        let startedDay = calendar.startOfDay(for: startedAt)
        guard targetDay == startedDay else { return }

        // After deleting the first-day vocabulary, check if any entries remain for that day.
        if let earliest = VocabularyStore.shared.earliestCreatedAt(forBookId: bookId) {
            let earliestDay = calendar.startOfDay(for: earliest)
            guard earliestDay == startedDay else {
                BookReadingStatusStore.shared.resetStarted(bookId: bookId)
                return
            }
            return
        }

        // No vocabulary remains for this book; clear the reading start.
        BookReadingStatusStore.shared.resetStarted(bookId: bookId)
    }

    private func beginRename(_ folder: DayBookFolder) {
        guard !folder.bookId.isEmpty else { return }
        renamingFolder = folder
        renameText = folder.title
        isRenamePresented = true
    }

    private func applyRenamedTitle(bookId: String, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = folders.firstIndex(where: { $0.bookId == bookId }) {
            var updated = folders[index]
            updated.title = trimmed
            folders[index] = updated
        }
    }

    private func renameBook(bookId: String, newTitle: String, completion: (() -> Void)? = nil) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let record = BooksStore.shared.record(forId: bookId) else {
                DispatchQueue.main.async { completion?() }
                return
            }
            BooksStore.shared.updateTitleAndPath(id: record.id, title: trimmed, filePath: record.filePath)
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    // No longer used: file path stays stable on rename to avoid blocking I/O during UI interactions.

    private var renameTitle: String { AppText.t(.rename) }

    private var renameMessage: String { AppText.t(.renameMessage) }

    private var renamePlaceholder: String { AppText.t(.renamePlaceholder) }

    private var renameSaveLabel: String { AppText.t(.save) }

    private var renameLabel: String { AppText.t(.rename) }
}

private enum WordsDateMode: String {
    case strip
    case calendar
}

private struct WordsMonthCalendarView: View {
    @Binding var monthDate: Date
    @Binding var selectedDay: Date
    let startedCounts: [String: Int]
    let finishedCounts: [String: Int]
    let goalMet: (Date) -> Bool

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private let calendar = Calendar.current
    private var textColor: Color { palette.text }
    private var mutedColor: Color { palette.muted }
    private var offMonthColor: Color { palette.offMonth }
    private var accentColor: Color { palette.accent }
    private var highlightColor: Color { palette.highlight }
    private var selectedBg: Color { highlightColor.opacity(0.16) }
    private var todayRingColor: Color {
        palette.todayRing
    }
    private var inactiveCellBg: Color { theme.cardSurface.opacity(colorScheme == .dark ? 0.24 : 0.18) }
    private var startedBadgePageColor: Color {
        palette.startedBadgePage
    }
    private var monthLocale: Locale { AppLanguage.current().locale }

    var body: some View {
        VStack(spacing: DSLayout.calendarPadding) {
            header
            weekdayRow
            grid
        }
        .padding(DSLayout.calendarPadding)
        .background(
            RoundedRectangle(cornerRadius: DSLayout.calendarCornerRadius, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: DSLayout.calendarCornerRadius, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack {
            Button {
                monthDate = calendar.date(byAdding: .month, value: -1, to: monthDate) ?? monthDate
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(textColor)
                    .frame(width: DSLayout.calendarNavButton, height: DSLayout.calendarNavButton)
                    .background(
                        RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                            .fill(theme.cardSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                                    .stroke(theme.cardStroke, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)

            Spacer()

                Text(monthTitle)
                    .font(.system(size: DSLayout.calendarTitleSize, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

            Spacer()

            Button {
                monthDate = calendar.date(byAdding: .month, value: 1, to: monthDate) ?? monthDate
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(textColor)
                    .frame(width: DSLayout.calendarNavButton, height: DSLayout.calendarNavButton)
                    .background(
                        RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                            .fill(theme.cardSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                                    .stroke(theme.cardStroke, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var weekdayRow: some View {
        let symbols = weekdaySymbols
        return HStack {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(mutedColor)
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
            }
        }
    }

    private var grid: some View {
        let days = gridDays
        let today = calendar.startOfDay(for: Date())
        let selected = calendar.startOfDay(for: selectedDay)

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DSLayout.calendarGridSpacing), count: 7), spacing: DSLayout.calendarGridSpacing) {
            ForEach(days, id: \.self) { date in
                let inMonth = calendar.isDate(date, equalTo: monthDate, toGranularity: .month)
                let isSelected = calendar.isDate(date, inSameDayAs: selected)
                let isToday = calendar.isDate(date, inSameDayAs: today)
                let metGoal = inMonth && goalMet(date)
                let key = StreakStore.dayKey(date)
                let startedCount = startedCounts[key] ?? 0
                let finishedCount = finishedCounts[key] ?? 0
                let weekday = calendar.component(.weekday, from: date)
                let isWeekend = weekday == 1 || weekday == 7
                let isFuture = date > today
                let cellTextColor = inMonth
                    ? (isSelected
                        ? textColor
                        : (isToday ? textColor : (isWeekend ? mutedColor : textColor.opacity(0.92))))
                    : offMonthColor
                let baseCellColor = inMonth
                    ? (isSelected
                        ? selectedBg
                        : isToday
                        ? highlightColor.opacity(0.10)
                        : (isFuture ? inactiveCellBg.opacity(0.85) : Color.clear))
                    : inactiveCellBg
                let borderColor = isSelected
                    ? theme.cardStroke.opacity(0.55)
                    : (isToday && isSelected == false ? todayRingColor.opacity(0.45) : Color.clear)

                Button {
                    selectedDay = calendar.startOfDay(for: date)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: DSLayout.isPad ? 13 : 11, style: .continuous)
                            .fill(baseCellColor)

                        if metGoal {
                            Circle()
                                .fill(highlightColor.opacity(0.22))
                                .frame(width: DSLayout.calendarGoalCircle, height: DSLayout.calendarGoalCircle)
                            Circle()
                                .fill(highlightColor)
                                .frame(width: DSLayout.calendarGoalDot, height: DSLayout.calendarGoalDot)
                                .offset(x: DSLayout.isPad ? 12 : 10, y: DSLayout.isPad ? 12 : 10)
                        }

                        if startedCount > 0 && inMonth {
                            startedBadge(count: startedCount)
                                .offset(x: DSLayout.isPad ? 12 : 10, y: DSLayout.isPad ? -12 : -10)
                        }
                        if finishedCount > 0 && inMonth {
                            finishedBadge(count: finishedCount)
                                .offset(x: DSLayout.isPad ? 12 : 10, y: DSLayout.isPad ? 12 : 10)
                        }

                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: DSLayout.calendarDaySize, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(cellTextColor)

                        if isToday && inMonth {
                            Circle()
                                .stroke(todayRingColor, lineWidth: 1.5)
                                .frame(width: DSLayout.calendarTodayRing, height: DSLayout.calendarTodayRing)
                        }
                    }
                            .frame(height: DSLayout.calendarCellHeight)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSLayout.isPad ? 13 : 11, style: .continuous)
                            .stroke(borderColor, lineWidth: isSelected ? 1 : 1.1)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!inMonth)
            }
        }
    }

    @ViewBuilder
    private func startedBadge(count: Int) -> some View {
        Circle()
            .fill(palette.startedBadgeFill.opacity(0.15))
            .frame(width: DSLayout.calendarBadgeSize, height: DSLayout.calendarBadgeSize)
            .overlay {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: DSLayout.calendarBadgeIconSize, weight: .bold))
                    .foregroundStyle(palette.startedBadgeFill)
            }
    }

    @ViewBuilder
    private func finishedBadge(count: Int) -> some View {
        Circle()
            .fill(palette.finishedBadgeFill.opacity(0.15))
            .frame(width: DSLayout.calendarBadgeSize, height: DSLayout.calendarBadgeSize)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: DSLayout.calendarBadgeIconSize, weight: .bold))
                    .foregroundStyle(palette.finishedBadgeFill)
            }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = monthLocale
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: monthDate)
    }

    private var weekdaySymbols: [String] {
        var symbols = calendar.shortStandaloneWeekdaySymbols
        let firstWeekdayIndex = calendar.firstWeekday - 1
        if firstWeekdayIndex > 0 {
            symbols = Array(symbols[firstWeekdayIndex...]) + Array(symbols[..<firstWeekdayIndex])
        }
        return symbols
    }

    private var gridDays: [Date] {
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
        let range = calendar.range(of: .day, in: .month, for: startOfMonth) ?? 1..<2

        let firstWeekday = calendar.component(.weekday, from: startOfMonth)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date] = []
        if leading > 0 {
            for offset in stride(from: leading, to: 0, by: -1) {
                if let d = calendar.date(byAdding: .day, value: -offset, to: startOfMonth) {
                    days.append(d)
                }
            }
        }

        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: startOfMonth) {
                days.append(d)
            }
        }

        while days.count % 7 != 0 {
            if let last = days.last, let next = calendar.date(byAdding: .day, value: 1, to: last) {
                days.append(next)
            } else {
                break
            }
        }

        return days
    }
}

struct DayBookWordsView: View {
    var title: String
    let items: [VocabularyEntry]
    @Binding var suppressRootPaging: Bool
    let onOpenInBook: (OpenBookRequest) -> Void

    @State private var flashcardRoute: FlashcardRoute?
    @State private var filter: MasteryFilter = .all
    @State private var localItems: [VocabularyEntry] = []
    @State private var memoizedFilteredItems: [VocabularyEntry] = []
    @State private var selection: Set<Int> = []
    @State private var isSelectionMode: Bool = false
    @State private var suppressTap: Bool = false
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.rootTabBarHeight) private var rootTabBarHeight
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { appSettings.theme.calendarPalette(for: colorScheme) }

    private var theme: LibraryTheme { appSettings.theme }
    private var calendarTextColor: Color {
        palette.text
    }
    private var calendarMutedColor: Color {
        palette.muted
    }
    private var calendarDangerColor: Color {
        palette.danger
    }
    private var calendarDangerTextColor: Color {
        palette.dangerText
    }
    private var actionBarSurfaceColor: Color {
        colorScheme == .dark ? theme.cardSurface.opacity(0.94) : theme.cardSurface.opacity(0.95)
    }
    private var actionBarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }
    private var destructiveButtonFillColor: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.85, green: 0.22, blue: 0.22, alpha: 0.92)
                : UIColor(red: 0.82, green: 0.18, blue: 0.18, alpha: 0.94)
        })
    }
    private var destructiveButtonBorderColor: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0.40, blue: 0.40, alpha: 0.30)
                : UIColor(red: 0.70, green: 0.12, blue: 0.12, alpha: 0.25)
        })
    }
    private var destructiveButtonForegroundColor: Color {
        .white
    }
    private var destructiveButtonDisabledFillColor: Color {
        theme.cardSurface.opacity(colorScheme == .dark ? 0.72 : 0.66)
    }
    private var destructiveButtonDisabledBorderColor: Color {
        theme.cardStroke.opacity(colorScheme == .dark ? 0.78 : 0.60)
    }
    private var destructiveButtonDisabledForegroundColor: Color {
        calendarMutedColor
    }

    private var bookInfoCard: some View {
        let totalCount = localItems.count
        let unknownCount = localItems.filter {
            $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue
        }.count
        let knownCount = totalCount - unknownCount
        let coverPath: String? = {
            guard let bookId = localItems.first?.bookId, !bookId.isEmpty else { return nil }
            return BookStore.shared.coverImagePath(forBookId: bookId)
        }()

        return VStack(spacing: 16) {
            HStack(spacing: 14) {
                BookCoverThumbnail(coverPath: coverPath)
                    .scaleEffect(1.3)
                    .frame(width: 57, height: 75)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                    Text(AppText.L("\(totalCount) words total", "총 \(totalCount)개 단어", "共\(totalCount)个单词"))
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                }
                Spacer(minLength: 0)

                if canOpenCurrentBook {
                    Button {
                        openCurrentBook()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.title3)
                            .foregroundStyle(palette.accent)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(palette.accent.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text("\(knownCount)")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(palette.accent)
                    Text(AppText.t(.masteryKnown))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(theme.cardStroke)
                    .frame(width: 1, height: 32)

                VStack(spacing: 2) {
                    Text("\(unknownCount)")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(palette.danger)
                    Text(AppText.t(.masteryUnknown))
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.cardSurface.opacity(colorScheme == .dark ? 0.6 : 0.5))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            if isSelectionMode {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { endSelectionMode() }
            }

            List {
                // Book info card as first section
                Section {
                    bookInfoCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                // Filter bar
                Section {
                    FilterBar(selection: $filter, showsBackground: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                // Word rows
                ForEach(filteredItems) { item in
                    WordListRow(
                        item: item,
                        isSelected: selection.contains(item.id),
                        isSelectionMode: isSelectionMode,
                        onTap: {
                            if suppressTap { return }
                            if isSelectionMode {
                                toggleSelection(item.id)
                            } else {
                                guard !AuthManager.shared.guestGate(.flashcard) else { return }
                                if let idx = filteredItems.firstIndex(where: { $0.id == item.id }) {
                                    flashcardRoute = FlashcardRoute(startIndex: idx)
                                }
                            }
                        },
                        onLongPress: {
                            if !isSelectionMode {
                                suppressTap = true
                                beginSelectionMode(with: item.id)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    suppressTap = false
                                }
                            }
                        }
                    )
                    .equatable()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteSingleItem(item)
                        } label: {
                            Label(AppText.t(.delete), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        let current = MasteryState(rawValue: item.masteryState) ?? .none
                        Button {
                            toggleSingleMastery(item)
                        } label: {
                            Label(
                                current == .known ? AppText.t(.masteryUnknown) : AppText.t(.masteryKnown),
                                systemImage: current == .known ? "questionmark.circle" : "checkmark.circle"
                            )
                        }
                        .tint(current == .known ? calendarDangerColor : palette.started)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectionMode {
                selectionActionBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .padding(.bottom, rootBarBottomPad)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isSelectionMode)
        .fullScreenCover(item: $flashcardRoute) { route in
            FlashcardDeckView(
                items: filteredItems,
                startIndex: route.startIndex,
                filter: filter,
                onSetMastery: { id, state in
                    VocabularyStore.shared.setMasteryState(id: id, state: state)
                    updateLocal(id: id, state: state)
                },
                openRequestProvider: { item in
                    openRequestFor(item)
                },
                onOpenInBook: { req in
                    onOpenInBook(req)
                },
                onUpdateEntry: { entry in
                    replaceLocal(entry)
                },
                onDeleteEntry: { id in
                    removeLocal(id: id)
                }
            )
        }
        .onAppear {
            suppressRootPaging = true
            localItems = items
            refreshFilteredItems()
        }
        .onChange(of: items) { _, newValue in
            localItems = newValue
            refreshFilteredItems()
        }
        .onChange(of: filter) { _, _ in
            refreshFilteredItems()
        }
        .onDisappear {
            suppressRootPaging = false
        }
    }

    private var canOpenCurrentBook: Bool {
        openRequestForCurrentBook() != nil
    }

    private var openInBookAccessibilityLabel: String { AppText.t(.openInBook) }

    private func openCurrentBook() {
        guard let req = openRequestForCurrentBook() else { return }
        onOpenInBook(req)
    }

    private var filteredItems: [VocabularyEntry] {
        memoizedFilteredItems
    }

    private func refreshFilteredItems() {
        let next: [VocabularyEntry]
        switch filter {
        case .all:
            next = localItems
        case .unknown:
            next = localItems.filter { $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue }
            case .known:
                next = localItems.filter { $0.masteryState == MasteryState.known.rawValue }
        }
        memoizedFilteredItems = next
        if isSelectionMode {
            let nextSelection = selection.intersection(next.map { $0.id })
            selection = nextSelection
            if selection.isEmpty {
                isSelectionMode = false
            }
        }
    }

    private func updateLocal(id: Int, state: MasteryState) {
        if let idx = localItems.firstIndex(where: { $0.id == id }) {
            let item = localItems[idx]
            localItems[idx] = VocabularyEntry(
                id: item.id,
                uuid: item.uuid,
                word: item.word,
                meaning: item.meaning,
                sentence: item.sentence,
                language: item.language,
                bookId: item.bookId,
                pageIndex: item.pageIndex,
                masteryState: state.rawValue,
                createdAt: item.createdAt,
                updatedAt: Date(),
                deletedAt: item.deletedAt,
                ownerUID: item.ownerUID,
                lookupCount: item.lookupCount,
                highlightRect: item.highlightRect,
                targetLanguage: item.targetLanguage,
                posJson: item.posJson,
                highlightColorHex: item.highlightColorHex,
                synonymPlacement: item.synonymPlacement,
                sentenceTranslationKo: item.sentenceTranslationKo
            )
            refreshFilteredItems()
        }
    }

    private func replaceLocal(_ entry: VocabularyEntry) {
        if let idx = localItems.firstIndex(where: { $0.id == entry.id }) {
            localItems[idx] = entry
            refreshFilteredItems()
        }
    }

    private func removeLocal(id: Int) {
        localItems.removeAll { $0.id == id }
        refreshFilteredItems()
    }

    private func openRequestFor(_ item: VocabularyEntry) -> OpenBookRequest? {
        guard let bookId = item.bookId, !bookId.isEmpty else { return nil }
        guard let pageIndex = item.pageIndex else { return nil }
        guard let record = BooksStore.shared.record(forId: bookId) else { return nil }
        let url = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return OpenBookRequest(bookId: bookId, bookTitle: record.title, fileURL: url, pageIndex: pageIndex)
    }

    private func openRequestForCurrentBook() -> OpenBookRequest? {
        guard let bookId = localItems.first?.bookId, !bookId.isEmpty else { return nil }
        guard let record = BooksStore.shared.record(forId: bookId) else { return nil }
        let url = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let pageIndex = localItems.first(where: { $0.pageIndex != nil })?.pageIndex ?? 0
        return OpenBookRequest(bookId: bookId, bookTitle: record.title, fileURL: url, pageIndex: pageIndex)
    }

    private var unknownLabel: String { AppText.t(.masteryUnknown) }

    private var knownLabel: String { AppText.t(.masteryKnown) }

    private var deleteSelectedLabel: String { AppText.t(.deleteSelected) }

    private func beginSelectionMode(with id: Int) {
        isSelectionMode = true
        selection = [id]
    }

    private func toggleSelection(_ id: Int) {
        if selection.contains(id) {
            selection.remove(id)
            if selection.isEmpty {
                isSelectionMode = false
            }
        } else {
            selection.insert(id)
        }
    }

    private func endSelectionMode() {
        isSelectionMode = false
        selection.removeAll()
    }

    @ViewBuilder
    private var selectionActionBar: some View {
        if isSelectionMode {
            HStack(spacing: 12) {
                Text(selectionCountLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(calendarTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                let deleteEnabled = !selection.isEmpty
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label(deleteSelectedLabel, systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(deleteEnabled ? destructiveButtonForegroundColor : destructiveButtonDisabledForegroundColor)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(deleteEnabled ? destructiveButtonFillColor : destructiveButtonDisabledFillColor)
                        .overlay(
                            Capsule()
                                .stroke(
                                    deleteEnabled ? destructiveButtonBorderColor : destructiveButtonDisabledBorderColor,
                                    lineWidth: 1
                                )
                        )
                )
                .disabled(!deleteEnabled)
                .opacity(deleteEnabled ? 1 : 0.45)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(actionBarSurfaceColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(actionBarStrokeColor, lineWidth: 1)
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.2)
            )
        }
    }

    private var rootBarBottomPad: CGFloat {
        let minimumReserved: CGFloat = 84
        let measured = rootTabBarHeight > 0 ? rootTabBarHeight : minimumReserved
        return max(minimumReserved, measured) + 4
    }

    private var selectionCountLabel: String {
        let count = selection.count
        return AppText.L("\(count) \(AppText.t(.selectedCount))", "\(count)\(AppText.t(.selectedCount))", "\(count)\(AppText.t(.selectedCount))")
    }

    private func deleteSingleItem(_ item: VocabularyEntry) {
        VocabularyStore.shared.delete(ids: [item.id])
        withAnimation {
            localItems.removeAll { $0.id == item.id }
            refreshFilteredItems()
        }
    }

    private func toggleSingleMastery(_ item: VocabularyEntry) {
        let current = MasteryState(rawValue: item.masteryState) ?? .none
        let next: MasteryState = current == .known ? .unknown : .known
        VocabularyStore.shared.setMasteryState(id: item.id, state: next)
        
        if let idx = localItems.firstIndex(where: { $0.id == item.id }) {
            let updated = VocabularyEntry(
                id: item.id,
                uuid: item.uuid,
                word: item.word,
                meaning: item.meaning,
                sentence: item.sentence,
                language: item.language,
                bookId: item.bookId,
                pageIndex: item.pageIndex,
                masteryState: next.rawValue,
                createdAt: item.createdAt,
                updatedAt: Date(),
                deletedAt: item.deletedAt,
                ownerUID: item.ownerUID,
                lookupCount: item.lookupCount,
                highlightRect: item.highlightRect,
                targetLanguage: item.targetLanguage,
                posJson: item.posJson,
                highlightColorHex: item.highlightColorHex,
                synonymPlacement: item.synonymPlacement,
                sentenceTranslationKo: item.sentenceTranslationKo
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                localItems[idx] = updated
            }
        }
    }

    private func deleteSelected() {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        VocabularyStore.shared.delete(ids: ids)
        withAnimation(.easeInOut(duration: 0.2)) {
            localItems.removeAll { selection.contains($0.id) }
            selection.removeAll()
            refreshFilteredItems()
            isSelectionMode = false
        }
    }
}

enum MasteryFilter: String, CaseIterable, Identifiable {
    case all
    case unknown
    case known

    var id: String { rawValue }
}

private struct FilterBar: View {
    @Binding var selection: MasteryFilter
    let showsBackground: Bool
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var calendarPalette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var paletteTextColor: Color { calendarPalette.text }
    private var paletteMutedColor: Color { calendarPalette.muted }

    init(selection: Binding<MasteryFilter>, showsBackground: Bool = true) {
        self._selection = selection
        self.showsBackground = showsBackground
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MasteryFilter.allCases) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            selection = option
                        }
                    } label: {
                            Text(title(for: option))
                                .font(.caption)
                                .fontWeight(selection == option ? .semibold : .regular)
                                .foregroundStyle(selection == option ? paletteTextColor : paletteMutedColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selection == option ? theme.cardSurface : theme.cardSurface.opacity(0.7))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .stroke(
                                                    selection == option ? theme.cardStroke.opacity(0.45) : theme.cardStroke,
                                                    lineWidth: selection == option ? 1 : 0.5
                                                )
                                        )
                                )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(showsBackground ? theme.cardSurface.opacity(0.9) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            showsBackground ? theme.cardStroke : Color.clear,
                            lineWidth: showsBackground ? 1 : 0
                        )
                )
        )
    }

    private func title(for option: MasteryFilter) -> String {
        switch option {
        case .all: return AppText.L("All", "전체", "全部")
        case .unknown: return AppText.t(.masteryUnknown)
        case .known: return AppText.t(.masteryKnown)
        }
    }
}

/// selection + isSelectionMode까지 포함한 행 전체를 Equatable로 래핑.
/// selection이나 isSelectionMode가 바뀌어도 item·isSelected·isSelectionMode가
/// 모두 같으면 body를 재평가하지 않는다.
private struct WordListRow: View, Equatable {
    let item: VocabularyEntry
    let isSelected: Bool
    let isSelectionMode: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var selectionTextColor: Color { palette.text }
    private var selectionMutedColor: Color { palette.muted }

    static func == (lhs: WordListRow, rhs: WordListRow) -> Bool {
        lhs.item == rhs.item &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isSelectionMode == rhs.isSelectionMode
    }

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? selectionTextColor : selectionMutedColor)
                        .font(.title3)
                        .frame(width: 26, height: 26)
                }
                WordRow(item: item)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress() }
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

private struct WordRow: View, Equatable {
    let item: VocabularyEntry
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    static func == (lhs: WordRow, rhs: WordRow) -> Bool {
        lhs.item == rhs.item
    }

    private var masteryColor: Color {
        let state = MasteryState(rawValue: item.masteryState) ?? .none
        switch state {
        case .known: return palette.accent
        default: return palette.danger
        }
    }

    private var masteryLabel: String {
        let state = MasteryState(rawValue: item.masteryState) ?? .none
        switch state {
        case .known: return AppText.t(.masteryKnown)
        default: return AppText.t(.masteryUnknown)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Word + status
            HStack(alignment: .firstTextBaseline) {
                Text(item.word)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                Text(masteryLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(masteryColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(masteryColor.opacity(0.12))
                    )
            }

            // Meaning
            Text(item.meaning)
                .font(.body)
                .foregroundStyle(palette.text.opacity(0.78))

            // Meta row
            HStack(spacing: 8) {
                if let pageIndex = item.pageIndex {
                    Text("p.\(pageIndex + 1)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
                Text(item.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                Spacer()
            }

            if let sentence = item.sentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.subheadline)
                    .foregroundStyle(palette.muted.opacity(0.85))
                    .lineLimit(2)
                    .italic()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
    }
}

private struct WordsTabDeleteFolderConfirmView: View {
    @Binding var dontAskAgainToday: Bool
    let folderCount: Int
    let onDelete: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppText.t(.confirmDeleteTitle))
                .font(.headline)
            Text(deleteMessage)
                .font(.subheadline)
                .foregroundStyle(palette.muted)
            Toggle(AppText.t(.dontAskAgainToday), isOn: $dontAskAgainToday)
            HStack {
                Button(AppText.t(.cancel), role: .cancel, action: onCancel)
                Spacer()
                Button(AppText.t(.delete), role: .destructive, action: onDelete)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var deleteMessage: String {
        if folderCount <= 1 {
            return AppText.t(.deleteFolderMessage)
        }
        return AppText.L(
            "This will remove all saved words in \(folderCount) folders.",
            "선택한 폴더 \(folderCount)개와 단어가 모두 삭제됩니다.",
            "将删除所选\(folderCount)个文件夹中的所有单词。"
        )
    }
}
