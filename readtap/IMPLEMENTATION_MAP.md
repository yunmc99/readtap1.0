# ReadTap 구현 맵 (정적 분석 리포트)

- 생성일: 2026-03-02
- 기준 루트: `/Users/yunminchae/Desktop/read_tap/readtap`
- 스캔 대상: Swift 소스 파일 91개 (`readtap/readtap/*.swift`)
- 추출 근거: 정적 텍스트 추출 (툴 실행 없이 동작 시맨틱 해석은 별도 리뷰 필요)
- 총 액션 훅 라인: 239
- 총 메서드 라인: 1640
- 중복된 섹션 제거 후 집계: `/tmp/action_index_dedup.txt`

## 1) 구현 범위 요약

- `Root`/네비게이션: 앱 진입점(`readtapApp.swift`), 탭 루트(`RootTabView.swift`), 인증/파이어베이스 초기화/언어 설정, 테마/스타일 유틸.
- `Library/Books`: 홈 화면, 책 폴더/이동/복제/삭제/공유/재불러오기, 책 메타데이터 정렬, 썸네일 캐시, 오프닝 동선.
- `Reader PDF`: PDF 뷰어, 페이지 네비게이션, 상단/하단 툴바, 하이라이트 오버레이, 페이지 점프, OCR/번역/사전 팝업.
- `Reader Image`: 이미지 기반 OCR 판독기, 박스 조정, 단어 저장/완독/수동입력 플로우.
- `Words/단어장`: 일별/책별 조회, 검색/필터, 다중선택 삭제, 마스터리 변경, 플래시카드 학습.
- `통계/리워드`: 일일 단어 수, 연속 읽기일, 시작/완독 카운트, 하루별 상태.
- `동기화/알림`: Firebase 연동 골격, 알림 스케줄, 동기화 엔진/체인지 로그/원격 동기화 준비.
- `데이터/퍼시스턴스`: SQLite 스토어 계층(어휘/책/폴더/폴링/동기화체인지/캐시/스탯), 파일 시스템 기반 책 디렉토리 관리.
- `번역/OCR 파이프라인`: OCR 캐시, 번역 캐시, 문맥 판별/정규화, 번역 라우팅 시도 기록.

## 2) 화면/페이지별 버튼·제스처·모달 액션 맵

아래는 코드에서 감지된 UI 액션 지점(버튼/제스처/시트/알럿/시트/탭/컨텍스트 메뉴 등)입니다. 숫자는 행 번호.

## 화면/액션 훅 맵

### WordsTabHelpers.swift
-   35:        Button(action: onTap) {
### ImageReaderSubviews.swift
-   39:      .onChanged { _ in
### ReaderToolbarComponents.swift
-   61:            ReaderChromeBarButton(
-   67:                ReaderChromeBarButton(
-   82:            ReaderChromeBarButton(
-   88:                ReaderChromeBarButton(
-   95:                ReaderChromeBarButton(
-   152:            ReaderChromeBarButton(
-   159:            ReaderChromeBarButton(
-   175:        Button(action: {
-   241:        Button(action: {
### RootTabView.swift
-   294:                tabButton(.library)
-   295:                tabButton(.calendar)
-   296:                tabButton(.words)
-   297:                tabButton(.settings)
-   312:    private func tabButton(_ tab: RootTab) -> some View {
-   110:            .onAppear {
-   215:            .onAppear {
-   99:            .onChange(of: selectedTab) { _, newTab in
-   113:            .onChange(of: scenePhase) { _, phase in
-   199:            .onChange(of: selectedTab) { _, newTab in
-   219:            .onChange(of: scenePhase) { _, phase in
-   225:            .onChange(of: auth.user) { _, newValue in
### ContentView.swift
-   584:        Button("Cancel", role: .cancel) {}
-   585:        Button("Go") {
-   599:        Button(AppText.t(.ok)) {}
-   2425:          Button(action: { cancelManualEntry() }) {
-   2450:          Button(action: { commitManualEntry() }) {
-   640:        return AnyView(readerLayer.onTapGesture {
-   658:          .onTapGesture {
-   2385:          .onTapGesture {
-   388:      view.onAppear {
-   397:          key: .onAppear,
-   425:              key: .onAppearResume,
-   2476:    .onAppear { isManualEntryFocused = true }
-   529:      view.onDisappear {
-   532:          key: .onDisappear,
-   213:      view.onChange(of: currentPageIndex) { oldPageIndex, newPageIndex in
-   277:      view.onChange(of: viewModel.popup) { oldPopup, newPopup in
-   287:      view.onChange(of: viewModel.isOCRReadyForCurrentPage) { oldValue, newValue in
-   298:      view.onChange(of: pdfViewRef) { oldValue, newValue in
-   308:      view.onChange(of: appSettings.autoSaveEnabled) { oldValue, newValue in
-   316:      view.onChange(of: totalPages) { oldValue, newValue in
-   331:      view.onChange(of: viewModel.isChromeVisible) { oldValue, visible in
-   341:      view.onChange(of: isThumbnailPanelVisible) { oldValue, newValue in
-   367:      view.onChange(of: isAdjustingBox) { oldValue, newValue in
-   374:      view.onChange(of: isManualEntryPresented) { oldValue, newValue in
-   381:      view.onChange(of: pdfLoadFailed) { oldValue, newValue in
-   474:      view.onChange(of: documentURL) { oldURL, newURL in
-   565:      view.onChange(of: scenePhase) { oldPhase, phase in
-   572:      view.sheet(isPresented: $isTargetPickerPresented) {
-   576:      view.sheet(isPresented: $isWordbookSheetPresented) {
-   581:      view.alert("Go to page", isPresented: $isJumpPresented) {
-   595:      view.alert(
-   960:        .task(id: "\(url.path)-\(pageIndex)-\(proxy.size.width)") {
### OCRPrecomputeService.swift
-   41:        await activeTaskStorage.task(for: bookId) != nil
-   62:        let alreadyRunning = await activeTaskStorage.task(for: taskKey) != nil
### SelectionAdjustOverlay.swift
-   82:                            Button(action: onCancel) {
-   101:                            Button(action: onDone) {
-   147:        .onAppear {
-   154:        .onChange(of: containerSize) { _, _ in
-   190:            .onChanged { value in
-   184:                .gesture(dragGesture)
### ReaderThumbnailSidebar.swift
-   580:                                .onAppear {
-   607:            .onAppear {
-   629:            .onDisappear {
-   617:            .onChange(of: currentPageIndex) { _, newValue in
-   624:            .onChange(of: pageCount) { _, newValue in
-   471:        .task(id: "\(pageIndex)-\(Int(thumbWidth))") {
### WordsTabView.swift
-   174:            Button(AppText.t(.cancel), role: .cancel) {
-   178:            Button(renameSaveLabel) {
-   440:                Button(role: .destructive) {
-   1504:                        Button(role: .destructive) {
-   1723:                Button(role: .destructive) {
-   2009:                Button(AppText.t(.cancel), role: .cancel, action: onCancel)
-   2011:                Button(AppText.t(.delete), role: .destructive, action: onDelete)
-   118:                    .onTapGesture {
-   139:                    .onTapGesture { cancelDeleteFolderSelection() }
-   818:                    .onTapGesture {
-   1475:                    .onTapGesture { endSelectionMode() }
-   1940:        .onTapGesture { onTap() }
-   192:        .onAppear {
-   595:            .onAppear {
-   1588:        .onAppear {
-   1600:        .onDisappear {
-   246:            .onChange(of: mode) { _, newValue in
-   249:            .onChange(of: selectedDay) { _, newValue in
-   255:            .onChange(of: monthDate) { _, newValue in
-   260:            .onChange(of: centerDay) { _, newValue in
-   284:            .onChange(of: appSettings.language) { _, _ in
-   287:            .onChange(of: isActive) { _, newValue in
-   588:                    .onChanged { _ in
-   611:            .onChange(of: scrollRequestDay) { _, newValue in
-   628:            .onChange(of: stripDays.count) { _, newCount in
-   1593:        .onChange(of: items) { _, newValue in
-   1597:        .onChange(of: filter) { _, _ in
-   160:        .sheet(item: $openedFolder) { folder in
-   1571:        .sheet(item: $flashcardRoute) { route in
-   156:        .fullScreenCover(item: $openRequest) { req in
-   172:        .alert(renameTitle, isPresented: $isRenamePresented) {
### SplashView.swift
-   43:        .onAppear {
### FolderBookPickerView.swift
-   74:            Button(action: saveAndClose) {
-   95:                Button("Clear") {
-   102:                EditButton()
-   145:        Button(action: action) {
-   105:        .onAppear {
-   93:        .toolbar {
### FolderManagerView.swift
-   46:                        Button("Done") { isNewFieldFocused = false }
-   58:                Button("Cancel", role: .cancel) { renamingFolder = nil }
-   59:                Button("Save") { saveRename() }
-   221:            Button(role: .destructive) {
-   228:            Button(role: .destructive) {
-   212:        .onTapGesture {
-   62:            .sheet(item: $editingFolder) { folder in
-   53:            .alert(AppLanguage.current() == .korean ? "이름 변경" : "Rename", isPresented: Binding<Bool>(
-   215:        .contextMenu {
-   42:            .toolbar {
### FolderChipView.swift
-   20:        Button(action: onTap) {
### LibraryThemePickerView.swift
-   46:        Button(action: onTap) {
### CalendarTabView.swift
-   37:            .onAppear { readingStreakDays = BookReadingStatusStore.shared.readingStreak() }
### ReaderWordbookSheet.swift
-   62:                                    Button(role: .destructive) {
-   44:                                .onTapGesture {
-   106:        .onAppear { reload() }
-   92:            .sheet(item: $flashcardRoute) { route in
-   76:            .toolbar {
### VocabularyListView.swift
-   35:                                Button(role: .destructive) {
-   154:        .onTapGesture {
-   62:            .onAppear {
-   68:            .fullScreenCover(item: $openRequest) { req in
### WordPopupView.swift
-   368:      .onAppear {
### HomeView.swift
-   102:                Button("Import PDF") {
-   105:                Button("Import from Photos") {
-   108:                Button("Scan Document") {
-   111:                Button("Cancel", role: .cancel) {}
-   213:                Button("Cancel", role: .cancel) {}
-   214:                Button("Save") {
-   226:                Button("OK", role: .cancel) {}
-   231:                Button(deleteConfirmBookAndWordsLabel, role: .destructive) {
-   238:                Button(deleteConfirmBookOnlyLabel, role: .destructive) {
-   245:                Button("Cancel", role: .cancel) {}
-   533:                Button(role: .destructive) {
-   982:                    Button("Import PDF", systemImage: "doc") {
-   985:                    Button("Import from Photos", systemImage: "photo.on.rectangle") {
-   988:                    Button("Scan Document", systemImage: "doc.text.viewfinder") {
-   1106:        Button(action: action) {
-   1671:        Button(action: action) {
-   1774:        Button(action: action) {
-   1828:                Button("닫기") {
-   1843:                Button("삭제") {
-   1879:        Button(action: action) {
-   925:                    .onTapGesture { openBook(book) }
-   94:            .onDisappear {
-   88:            .onChange(of: isImportDialogPresented) { _, isOpen in
-   91:            .onChange(of: isImportLoadingActive) { _, _ in
-   146:            .sheet(item: $activeImportSheet) { sheet in
-   247:            .sheet(item: $folderSheetBook) { book in
-   262:            .sheet(isPresented: $isFolderManagerPresented) {
-   287:            .sheet(isPresented: $isSharePresented) {
-   191:            .fullScreenCover(item: $readerSelection, onDismiss: { readerSelection = nil }) { selection in
-   211:            .alert("Rename", isPresented: $isRenamePresented) {
-   222:            .alert("Import failed", isPresented: Binding(
-   101:            .confirmationDialog("Add Book", isPresented: $isImportDialogPresented, titleVisibility: .visible) {
-   230:            .confirmationDialog(deleteConfirmTitle, isPresented: $isDeleteConfirmPresented, titleVisibility: .visible) {
-   80:            .toolbar(.hidden, for: .navigationBar)
-   174:            .task(id: isActive) {
-   1423:        .task(id: book.coverImagePath) {
### StreakView.swift
-   30:        .onAppear {
-   34:        .onDisappear {
-   46:        .onChange(of: scenePhase) { _, phase in
-   55:        .onChange(of: appSettings.language) { _, _ in
-   76:        .contextMenu {
### ReviewDeckView.swift
-   70:            .onAppear {
-   69:            .toolbar(.hidden, for: .navigationBar)
### FlashcardDeckView.swift
-   184:                Button(okTitle, role: .cancel) {}
-   436:                    Button(cancelTitle) { onCancel() }
-   439:                    Button(saveTitle) { onSave() }
-   477:        .onTapGesture {
-   124:                                    .onChanged { value in
-   174:            .sheet(isPresented: $isEditPresented) {
-   183:            .alert(editErrorTitle, isPresented: $isEditErrorPresented) {
-   145:            .toolbar {
-   434:            .toolbar {
-   122:                            .gesture(
### VocabularyByBookView.swift
-   196:            Button(role: .destructive) {
-   1290:                Button(AppText.t(.cancel), role: .cancel, action: onCancel)
-   1292:                Button(AppText.t(.delete), role: .destructive, action: onDelete)
-   66:                    .onTapGesture {
-   120:                    .onTapGesture { cancelDelete() }
-   111:            .onAppear { if isActive { reload() } }
-   148:        .onAppear {
-   112:            .onChange(of: isActive) { _, active in
-   152:        .onChange(of: folders) { _, _ in
-   156:        .onChange(of: folderSections) { _, _ in
-   159:        .onChange(of: searchText) { _, _ in
-   162:        .onChange(of: filter) { _, _ in
-   165:        .onChange(of: sortMode) { _, _ in
-   168:        .onChange(of: groupByFolder) { _, _ in
-   171:        .onChange(of: openFromReaderRequest) { _, newRequest in
-   144:        .fullScreenCover(item: $openRequest) { req in
-   1164:        .fullScreenCover(item: $openRequest) { req in
-   1147:                .contextMenu {
### StreakCalendarView.swift
-   191:                Button(action: onClose) {
-   24:                    .onTapGesture { isPresented = false }
-   59:        .onAppear { readingStreakDays = BookReadingStatusStore.shared.readingStreak() }
### SettingsView.swift
-   240:            Button("OK", role: .cancel) {}
-   258:                Button(role: .destructive) {
-   427:                Button(AppText.t(.save)) {
-   450:                Button(AppText.t(.clear)) {
-   529:                    Button(role: .destructive) {
-   470:        .onAppear {
-   124:        .onChange(of: appSettings.language) { _, _ in
-   244:        .onChange(of: appSettings.language) { _, _ in
-   236:        .alert("Sign-in Failed", isPresented: Binding(
-   123:        .toolbar(.hidden, for: .navigationBar)
-   235:        .toolbar(.hidden, for: .navigationBar)
### FolderPickerSheet.swift
-   97:                    Button("Done") {
-   118:                        Button("완료") {
-   172:        Button(action: action) {
-   124:            .onTapGesture {
-   128:        .onAppear {
-   85:            .toolbar {
### ImageReaderView.swift
-   145:            Button(AppText.t(.cancel)) { cancelManualEntry() }
-   148:            Button(AppText.t(.done)) { commitManualEntry() }
-   155:      Button(AppText.t(.cancel), role: .cancel) {
-   201:            .onTapGesture {
-   98:    .onAppear {
-   110:    .onDisappear {
-   93:    .onChange(of: viewModel.popup) { _, newValue in
-   104:    .onChange(of: viewModel.image) { _, _ in
-   114:    .onChange(of: scenePhase) { _, phase in
-   432:      .onChanged { value in
-   927:      .onChanged { value in
-   117:    .sheet(isPresented: $isWordbookPresented) {
-   120:    .sheet(isPresented: $isManualEntryPresented) {
-   154:    .alert("조정 영역 오류", isPresented: shouldPresentAdjustBoxError) {
-   143:        .toolbar {
### PDFKitView.swift
-   1418:            // prefetch는 ContentView.onChange(of: currentPageIndex)에서
-   2229:                    delay: Timing.gestureModeWarmupDelay
-   4504:                if let gestures = current.gestureRecognizers, !gestures.isEmpty {
### BookVocabularyListView.swift
-   83:            .onTapGesture {
-   47:            .onAppear {
### VocabularyByDateView.swift
-   123:        .onTapGesture {
-   62:            .onAppear {
-   65:            .fullScreenCover(item: $openRequest) { req in
-   128:        .contextMenu {

## 3) 공유 상태/동작 중첩(겹침) 분석

### 3-1. 파일당 공유 싱글턴 사용(핵심)

`readtap` 내부에서 싱글턴 인스턴스를 직접 참조하는 파일 목록:

```text
readtap/readtap/AppWarmup.swift	VocabularyStore;BooksStore;OCRCacheStore;TranslationLookupCache;
readtap/readtap/BookReadingStatusStore.swift	VocabularyStore;
readtap/readtap/BookStore.swift	VocabularyStore;BookReadingStatusStore;BooksStore;BookStore;ReadingProgressStore;OCRCacheStore;BookDrawingStore;
readtap/readtap/BookVocabularyListView.swift	VocabularyStore;
readtap/readtap/BooksStore.swift	OCRCacheStore;BookDrawingStore;
readtap/readtap/CalendarTabView.swift	BookReadingStatusStore;
readtap/readtap/ContentView.swift	BookReadingStatusStore;ReadingProgressStore;PDFHighlightManager;
readtap/readtap/Database/VocabularyStore.swift	BooksStore;
readtap/readtap/FlashcardDeckView.swift	VocabularyStore;
readtap/readtap/HomeView.swift	VocabularyStore;BookReadingStatusStore;BooksStore;BookStore;ReadingProgressStore;
readtap/readtap/ImageReaderView.swift	VocabularyStore;BookReadingStatusStore;StreakStore;
readtap/readtap/NotificationManager.swift	VocabularyStore;StreakStore;
readtap/readtap/OCRPrecomputeService.swift	OCRCacheStore;
readtap/readtap/PDFHighlightManager.swift	VocabularyStore;
readtap/readtap/PDFKitView.swift	BookDrawingStore;
readtap/readtap/ReadTapPDFView.swift	BookDrawingStore;
readtap/readtap/ReaderUsageTracker.swift	BookReadingStatusStore;StreakStore;
readtap/readtap/ReaderViewModel+Lookup.swift	BookReadingStatusStore;PDFHighlightManager;
readtap/readtap/ReaderViewModel+OCR.swift	OCRCacheStore;
readtap/readtap/ReaderViewModel.swift	VocabularyStore;BookReadingStatusStore;StreakStore;MeaningCandidateCacheStore;PDFHighlightManager;
readtap/readtap/ReaderWordbookSheet.swift	VocabularyStore;
readtap/readtap/ReviewDeckView.swift	VocabularyStore;
readtap/readtap/RootTabView.swift	SyncEngine;NotificationManager;
readtap/readtap/SettingsView.swift	NotificationManager;
readtap/readtap/StreakCalendarView.swift	BookReadingStatusStore;
readtap/readtap/StreakView.swift	VocabularyStore;BookReadingStatusStore;
readtap/readtap/SyncEngine.swift	VocabularyStore;BookReadingStatusStore;BooksStore;BookStore;
readtap/readtap/TranslationService.swift	VocabularyStore;TranslationLookupCache;
readtap/readtap/VocabularyByBookView.swift	VocabularyStore;BookReadingStatusStore;BooksStore;
readtap/readtap/VocabularyByDateView.swift	VocabularyStore;BooksStore;
readtap/readtap/VocabularyListView.swift	VocabularyStore;BooksStore;
readtap/readtap/WordLookupService.swift	VocabularyStore;
readtap/readtap/WordsTabView.swift	VocabularyStore;BookReadingStatusStore;BooksStore;BookStore;
readtap/readtap/readtapApp.swift	AppSettings;
```
### 3-2. 동작이 겹치는 핵심 영역

- `VocabularyStore`(단어 영속화/상태)
  - 저장(단어 저장/갱신), 삭제, 마스터리 변경, 조회가 여러 화면에서 동일 실행.
  - 호출 지점: `ReaderViewModel+Lookup.swift`, `ImageReaderView.swift`, `ReaderWordbookSheet.swift`, `VocabularyListView.swift`, `VocabularyByBookView.swift`, `WordsTabView.swift`, `FlashcardDeckView.swift`, `WordLookupService.swift`, `ReviewDeckView.swift`.

- `BookReadingStatusStore`(읽기 진행/완독/시작일/마감일/단어 저장 카운트)
  - 독서 상태 기록과 목표 판정이 Reader 및 단어탭/달력 계열에서 함께 참조.
  - 호출 지점: `ContentView.swift`, `ImageReaderView.swift`, `ReaderUsageTracker.swift`, `ReaderViewModel+Lookup.swift`, `ReaderViewModel.swift`, `HomeView.swift`, `WordsTabView.swift`, `VocabularyByBookView.swift`, `StreakCalendarView.swift`, `CalendarTabView.swift`, `SyncEngine.swift`, `StreakView.swift`.

- `BooksStore`(책/폴더 메타 변경)
  - 책 이동/정렬/폴더 배정/이름 변경이 `HomeView`를 중심으로 수행되며, 조회/필터링이 단어 탭/리스트에 광범위하게 사용.
  - 호출 지점: `BooksStore.swift` 본체 + `HomeView.swift`, `WordsTabView.swift`, `VocabularyByBookView.swift`, `VocabularyByDateView.swift`, `VocabularyListView.swift`, `SyncEngine.swift`.

- `BookStore`(파일/파일시스템 정리)
  - 삭제/복제/경로 변경/마이그레이션 시 `VocabularyStore`, `BookReadingStatusStore`, `BookmarkStore`, `ReadingProgressStore` 등과 함께 정리 로직이 묶임.
  - 호출 지점: `BookStore.swift` 본체 중심, `HomeView.swift`, `SyncEngine.swift`.

- `NotificationManager`
  - 알림 스케줄 갱신이 `RootTabView.swift`(탭 진입/복귀/상태변경)와 `SettingsView.swift`(설정 변경)에서 반복 호출.

- `SyncEngine` 동기화 트리거
  - 현재 공개 호출은 `RootTabView.swift`의 수동/조건부 sync 트리거가 중심.
  - 동기화 영향 엔티티: 어휘/책/상태/동기화체인지(`VocabularyStore`, `BooksStore`, `BookStore`, `BookReadingStatusStore`).

### 3-3. 중복 동작 예시(추가 개발 시 충돌 포인트)

- 완독 토글
  - `ContentView.swift`와 `ImageReaderView.swift`에서 모두 완독 토글/완독 상태 참조(`toggleFinished`)를 직접 수행.
- 단어 저장/저장카운트
  - 단어 저장은 Reader 쪽(`ReaderViewModel+Lookup.swift`)과 ImageReader 쪽(`ImageReaderView.swift`) 경로가 중복.
  - 단어 저장 카운트(`markWordsSaved`)도 OCR/리더 분기에서 동시 호출 가능.
- 단어 삭제/마스터리 변경
  - `ReaderWordbookSheet`, `VocabularyListView`, `VocabularyByBookView`, `WordsTabView`에서 동일한 store API를 호출.
- 책 삭제
  - `BookStore.remove/delete`에서 단어/북 상태/북마크/진행상태 정리까지 수행하고, UI 레벨에서도 `HomeView` 및 단어 뷰에서 대상 선별 삭제 플로우가 있음.
- 리셋/목표 계산 함수 호출
  - `WordsTabView`와 `StreakView`/`StreakCalendarView`가 `BookReadingStatusStore`의 동일 지표 조회/리셋 함수를 서로 참조.

권장: 향후 신규 기능 추가 시 아래 규칙 적용을 추천
- 공통 상태 변경 API는 최대한 한 소유 영역(Reader 단어 저장/상태 변경, 책 상태 변경, 통계/알림 변경)에서만 수행하고, UI는 해당 메서드 호출만 담당.
- 단어 저장·삭제·마스터리 변경 로직은 `Reader`와 `Words` 화면에서 공통 헬퍼 라우트 혹은 ViewModel로 통합.
- `HomeView`와 `WordsTabView`에서 책 관련 삭제/이동과 `BookStore/BooksStore` 호출이 겹치므로, 책 이동/삭제 정책은 단일 유즈케이스 함수(예: `LibraryMutations`)로 위임 검토.

## 4) 파일별 액션 훅/메서드 원문 맵

아래는 각 Swift 파일을 기준으로 감지된 액션 훅 수, 메서드 시그니처입니다.

### readtap/readtap/Database/PDFThumbnailMetaStore.swift
- action_hooks=, methods=24
- methods:
```
4:final class PDFThumbnailMetaStore {
18:    private init() {
22:    func setup() {
66:    func upsert(cacheKey: String, documentPath: String, documentVersion: String, pageIndex: Int, width: Int, height: Int, filePath: String, bytes: Int64) {
90:    func touch(cacheKey: String) {
106:    func deleteDocument(path: String, version: String) {
116:    func delete(cacheKey: String) {
121:    func deleteDocumentAllVersions(path: String) {
131:    func deleteOtherVersions(for path: String, keep version: String) {
140:    func clearAll() {
144:    func hasSufficientWarmCache(documentPath: String, documentVersion: String, pageLimit: Int, requiredSizeCount: Int) -> Bool {
171:    func staleEntries(forDocumentPath path: String, version: String) -> [(cacheKey: String, filePath: String, bytes: Int64)] {
207:    private func removeRows(whereSQL: String, values: [String]) -> [(String, String, Int64)] {
237:    private func persist(
290:    private func purgeIfNeeded() async {
314:    private func purgeIfNeededIfNeeded() {
320:    private func purgeOutdated(before timestamp: TimeInterval) {
341:    private func purgeByLeastRecentlyUsed(targetFreeBytes: Int64) -> Int64 {
375:    private func pruneRowsIfNeeded(maxRows: Int) {
403:    private func currentTotalBytes() -> Int64 {
411:    private func currentRowCount() -> Int {
419:    private func rowsToDelete(sql: String, bindings: [Int64] = []) -> [(String, String, Int64)]? {
435:    private func rowsToDelete(sql: String, textBindings: [String]) -> [(String, String, Int64)]? {
451:    private func rowsToDelete(sql: String, doubleBindings: [Double]) -> [(String, String, Int64)]? {
```


### readtap/readtap/Database/SQLiteStore.swift
- action_hooks=, methods=12
- methods:
```
7:final class SQLiteStore {
15:    private init() {
25:    deinit {
32:    private func runOnQueue<T>(_ work: () throws -> T) rethrows -> T {
41:    private func openDB() {
70:    private func createTablesIfNeeded() {
162:    func execute(_ sql: String) -> Bool {
180:    func withStatement<T>(_ sql: String, _ block: (OpaquePointer?) throws -> T) rethrows -> T? {
197:    func transaction(_ work: () -> Bool) -> Bool {
211:    private func hasColumn(table: String, column: String) -> Bool {
225:    private func backfillVocabularyUUIDsAndUpdatedAt() {
250:    private func backfillVocabularyUpdatedAt() {
```


### readtap/readtap/Database/SyncChangeStore.swift
- action_hooks=, methods=11
- methods:
```
4:enum SyncEntityType: String {
11:enum SyncAction: String {
16:struct SyncChange: Identifiable, Hashable {
24:final class SyncChangeStore {
30:    private init() {
34:    private func createTableIfNeeded() {
49:    func recordChange(type: SyncEntityType, id: String, action: SyncAction, at date: Date = Date()) {
67:    func fetchAll() -> [SyncChange] {
89:    func delete(ids: [Int]) {
101:    func clear() {
105:    func performWithoutRecording(_ block: () -> Void) {
```


### readtap/readtap/Database/TranslationLookupCache.swift
- action_hooks=, methods=11
- methods:
```
4:final class TranslationLookupCache {
15:    private init() {
19:    func setup() {
52:    func key(
69:    func load(
103:    func save(
146:    private func markLookupHit(cacheKey: String) {
162:    private func persistTranslationCache(
204:    private func purgeIfNeeded() async {
220:    private func purgeOutdated(before timestamp: TimeInterval) {
231:    private func pruneRowsIfNeeded(maxRows: Int) {
```


### readtap/readtap/Database/CacheNormalizer.swift
- action_hooks=, methods=1
- methods:
```
5:enum CacheNormalizer {
```


### readtap/readtap/Database/OCRCacheStore.swift
- action_hooks=, methods=14
- methods:
```
4:final class OCRCacheStore {
16:    private init() {}
18:    func setup() {
41:    func load(bookId: String, pageIndex: Int) -> [PDFOCRWord]? {
46:    func load(bookId: String, pageIndex: Int, languages: [String]) -> [PDFOCRWord]? {
51:    private func load(bookId: String, pageIndex: Int, requiredLanguageKey: String?) -> [PDFOCRWord]? {
113:    private func parseLanguageKey(_ languageKey: String) -> (version: String?, languages: Set<String>)? {
139:    private func purgeIfNeeded() async {
155:    private func purgeOutdated(before timestamp: TimeInterval) {
166:    private func pruneRowsIfNeeded(maxRows: Int) {
191:    func save(bookId: String, pageIndex: Int, words: [PDFOCRWord], languages: [String]) {
214:    private func makeLanguageKey(for languages: [String], includeVersion: Bool) -> String {
227:    func deleteBook(bookId: String) {
236:    func deletePage(bookId: String, pageIndex: Int) {
```


### readtap/readtap/Database/TranslationTelemetryStore.swift
- action_hooks=, methods=19
- methods:
```
4:enum TranslationAttemptEngine: String {
14:struct TranslationAttemptTelemetry {
29:final class TranslationTelemetryStore {
43:    private struct RoutingDecisionCacheEntry {
48:    private init() {
52:    func setup() {
88:    func record(_ event: TranslationAttemptTelemetry) {
127:    func shouldPrioritizeDeepL(source: String, target: String, text: String) -> Bool? {
176:    private func queryRoutingStats(
215:    func shouldPreferMyMemory(
275:    private enum RoutingDecisionKind {
280:    private func routingDecisionCacheKey(
299:    private func routingDecisionCacheValue(for key: String) -> Bool? {
314:    private func routingDecisionStore(value: Bool?, for key: String) {
335:    func cleanup() {
341:    private func purgeIfNeeded() async {
357:    private func purgeOutdated(before timestamp: TimeInterval) {
368:    private func pruneRowsIfNeeded(maxRows: Int) {
392:    private func normalizeLangCode(_ value: String) -> String {
```


### readtap/readtap/Database/MeaningCandidateCacheStore.swift
- action_hooks=, methods=13
- methods:
```
4:final class MeaningCandidateCacheStore {
7:    struct Candidate: Codable, Equatable {
21:    private init() {
25:    func setup() {
57:    func key(word: String, source: String, target: String, context: String?) -> String {
67:    func load(
99:    func save(
135:    private func markLookupHit(cacheKey: String) {
151:    private func persistCandidates(
196:    private func purgeIfNeeded() async {
212:    private func purgeOutdated(before timestamp: TimeInterval) {
223:    private func pruneRowsIfNeeded(maxRows: Int) {
247:    private func dedupeAndNormalize(_ candidates: [Candidate]) -> [Candidate] {
```


### readtap/readtap/Database/VocabularyStore.swift
- action_hooks=, methods=38
- methods:
```
5:enum MasteryState: Int, CaseIterable, Identifiable {
14:struct DayVocabularyCounts: Hashable {
20:enum VocabularyUpdateResult: Hashable {
27:struct VocabularyEntry: Identifiable, Hashable {
46:final class VocabularyStore {
52:    private init() {}
54:    private func notifyVocabularyDidChange() {
61:    func saveWord(
121:    func saveWord(
177:    func fetchRecent(limit: Int = 50) -> [VocabularyEntry] {
193:    func earliestCreatedAt(forBookId bookId: String) -> Date? {
220:    func fetchByBookId(_ bookId: String, limit: Int = 500) -> [VocabularyEntry] {
235:    func fetchCount() -> Int {
245:    func fetchCountForDay(_ date: Date) -> Int {
264:    func fetchCountsForDay(_ date: Date) -> DayVocabularyCounts {
306:    func fetchCountsByDayKey(from start: Date, to end: Date) -> [String: Int] {
333:    func fetchForDay(_ date: Date, limit: Int = 500) -> [VocabularyEntry] {
352:    func setMasteryState(id: Int, state: MasteryState) {
365:    func updateWordMeaningSentence(id: Int, word: String, meaning: String, sentence: String?, bookId: String?) -> VocabularyUpdateResult {
425:    func updateHighlightRect(id: Int, rect: CGRect?) -> Bool {
443:    func deleteByBookId(_ bookId: String) {
462:    func deleteByBookId(_ bookId: String, forDay date: Date) {
491:    func delete(ids: [Int]) {
509:    func migrateBookId(from oldBookId: String, to newBookId: String) {
522:    func distinctBookIds() -> [String] {
539:    func consolidateOrphanedBookIds() {
562:    private func findExistingId(word: String, bookId: String?) -> Int? {
584:    func existingEntry(word: String, bookId: String?) -> VocabularyEntry? {
598:    func record(forUUID uuid: String) -> VocabularyEntry? {
609:    func upsertFromRemote(
729:    func deleteByUUID(_ uuid: String) {
741:    private func incrementLookupCount(id: Int) {
758:    func incrementLookup(word: String, bookId: String?) {
764:    private func recordVocabChange(id: Int, action: SyncAction, at date: Date) {
769:    private func recordVocabDeletes(ids: [Int]) {
779:    private func recordVocabChangesForBookId(_ bookId: String, at date: Date) {
786:    private func uuidForId(_ id: Int) -> String? {
808:    private func idsForBookId(_ bookId: String?, from start: Double? = nil, to end: Double? = nil) -> [Int] {
```


### readtap/readtap/LanguageDetection.swift
- action_hooks=, methods=6
- methods:
```
4:enum TranslationSource: String, CaseIterable, Identifiable {
51:enum TranslationTarget: String, CaseIterable, Identifiable {
88:    func resolvedLocaleLanguage(forSource source: String) -> String {
126:enum DetectedLanguage: String {
148:struct LanguageDetector {
149:    struct Result {
```


### readtap/readtap/WordsTabHelpers.swift
- action_hooks=1, methods=6
- hooks:
```
35:        Button(action: onTap) {
```
- methods:
```
10:struct DatePill: View {
93:    private func startedBadge(count: Int) -> some View {
105:    private func finishedBadge(count: Int) -> some View {
132:struct DayBookFolder: Identifiable, Equatable {
159:enum SmallBadgeKind {
164:struct SmallBadge: View {
```


### readtap/readtap/TranslationTargetPickerView.swift
- action_hooks=, methods=1
- methods:
```
3:struct TranslationTargetPickerView: View {
```


### readtap/readtap/StreakStore.swift
- action_hooks=, methods=11
- methods:
```
4:struct StreakSummary: Equatable {
10:final class StreakStore {
15:    private init() {
19:    private func createTableIfNeeded() {
32:    func markRead(seconds: Int) {
49:    func markSavedWord() {
64:    func summary() -> StreakSummary {
106:    func readingActivityByDayKey(from start: Date, to end: Date) -> [String: Bool] {
130:    func resetAll() {
134:    private func fetchRecentDays(limit: Int) -> [String: StreakRecord] {
164:    private struct StreakRecord {
```


### readtap/readtap/ImageReaderSubviews.swift
- action_hooks=, methods=4
- methods:
```
3:struct OCRWordOverlay: View {
37:  private func longPressGesture(_ mapped: [MappedWord]) -> some Gesture {
63:  private func nearestWord(to point: CGPoint, in mapped: [MappedWord]) -> MappedWord? {
74:struct ImageReaderLoadingPulseView: View {
```


### readtap/readtap/ReaderToolbarComponents.swift
- action_hooks=9, methods=7
- hooks:
```
61:            ReaderChromeBarButton(
67:                ReaderChromeBarButton(
82:            ReaderChromeBarButton(
88:                ReaderChromeBarButton(
95:                ReaderChromeBarButton(
152:            ReaderChromeBarButton(
159:            ReaderChromeBarButton(
175:        Button(action: {
241:        Button(action: {
```
- methods:
```
11:private enum ReaderHaptics {
22:    private class SharedTapHaptic {
27:struct ReaderChromeBar: View, Equatable {
124:struct ReaderBottomBar: View, Equatable {
216:struct ReaderChromeBarButton: View {
226:    init(
284:struct LongPressModePill: View {
```


### readtap/readtap/TranslationService.swift
- action_hooks=, methods=98
- methods:
```
9:    func translate(text: String, source: String, target: String, context: String?) async throws -> String
12:extension TranslationServicing {
13:    func translate(
23:    func translate(
54:enum TranslationEngine: String, CaseIterable, Identifiable {
127:private actor SourceLanguageCache {
132:    func load(_ key: String) -> String? {
139:    func store(_ key: String, value: String) {
162:enum TranslationError: Error {
169:struct PapagoTranslator: TranslationServicing {
170:    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
177:struct ContextServerTranslator: TranslationServicing {
181:    init(preferredProvider: String? = nil, apiKeyProvider: (() -> String?)? = nil) {
186:    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
230:struct MyMemoryTranslator: TranslationServicing {
232:    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
272:    private func langCode(from bcp47: String) -> String {
277:    private func preferredSourceLanguage(for source: String, text: String) -> String {
289:private struct MyMemoryResponse: Decodable {
290:    struct ResponseData: Decodable {
298:struct KoreanDictionaryTranslator: TranslationServicing {
299:    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
317:final class CompositeTranslator: TranslationServicing {
332:    private func debugTranslationLog(_ message: String) {
336:    private func debugTranslationLog(_ message: String) {}
339:    private struct InFlightTranslationRequestKey: Hashable {
347:    private actor InFlightTranslationCoordinator {
350:        func run(_ key: InFlightTranslationRequestKey, _ operation: @escaping () async throws -> String) async throws -> String {
368:    private actor TranslationEngineBackoffGate {
369:        private struct State {
379:        func canAttempt(_ key: String) -> Bool {
387:        func markSuccess(_ key: String) {
391:        func recordFailure(_ key: String, isRecoverable: Bool) {
407:    func translate(text: String, source: String, target: String, context: String?) async throws -> String {
417:    func translate(
473:    private func preferredTranslationEngine(_ preferredEngine: TranslationEngine?) -> TranslationEngine {
480:    private func translateSingleShot(
592:        func loadCachedTranslation(_ engine: TranslationAttemptEngine, contextKey: String?) -> String? {
620:        func performTranslateWithMetrics(
771:        func attemptMyMemoryTranslation() async throws -> String {
839:            func add(_ list: inout [TranslationEngine], _ engine: TranslationEngine) {
1021:    private func shouldFallbackToMyMemory(_ error: TranslationError) -> Bool {
1032:    private func translationBackoffKey(
1041:    private func translationRetryAttempts(for engine: TranslationAttemptEngine, inputLength: Int, hasContext: Bool) -> Int {
1053:    private func shouldRetryTranslationError(
1077:    private func translationRetryDelayMs(error: TranslationError, attempt: Int, engine: TranslationAttemptEngine) -> UInt64 {
1105:    private func loadUserDefinedTranslation(
1149:    private func isLikelyPlaceholderMeaning(
1163:    private func shouldRejectTranslationOutput(
1188:    private func normalizedTextForTranslationComparison(normalizedText: String) -> String {
1203:    private func hasExpectedScript(for output: String, target: String) -> Bool {
1213:    private func translateChunksConcurrently(
1237:            func addNextTask() {
1300:    private func normalizedLangCode(_ value: String) -> String {
1309:    private func normalizedTranslationLanguage(_ value: String) -> String {
1322:    private func hasMixedScripts(_ text: String) -> Bool {
1340:    private func resolvedSourceLanguage(source: String, text: String) async -> String {
1380:    private func sourceLanguageCacheKey(source: String, text: String) -> String {
1388:    private func quickSourceLanguageHint(for text: String) -> String? {
1455:    private func normalizedTranslationContext(_ context: String?) -> String? {
1474:    private func normalizeTranslationInput(_ text: String) -> String {
1501:    private func splitTextForTranslation(_ text: String) -> [String] {
1563:    private func chunkTranslationContext(
1570:    private func combineChunkContext(current: String?, with chunkText: String) -> String? {
1574:    private func compactChunkContext(for pieces: [String]) -> String? {
1594:    private func translationTextBucket(for text: String) -> Int {
1603:    private func translationErrorCode(from error: Error) -> Int? {
1609:    private func mapToTranslationError(_ error: Error) -> TranslationError {
1625:    private func shouldRetryTranslationError(_ error: TranslationError) -> Bool {
1638:    private func logAttemptTelemetry(
1670:    private func translator(for engine: TranslationEngine) -> TranslationServicing {
1681:    private func shouldPrioritizeDeepL(for text: String, source: String, target: String) -> Bool {
1699:    private func canUseContextServer(
1713:    private func isSupportedByDeepL(source: String, target: String) -> Bool {
1719:    private func attemptEngine(for engine: TranslationEngine) -> TranslationAttemptEngine {
1729:private actor InMemoryTranslationCache {
1734:    func load(key: String) async -> String? {
1740:    func store(key: String, value: String) async {
1755:    private func promote(_ key: String) {
1761:private func inMemoryTranslationCacheKey(
1805:private func shouldFallbackToSecondary(after error: TranslationError) -> Bool {
1821:private enum DeepLLanguage {
1847:private enum FormURLEncoder {
1862:private struct DeepLTranslateResponse: Decodable {
1863:    struct Translation: Decodable {
1869:private struct DeepLErrorResponse: Decodable {
1873:private func shouldRetryNoopTranslation(input: String, output: String, source: String, target: String) -> Bool {
1887:private func normalizeNoopCompare(_ text: String) -> String {
1903:private func hasMeaningfulCharacters(_ text: String) -> Bool {
1918:private func hasEnoughMeaning(_ text: String) -> Bool {
1942:private func areNumericContentOnly(_ text: String) -> Bool {
1953:private func outputContainsHangul(_ text: String) -> Bool {
1961:private func outputContainsLatin(_ text: String) -> Bool {
1970:private func outputContainsHan(_ text: String) -> Bool {
1978:private func outputContainsJapanese(_ text: String) -> Bool {
1986:private func isLikelyLowQualityTranslation(
2061:private func maxCharacterShare(_ text: String) -> Double {
2071:private enum LanguageConfidenceThreshold {
```


### readtap/readtap/WordLookupService.swift
- action_hooks=, methods=45
- methods:
```
10:private actor TranslationRequestCoalescer {
11:  private struct CachedTranslation {
23:  func run(_ key: String, operation: @escaping () async throws -> String) async throws -> String {
59:  private func bumpCacheOrder(_ key: String) {
66:  private func trimCacheIfNeeded() {
78:final class WordLookupService {
79:  struct MeaningLookup {
85:  struct MeaningLookupResult {
98:  func lookupMeaning(
123:  func lookupMeaning(
151:  func lookupMeaningWithMetadata(
271:  func translateOnce(text: String, source: String, target: String, context: String?) async -> String
283:  func translateOnce(
300:  func cachedLookup(word: String, source: String, target: String, bookId: String?) async -> String {
314:  private func normalizedPreferredEngine(for preferredEngine: TranslationEngine) -> TranslationEngine {
318:  private func makeMeaningLookupResult(
343:  func lookupFailureNotice(from rawMeaning: String) -> String? {
359:  private func meaningConfidence(
383:  private func lookupMeaningNoCache(
575:  private func deriveCandidateMeanings(from rawMeaning: String, candidateInput: String) -> [String]
594:  private func parseCandidateStrings(_ text: String) -> [String]? {
626:  private func stripWrappingPunctuation(_ text: String) -> String {
641:  private func stripLeadingEnumeration(_ text: String) -> String {
665:  private func translationCandidates(_ normalizedResult: LookupNormalizationResult, source: String)
702:  private func translationCandidateScore(input: String, output: String, target: String) -> Int {
738:  private func contextQualityCandidate(input: String, output: String, target: String) -> Bool {
744:  private func translationNeedsContextlessRetry(
755:  private func translationOutputHasExpectedScript(_ output: String, target: String) -> Bool {
772:  private func refinedContextlessTranslation(
804:  private func translationRequestCacheKey(
842:  private func normalizedTranslationContext(_ context: String?) -> String? {
861:  private func normalizedLangForLookup(_ value: String) -> String {
871:  private func stableHash(_ text: String) -> String {
883:  private func normalizedTranslationText(_ word: String, source: String) -> String {
888:  private func normalizedTranslationCandidates(for word: String, source: String) -> [String] {
904:  private func normalizedTranslationSource(from source: String, text: String) -> String {
921:  func isLikelyPlaceholderMeaning(_ meaning: String, forWord word: String) -> Bool {
968:  private func normalizeMeaningForTranslateCandidate(_ text: String) -> String {
989:  private func outputContainsHangul(_ text: String) -> Bool {
996:  private func outputContainsLatin(_ text: String) -> Bool {
1004:  private func outputContainsHan(_ text: String) -> Bool {
1011:  private func outputContainsJapanese(_ text: String) -> Bool {
1017:  private func shouldPreferLiveMeaning(_ live: String, over cached: String, word: String) -> Bool {
1026:  private func normalizeMeaningForCompare(_ text: String) -> String {
1036:  private func persistMeaningUpdate(
```


### readtap/readtap/RootTabView.swift
- action_hooks=12, methods=12
- hooks:
```
99:            .onChange(of: selectedTab) { _, newTab in
110:            .onAppear {
113:            .onChange(of: scenePhase) { _, phase in
199:            .onChange(of: selectedTab) { _, newTab in
215:            .onAppear {
219:            .onChange(of: scenePhase) { _, phase in
225:            .onChange(of: auth.user) { _, newValue in
294:                tabButton(.library)
295:                tabButton(.calendar)
296:                tabButton(.words)
297:                tabButton(.settings)
312:    private func tabButton(_ tab: RootTab) -> some View {
```
- methods:
```
6:struct RootTabBarHeightPreferenceKey: PreferenceKey {
14:struct RootTabBarHeightEnvironmentKey: EnvironmentKey {
18:extension EnvironmentValues {
25:private enum RootTab: Int, Hashable {
50:struct RootTabView: View {
74:private struct LocalRootTabView: View {
164:    private func tabContent<C: View>(_ tab: RootTab, @ViewBuilder content: () -> C) -> some View {
172:private struct CloudRootTabView: View {
272:    private func tabContent<C: View>(_ tab: RootTab, @ViewBuilder content: () -> C) -> some View {
279:    private func syncIfSignedIn() {
285:private struct RootTabBar: View {
312:    private func tabButton(_ tab: RootTab) -> some View {
```


### readtap/readtap/ContentView.swift
- action_hooks=32, methods=67
- hooks:
```
213:      view.onChange(of: currentPageIndex) { oldPageIndex, newPageIndex in
277:      view.onChange(of: viewModel.popup) { oldPopup, newPopup in
287:      view.onChange(of: viewModel.isOCRReadyForCurrentPage) { oldValue, newValue in
298:      view.onChange(of: pdfViewRef) { oldValue, newValue in
308:      view.onChange(of: appSettings.autoSaveEnabled) { oldValue, newValue in
316:      view.onChange(of: totalPages) { oldValue, newValue in
331:      view.onChange(of: viewModel.isChromeVisible) { oldValue, visible in
341:      view.onChange(of: isThumbnailPanelVisible) { oldValue, newValue in
367:      view.onChange(of: isAdjustingBox) { oldValue, newValue in
374:      view.onChange(of: isManualEntryPresented) { oldValue, newValue in
381:      view.onChange(of: pdfLoadFailed) { oldValue, newValue in
388:      view.onAppear {
397:          key: .onAppear,
425:              key: .onAppearResume,
474:      view.onChange(of: documentURL) { oldURL, newURL in
529:      view.onDisappear {
532:          key: .onDisappear,
565:      view.onChange(of: scenePhase) { oldPhase, phase in
572:      view.sheet(isPresented: $isTargetPickerPresented) {
576:      view.sheet(isPresented: $isWordbookSheetPresented) {
581:      view.alert("Go to page", isPresented: $isJumpPresented) {
584:        Button("Cancel", role: .cancel) {}
585:        Button("Go") {
595:      view.alert(
599:        Button(AppText.t(.ok)) {}
640:        return AnyView(readerLayer.onTapGesture {
658:          .onTapGesture {
960:        .task(id: "\(url.path)-\(pageIndex)-\(proxy.size.width)") {
2385:          .onTapGesture {
2425:          Button(action: { cancelManualEntry() }) {
2450:          Button(action: { commitManualEntry() }) {
2476:    .onAppear { isManualEntryFocused = true }
```
- methods:
```
18:extension PDFPage: @retroactive @unchecked Sendable {}
20:enum ReaderInteractionMode: String, Equatable {
25:struct ReaderView: View {
107:  private enum ReaderStateMutationKey: String {
158:  private func enqueueReaderStateUpdate(
201:  private func beginReaderStateUpdateCycle() {
650:  private func thumbnailSidebarOverlay(panelWidth: CGFloat, containerSize: CGSize) -> some View {
747:  private func thumbnailPanelWidth(for containerWidth: CGFloat) -> CGFloat {
752:  private func chromeTopBar(for proxy: GeometryProxy) -> some View {
787:  private func chromeBottomBar(for proxy: GeometryProxy) -> some View {
809:  private func openCurrentBookInWordsTab() {
819:  private func refreshPanelDocumentState() {
832:  private func toggleThumbnailPanel() {
858:  private func ensurePanelDocumentReadyForPanel() {
870:  private func schedulePanelDocumentRetry(attempt: Int) {
940:  private struct CachedThumbnailImageProxy: View {
1227:  private enum PDFLoadOverlayState {
1333:  private func loadingMessage(for elapsed: TimeInterval) -> String {
1349:  private func retryPDFLoad(forceResetPage: Bool) {
1365:  private func markPDFReadyForInteraction() {
1370:  private func shouldShowPDFLoadingOverlay(for documentURL: URL?) -> Bool {
1376:  private func pdfDocumentUsableForInteraction() -> Bool {
1382:  private func beginPDFLoadCycle(showLoading: Bool = true, isRecoveryAttempt: Bool = false) {
1476:  private func invalidatePDFLoadSession() {
1501:  private func finalizePDFLoadReady() {
1538:  private func attemptFinalizePDFInteraction(readyGeneration: Int) {
1582:  private func performPDFGeometryWarmup(forceForFirstRun: Bool = false) async {
1667:  private func submitLookupSelection(
1683:  private func startLookupProbe(
1875:  private func lookupSelectionFromTextLayer(
1960:  private func fallbackOCRSelection(
2026:  private func pickWordSelectionFromTextLayer(
2092:  private func lookupPage(
2099:  private func cancelPDFLoadReadyFinalize() {
2104:  private func cancelPdfLoadTimeout() {
2109:  private func setPdfLoadState(
2138:  private func logCacheDiagnostics(reason: String) {
2145:  private func invalidateDocumentCachesForReaderSwitch(oldURL: URL?, newURL: URL?) {
2162:  private func cancelPdfLoadingOverlay() {
2168:  private func startPdfLoadTicker() {
2183:  private func stopPdfLoadTicker() {
2200:  private func syncChromeVisibilityState() {
2207:  private func clearLookupArtifacts() {
2214:  private func hideReaderChrome(immediately: Bool) {
2234:  private func handleReaderSingleTap(hadPopup: Bool, readyGeneration: Int) {
2370:  private func dismissPopupAndClearLookupArtifacts() {
2479:  private func startBoxAdjust() {
2520:  private func fallbackContainerSize() -> CGSize {
2543:  private func startManualEntry() {
2556:  private func cancelBoxAdjust() {
2565:  private func commitBoxAdjust() {
2794:  private func cancelManualEntry() {
2802:  private func commitManualEntry() {
2847:  private func ocrPhraseAndLine(in rectOnPage: CGRect, pageIndex: Int) -> (
2856:    struct Item {
2877:    struct Line {
2883:      init(item: Item) {
2927:    func verticalDistance(from y: CGFloat, to minY: CGFloat, _ maxY: CGFloat) -> CGFloat {
2962:  private func goToPage(_ index: Int) {
2974:  private func navigateToPage(_ index: Int) {
2986:  private func clampPageIndex(_ index: Int) -> Int {
2993:  private func applyPendingNavigationIfNeeded() {
3033:  private func schedulePendingNavigationIfNeeded() {
3046:  private func toggleBookmark() {
3051:  private func toggleFinished() {
3056:  private func scheduleProgressSave() {
3069:extension ReaderView {
```


### readtap/readtap/PDFKitCoordinator.swift
- action_hooks=, methods=


### readtap/readtap/ImageOCRPDFBuilder.swift
- action_hooks=, methods=18
- methods:
```
8:struct ImageOCRPDFBuilder {
9:    enum BuildError: LocalizedError {
94:    private struct OCRWord {
100:    private struct OCRPassResult {
105:    private struct OCRTuningText {
295:    private enum OCRPass {
567:        func mapRect(_ rect: CGRect, within region: CGRect) -> CGRect {
626:        struct PendingToken {
726:        func isTrimChar(_ c: Character) -> Bool {
771:        func isValidWord(_ i: Int, _ j: Int) -> Bool {
1118:	    private struct PDFTextItem {
1127:	        struct WordItem {
1150:	        struct Line {
1155:	        func verticalOverlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
1225:	        func dedupeLineWords(_ sorted: [WordItem]) -> [WordItem] {
1252:	        func medianHeight(of items: [WordItem]) -> CGFloat {
1819:private extension CGImagePropertyOrientation {
1820:    init(_ orientation: UIImage.Orientation) {
```


### readtap/readtap/BookmarkStore.swift
- action_hooks=, methods=9
- methods:
```
3:final class BookmarkStore {
6:    private init() {}
8:    func isBookmarked(bookId: String, pageIndex: Int) -> Bool {
12:    func toggle(bookId: String, pageIndex: Int) {
21:    func migrateBookId(from oldBookId: String, to newBookId: String) {
29:    func remove(bookId: String) {
33:    func page(for bookId: String) -> Int? {
42:    private func save(bookId: String, page: Int?) {
51:    private func keyForBook(_ bookId: String) -> String {
```


### readtap/readtap/WordSnap.swift
- action_hooks=, methods=4
- methods:
```
3:enum WordSnap {
4:    struct Item<Value> {
51:    private struct Line<Value> {
57:        init(item: Item<Value>) {
```


### readtap/readtap/KoreanDictionaryService.swift
- action_hooks=, methods=17
- methods:
```
6:struct KoreanDictionaryEntry {
15:enum KoreanDictKeyStore {
74:final class KoreanDictionaryService {
76:    private init() {}
78:    enum DictError: Error, LocalizedError {
96:    func lookup(_ word: String) async throws -> [KoreanDictionaryEntry] {
125:    private func lookupPrefix(_ word: String, apiKey: String) async throws -> [KoreanDictionaryEntry] {
144:    private func fetchData(from url: URL) async throws -> Data {
171:private final class KRDictErrorParser: NSObject, XMLParserDelegate {
172:    struct APIError {
192:    func parser(_ parser: XMLParser, didStartElement elementName: String,
199:    func parser(_ parser: XMLParser, foundCharacters string: String) {
203:    func parser(_ parser: XMLParser, didEndElement elementName: String,
219:private final class KRDictXMLParser: NSObject, XMLParserDelegate {
242:    func parser(_ parser: XMLParser, didStartElement elementName: String,
259:    func parser(_ parser: XMLParser, foundCharacters string: String) {
263:    func parser(_ parser: XMLParser, didEndElement elementName: String,
```


### readtap/readtap/OCRPrecomputeService.swift
- action_hooks=2, methods=5
- hooks:
```
41:        await activeTaskStorage.task(for: bookId) != nil
62:        let alreadyRunning = await activeTaskStorage.task(for: taskKey) != nil
```
- methods:
```
10:enum OCRPrecomputeService {
20:    private actor ActiveTaskStorage {
23:        func task(for key: String) -> Task<Void, Never>? {
27:        func set(_ task: Task<Void, Never>, for key: String) {
31:        func remove(for key: String) -> Task<Void, Never>? {
```


### readtap/readtap/LookupNormalization.swift
- action_hooks=, methods=7
- methods:
```
4:struct LookupNormalizationResult {
11:enum LookupNormalizer {
150:        func isTrimChar(_ c: Character) -> Bool {
268:    private enum ScriptKind: Equatable {
317:        func pick(_ preferred: String, prefix: String) -> String? {
404:        func substring(_ i: Int, _ j: Int) -> String {
408:        func isValid(_ i: Int, _ j: Int) -> Bool {
```


### readtap/readtap/ReadTapPDFView.swift
- action_hooks=, methods=63
- methods:
```
15:final class ReadTapPDFView: PDFView, PKCanvasViewDelegate {
16:  enum DrawingInkKind {
21:  enum DrawingEraserKind {
51:  deinit {
61:  func configureDrawingPersistence(bookId: String) {
70:  func prepareDrawingOverlayIfNeeded() {
81:  func setNavigationEnabled(_ enabled: Bool) {
86:  func setLookupSelectionEnabled(_ enabled: Bool) {
94:  func isLookupSelectionActive() -> Bool {
98:  func setDrawingEnabled(_ enabled: Bool) {
121:  func setDrawingLayerVisible(_ visible: Bool) {
129:  func refreshDrawingOverlayNow(maxRetries: Int = 8) {
153:  func setDrawingInkTool(_ kind: DrawingInkKind, color: UIColor) {
166:  func setDrawingEraserTool(_ kind: DrawingEraserKind) {
174:  func drawingUndo() {
179:  func drawingRedo() {
194:  private func refreshDrawingOverlayForCurrentPage() {
223:  private func registerDrawingObserversIfNeeded() {
234:  private func ensureDrawingOverlayProviderAttached(forceRebind: Bool = false) {
245:  private func ensureDrawingCanvasInstalled() {
263:  private func updateDrawingCanvasLayout(syncPage: Bool) -> Bool {
301:  private func drawingHostView() -> UIView {
311:  private func loadDrawingForCurrentPage() {
320:  private func persistCurrentPageDrawing(immediate: Bool) {
340:  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
346:  func installLandscapeSwipeGestures() {
357:  func removeLandscapeSwipeGestures() {
365:  func installZoomedPageSwipe() {
443:  private func canStartPageTurn(at now: Date) -> Bool {
450:  private func isInLandscapeScrollEdge(forward: Bool) -> Bool {
461:  private func animatePageTurn(forward: Bool) {
476:  private func findInternalScrollView() -> UIScrollView? {
525:  private func addMarkup(type: PDFAnnotationSubtype, color: UIColor) {
558:  private func isSameMarkup(_ existing: CGRect, _ target: CGRect) -> Bool {
570:  private func annotationTypeString(for subtype: PDFAnnotationSubtype) -> String {
576:  func forceClearSelection() {
581:  func showLookupHighlight(rect: CGRect) {
622:  private func removeTaggedSubviews(in view: UIView) {
632:  func clearLookupHighlight(immediate: Bool = false) {
674:private final class PDFDrawingOverlayProvider: NSObject, PDFPageOverlayViewProvider,
678:  private final class WeakCanvas {
681:    init(_ canvas: PKCanvasView?) {
696:  func attach(to pdfView: PDFView) {
700:  func setBookId(_ bookId: String) {
714:  func setEnabled(_ enabled: Bool) {
723:  func setVisible(_ visible: Bool) {
731:  func setInkTool(_ kind: ReadTapPDFView.DrawingInkKind, color: UIColor) {
743:  func setEraser(_ kind: ReadTapPDFView.DrawingEraserKind) {
750:  func undo() {
756:  func redo() {
762:  private func currentCanvas() -> PKCanvasView? {
769:  private func visibleCanvases() -> [PKCanvasView] {
774:  func refreshVisibleCanvases() {
785:  func hasCanvasForCurrentPage() -> Bool {
792:  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
811:  func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
824:  func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage)
836:  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
840:  private func applyDrawing(to canvas: PKCanvasView, pageIndex: Int) {
848:  private func persistDrawing(from canvas: PKCanvasView, immediate: Bool) {
855:  private func persist(pageIndex: Int, immediate: Bool) {
876:  private func flushAllPendingPersist() {
883:  func flushPendingPersistNow() {
```


### readtap/readtap/AuthManager.swift
- action_hooks=, methods=5
- methods:
```
9:final class AuthManager: ObservableObject {
16:    private init() {
22:    func signInWithGoogle() async throws {
43:    func signOut() {
63:enum AuthError: LocalizedError {
```


### readtap/readtap/SelectionAdjustOverlay.swift
- action_hooks=5, methods=11
- hooks:
```
82:                            Button(action: onCancel) {
101:                            Button(action: onDone) {
147:        .onAppear {
154:        .onChange(of: containerSize) { _, _ in
184:                .gesture(dragGesture)
```
- methods:
```
3:struct SelectionAdjustOverlay: View {
29:    private enum DragMode {
239:    private func shouldCommitRect(_ candidate: CGRect) -> Bool {
244:    private func isNotEffectivelyEqual(_ lhs: CGRect, to rhs: CGRect, tolerance: CGFloat) -> Bool {
252:    private enum Edge {
256:    private func edgeCaret(_ edge: Edge) -> some View {
276:    private func resizeLeftEdge(start: CGRect, translation: CGSize) -> CGRect {
285:    private func resizeRightEdge(start: CGRect, translation: CGSize) -> CGRect {
293:    private func clampedRect(_ proposed: CGRect) -> CGRect {
322:private struct SelectionHitArea: Shape {
326:    func path(in rect: CGRect) -> Path {
```


### readtap/readtap/PDFDocumentCache.swift
- action_hooks=, methods=18
- methods:
```
4:final class PDFDocumentCache {
13:    private struct CachedDocumentInfo: Equatable {
18:    private struct Stats {
30:    private init() {
41:    func document(for url: URL) -> PDFDocument? {
56:    func set(_ document: PDFDocument, for url: URL) {
65:    func remove(_ url: URL) {
74:    func clearAll(reason: String = "clear-all") {
83:    private func clearStoredFingerprint(for url: URL) {
92:    private func isEntryFresh(for key: CachedDocumentInfo?, at url: URL) -> Bool {
106:    private func cacheKey(for url: URL) -> CachedDocumentInfo? {
116:    private func attachFingerprint(for url: URL) {
124:    func debugSummary() -> String {
142:    func logSummaryIfNeeded(reason: String) {
151:    func recordStaleHit() {
157:    private func updateStats(_ mutation: (inout Stats) -> Void) {
163:    private func estimatedCost(for url: URL, document: PDFDocument) -> Int {
171:    private func configureLimits() {
```


### readtap/readtap/PDFOCRProcessor.swift
- action_hooks=, methods=21
- methods:
```
15:struct PDFOCRWord: Identifiable, Codable {
21:  private enum CodingKeys: String, CodingKey {
28:enum PDFOCRProcessor {
36:  private struct RenderedPage {
43:  private struct OCRPageResult {
48:  enum OCRRenderQuality: Int {
86:  private final class CachedRenderedPage: NSObject {
92:    init(image: UIImage, scale: CGFloat, pageBounds: CGRect, quality: OCRRenderQuality) {
350:  private struct OCRTuningText {
491:  private actor OCRRenderSlotGate {
508:    private func key(_ quality: OCRRenderQuality) -> Int {
512:    func acquire(for quality: OCRRenderQuality) async {
524:    func release(for quality: OCRRenderQuality) {
1074:private actor PDFOCRRecognitionCoalescer {
1075:  private struct CachedOCRResult {
1080:  private struct OCRFailure {
1094:  func run(_ key: String, _ operation: @escaping () async -> [PDFOCRWord]) async -> [PDFOCRWord] {
1134:  private func bumpCacheOrder(_ key: String) {
1141:  private func trimCacheIfNeeded() {
1152:  private func failureRetryDelay(for consecutiveFailures: Int) -> TimeInterval {
1159:  private func pruneFailures(before now: Date) {
```


### readtap/readtap/BookDrawingStore.swift
- action_hooks=, methods=11
- methods:
```
10:final class BookDrawingStore {
18:  private struct DrawingEntry: Codable {
23:  private struct DrawingPayload: Codable {
27:  private init() {}
29:  func load(bookId: String) -> [Int: Data] {
41:  func save(bookId: String, pageIndex: Int, drawingData: Data?) {
57:  func deleteBook(bookId: String) {
66:  private func drawingsDirectory() -> URL {
79:  private func fileURL(for bookId: String) -> URL {
83:  private func readFromDisk(bookId: String) -> [Int: Data] {
92:  private func writeToDisk(_ map: [Int: Data], bookId: String) {
```


### readtap/readtap/ReaderThumbnailSidebar.swift
- action_hooks=6, methods=37
- hooks:
```
471:        .task(id: "\(pageIndex)-\(Int(thumbWidth))") {
580:                                .onAppear {
607:            .onAppear {
617:            .onChange(of: currentPageIndex) { _, newValue in
624:            .onChange(of: pageCount) { _, newValue in
629:            .onDisappear {
```
- methods:
```
13:private actor ThumbnailRenderGate {
18:    init(maxConcurrent: Int = 3) {
22:    func acquire() async {
33:    func release() {
44:final class PDFThumbnailCache {
58:    private struct Stats {
68:    init() {
87:    func clearAll() {
98:    func remove(documentURL: URL) {
120:    func image(documentURL: URL?, page: PDFPage, pageIndex: Int, size: CGSize) -> UIImage {
138:    func cachedImage(documentURL: URL?, pageIndex: Int, size: CGSize) async -> UIImage? {
167:    func storeImage(image: UIImage, documentURL: URL?, pageIndex: Int, size: CGSize) {
200:    func warmupInitialThumbnails(documentURL: URL, pageCountLimit: Int = 8) async {
254:    func withRenderSlot<T>(_ operation: () async -> T) async -> T {
262:    func restoreRenderedWindow(for documentURL: URL?, totalPages: Int) -> Int {
274:    func persistRenderedWindow(for documentURL: URL?, count: Int, totalPages: Int) {
281:    private func imageCacheKey(documentURL: URL?, pageIndex: Int, size: CGSize) -> NSString {
288:    private func canonicalCacheSize(for size: CGSize) -> CGSize {
299:    private func canonicalCacheWidth(for width: CGFloat) -> CGFloat {
312:    private func stateKey(for documentURL: URL) -> String {
316:    private func documentCacheRoot(for documentURL: URL) -> URL {
321:    private func versionCacheRoot(for documentURL: URL) -> URL {
326:    private func diskURL(for documentURL: URL, pageIndex: Int, size: CGSize) -> URL? {
335:    private func warmupTargetSizes() -> [CGSize] {
341:    private func cacheBucketName(for path: String) -> String {
346:    private func readImageFromDisk(at url: URL) async -> UIImage? {
359:    func debugSummary() -> String {
375:    func logSummaryIfNeeded(reason: String) {
384:    private func documentVersionFingerprint(for documentURL: URL?) -> String {
400:private struct ReaderThumbnailCell: View {
476:    private func renderIfNeeded() async {
510:struct PDFThumbnailSidebar: View {
637:    private func clampedRenderWindow(pageCount: Int) -> Int {
647:    private func initialRenderCount(for pageCount: Int) -> Int {
658:    private func persistRenderedWindowHint(totalPages: Int) {
662:    private func ensureRenderedThrough(pageIndex: Int, totalPages: Int) {
694:    private func maybeExpandWindow(around index: Int, totalPages: Int) {
```


### readtap/readtap/WordsTabView.swift
- action_hooks=30, methods=51
- hooks:
```
118:                    .onTapGesture {
139:                    .onTapGesture { cancelDeleteFolderSelection() }
156:        .fullScreenCover(item: $openRequest) { req in
160:        .sheet(item: $openedFolder) { folder in
172:        .alert(renameTitle, isPresented: $isRenamePresented) {
174:            Button(AppText.t(.cancel), role: .cancel) {
178:            Button(renameSaveLabel) {
192:        .onAppear {
246:            .onChange(of: mode) { _, newValue in
249:            .onChange(of: selectedDay) { _, newValue in
255:            .onChange(of: monthDate) { _, newValue in
260:            .onChange(of: centerDay) { _, newValue in
284:            .onChange(of: appSettings.language) { _, _ in
287:            .onChange(of: isActive) { _, newValue in
440:                Button(role: .destructive) {
595:            .onAppear {
611:            .onChange(of: scrollRequestDay) { _, newValue in
628:            .onChange(of: stripDays.count) { _, newCount in
818:                    .onTapGesture {
1475:                    .onTapGesture { endSelectionMode() }
1504:                        Button(role: .destructive) {
1571:        .sheet(item: $flashcardRoute) { route in
1588:        .onAppear {
1593:        .onChange(of: items) { _, newValue in
1597:        .onChange(of: filter) { _, _ in
1600:        .onDisappear {
1723:                Button(role: .destructive) {
1940:        .onTapGesture { onTap() }
2009:                Button(AppText.t(.cancel), role: .cancel, action: onCancel)
2011:                Button(AppText.t(.delete), role: .destructive, action: onDelete)
```
- methods:
```
3:struct WordsTabView: View {
304:    private func configureMonthYearFormatter() {
320:    private func monthKey(for month: Date) -> String {
325:    private func activateIfNeeded() {
502:    private func toggleMode() {
514:    private func stripPill(for day: Date, using proxy: ScrollViewProxy) -> some View {
731:    private func folderRow(for folder: DayBookFolder) -> some View {
834:    private func startFolderSelection(with id: String) {
839:    private func openBooks(for folder: DayBookFolder) {
843:    private func toggleFolderSelection(_ id: String) {
854:    private func endFolderSelection() {
859:    private func beginDelete(_ ids: [String]) {
871:    private func confirmDeleteSelectedFolders() {
903:    private func cancelDeleteFolderSelection() {
908:    private func shouldSkipDeleteConfirmToday() -> Bool {
912:    private func reload() {
935:    private func buildStripDaysIfNeeded() {
970:    private func readFirstBookAddedAt() -> Date? {
978:    private func countForDay(_ day: Date) -> Int {
983:    private func refreshStripBadges(around day: Date) {
1008:    private func refreshMonthBadges(for month: Date) {
1029:    private func goalMet(_ day: Date) -> Bool {
1038:    private func makeFolders(from items: [VocabularyEntry], on day: Date) -> [DayBookFolder] {
1085:    private func readingMarkers(bookId: String, on day: Date) -> (Bool, Bool) {
1093:    private func resetReadingStartIfNeeded(bookId: String, deletedDay: Date?) {
1119:    private func beginRename(_ folder: DayBookFolder) {
1126:    private func applyRenamedTitle(bookId: String, newTitle: String) {
1136:    private func renameBook(bookId: String, newTitle: String, completion: (() -> Void)? = nil) {
1165:private enum WordsDateMode: String {
1170:private struct WordsMonthCalendarView: View {
1360:    private func startedBadge(count: Int) -> some View {
1372:    private func finishedBadge(count: Int) -> some View {
1434:struct DayBookWordsView: View {
1611:    private func openCurrentBook() {
1620:    private func refreshFilteredItems() {
1640:    private func updateLocal(id: Int, state: MasteryState) {
1664:    private func openRequestFor(_ item: VocabularyEntry) -> OpenBookRequest? {
1673:    private func openRequestForCurrentBook() -> OpenBookRequest? {
1689:    private func beginSelectionMode(with id: Int) {
1694:    private func toggleSelection(_ id: Int) {
1705:    private func endSelectionMode() {
1779:    private func deleteSingleItem(_ item: VocabularyEntry) {
1787:    private func toggleSingleMastery(_ item: VocabularyEntry) {
1816:    private func deleteSelected() {
1829:enum MasteryFilter: String, CaseIterable, Identifiable {
1837:private struct FilterBar: View {
1847:    init(selection: Binding<MasteryFilter>, showsBackground: Bool = true) {
1898:    private func title(for option: MasteryFilter) -> String {
1910:private struct WordListRow: View, Equatable {
1949:private struct WordRow: View, Equatable {
1989:private struct WordsTabDeleteFolderConfirmView: View {
```


### readtap/readtap/Models.swift
- action_hooks=, methods=4
- methods:
```
3:enum BookFileType: String {
8:struct Book: Identifiable, Hashable {
19:struct BookRow: Identifiable, Hashable {
30:enum HighlightRole {
```


### readtap/readtap/SplashView.swift
- action_hooks=1, methods=2
- hooks:
```
43:        .onAppear {
```
- methods:
```
3:struct SplashView: View {
74:    private func startFinalTapSequence() {
```


### readtap/readtap/ReadingProgressStore.swift
- action_hooks=, methods=8
- methods:
```
3:final class ReadingProgressStore {
6:    private init() {}
8:    func migrateBookId(from oldBookId: String, to newBookId: String) {
16:    func remove(bookId: String) {
20:    func page(for bookId: String) -> Int? {
29:    func setPage(bookId: String, pageIndex: Int) {
33:    private func save(bookId: String, page: Int?) {
42:    private func keyForBook(_ bookId: String) -> String {
```


### readtap/readtap/OCRWord.swift
- action_hooks=, methods=3
- methods:
```
4:struct MappedWord: Identifiable {
11:struct OCRWord: Identifiable {
17:  init(text: String, boundingBox: CGRect, confidence: Float = 0.55) {
```


### readtap/readtap/AppLanguage.swift
- action_hooks=, methods=3
- methods:
```
3:enum AppLanguage: String, CaseIterable, Identifiable {
52:enum AppString {
230:struct AppText {
```


### readtap/readtap/ReaderSelectionFilter.swift
- action_hooks=, methods=6
- methods:
```
12:struct WordSelection {
22:enum ReaderSelectionFilter {
23:  enum LookupHitProfile {
28:  struct WordSegment {
297:    func substring(_ i: Int, _ j: Int) -> String {
301:    func isValid(_ i: Int, _ j: Int) -> Bool {
```


### readtap/readtap/ReaderViewModel+MeaningHelpers.swift
- action_hooks=, methods=27
- methods:
```
6:extension ReaderViewModel {
8:  func buildCandidateWords(primary: String, normalization: LookupNormalizationResult)
50:  func buildRescueMeaningCandidates(
69:    func add(source: String, target: String) {
149:  func guessSourceForRescue(word: String, sentenceDetected: LanguageDetector.Result)
194:  func containsHangul(_ text: String) -> Bool {
205:  func containsJapaneseKana(_ text: String) -> Bool {
217:  func containsHan(_ text: String) -> Bool {
229:  func isLikelyLatinToken(_ text: String) -> Bool {
256:  func englishSpellingSuggestions(for word: String) -> [String] {
277:  func buildMeaningAlternatives(
292:      func add(_ text: String, _ context: String?) {
361:  func directEngineForCurrentTranslationSetting() -> TranslationEngine? {
367:  func shouldUseEnglishMeaningTemplates(word: String, source: String, target: String)
382:  func translateCandidateMeaning(
407:  func normalizeContextForTranslationCandidate(_ context: String?) -> String? {
424:  func normalizeMeaningForCompare(_ text: String) -> String {
431:  func splitTranslationMeaning(word: String, meaning: String) -> (
473:  func buildMeaningCandidatesFromLookup(
520:  func splitMeaningOptions(_ meaning: String) -> [String] {
559:  func stripLeadingEnumeration(_ text: String) -> String {
586:  func stripWrappingPunctuation(_ text: String) -> String {
598:  func mergeMeaningCandidates(
607:    func add(_ candidate: WordPopupState.MeaningCandidate) {
620:  func contextSnippet(sentence: String, word: String) -> String? {
643:  func formatMeaningForSave(meaning: String, synonyms: [String]) -> String {
653:  func meaningConfidence(
```


### readtap/readtap/ReaderLookupConfig.swift
- action_hooks=, methods=3
- methods:
```
11:enum ReaderLookupLimits {
48:enum ReaderAdjustLimits {
53:enum ReaderLoadingUX {
```


### readtap/readtap/readtapApp.swift
- action_hooks=, methods=2
- methods:
```
13:struct readtapApp: App {
14:    init() {
```


### readtap/readtap/CalloutPopup.swift
- action_hooks=, methods=9
- methods:
```
5:struct CalloutPopup<Content: View>: View {
6:    enum Placement: Equatable {
22:    init(sourceRect: CGRect, scale: CGFloat = 1.0, @ViewBuilder content: () -> Content) {
78:    private func clampedSourceRect(_ sourceRect: CGRect, container: CGSize, insets: EdgeInsets) -> CGRect {
106:    private func choosePlacement(
132:    private func positionedCenter(
161:    private func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
167:private struct SizePreferenceKey: PreferenceKey {
172:private struct MeasureSize: View {
```


### readtap/readtap/PopupPositioning.swift
- action_hooks=, methods=5
- methods:
```
3:struct ClampedPopup<Content: View>: View {
10:    init(anchor: CGPoint, @ViewBuilder content: () -> Content) {
27:    private func clampedPoint(in container: CGSize, insets: EdgeInsets) -> CGPoint {
64:private struct SizePreferenceKey: PreferenceKey {
72:private struct MeasureSize: View {
```


### readtap/readtap/FolderBookPickerView.swift
- action_hooks=6, methods=6
- hooks:
```
74:            Button(action: saveAndClose) {
93:        .toolbar {
95:                Button("Clear") {
102:                EditButton()
105:        .onAppear {
145:        Button(action: action) {
```
- methods:
```
3:struct FolderBookPickerView: View {
114:    private func add(_ id: String) {
120:    private func remove(_ id: String) {
125:    private func moveSelection(from source: IndexSet, to destination: Int) {
129:    private func saveAndClose() {
135:private struct MultipleSelectionRow: View {
```


### readtap/readtap/FolderManagerView.swift
- action_hooks=10, methods=6
- hooks:
```
42:            .toolbar {
46:                        Button("Done") { isNewFieldFocused = false }
53:            .alert(AppLanguage.current() == .korean ? "이름 변경" : "Rename", isPresented: Binding<Bool>(
58:                Button("Cancel", role: .cancel) { renamingFolder = nil }
59:                Button("Save") { saveRename() }
62:            .sheet(item: $editingFolder) { folder in
212:        .onTapGesture {
215:        .contextMenu {
221:            Button(role: .destructive) {
228:            Button(role: .destructive) {
```
- methods:
```
3:struct FolderManagerView: View {
182:    private func folderRow(for folder: BookFolderWithBooks) -> some View {
244:    private func addFolder() {
252:    private func beginRename(_ folder: BookFolderWithBooks) {
257:    private func beginEditBooks(_ folder: BookFolderWithBooks) {
261:    private func saveRename() {
```


### readtap/readtap/FolderChipView.swift
- action_hooks=1, methods=6
- hooks:
```
20:        Button(action: onTap) {
```
- methods:
```
4:struct FolderChipView: View {
80:private struct FolderDropDelegate: DropDelegate {
84:    func dropEntered(info: DropInfo) {
88:    func dropExited(info: DropInfo) {
92:    func dropUpdated(info: DropInfo) -> DropProposal? {
96:    func performDrop(info: DropInfo) -> Bool {
```


### readtap/readtap/LookupPipeline.swift
- action_hooks=, methods=10
- methods:
```
4:enum LookupSource: String, Equatable {
11:enum LookupStage: String, Equatable {
24:struct LookupSession {
35:final class LookupSessionCoordinator {
40:  func startSession(
61:  private func nextSessionIdForFallback() -> LookupSessionID {
69:  func updateSession(sessionId: LookupSessionID, stage: LookupStage, source: LookupSource) {
76:  func isCurrent(sessionId: LookupSessionID, generation: LookupSessionGeneration) -> Bool {
81:  func endCurrentIfNeeded(sessionId: LookupSessionID, generation: LookupSessionGeneration) {
86:  func cancelAllSessions() {
```


### readtap/readtap/LibraryThemePickerView.swift
- action_hooks=1, methods=2
- hooks:
```
46:        Button(action: onTap) {
```
- methods:
```
3:struct LibraryThemePickerView: View {
37:private struct ThemeCard: View {
```


### readtap/readtap/CalendarTabView.swift
- action_hooks=1, methods=1
- hooks:
```
37:            .onAppear { readingStreakDays = BookReadingStatusStore.shared.readingStreak() }
```
- methods:
```
3:struct CalendarTabView: View {
```


### readtap/readtap/ReaderWordbookSheet.swift
- action_hooks=5, methods=7
- hooks:
```
44:                                .onTapGesture {
62:                                    Button(role: .destructive) {
76:            .toolbar {
92:            .sheet(item: $flashcardRoute) { route in
106:        .onAppear { reload() }
```
- methods:
```
10:struct ReaderWordbookSheet: View {
159:    private func reload() {
163:    private func updateLocal(id: Int, state: MasteryState) {
176:    private func toggleMastery(_ item: VocabularyEntry) {
183:    private func deleteItem(_ item: VocabularyEntry) {
192:    private func filterTitle(for option: MasteryFilter) -> String {
207:private struct WordbookRow: View {
```


### readtap/readtap/BookReadingStatusStore.swift
- action_hooks=, methods=52
- methods:
```
3:struct BookStatusEntry: Hashable {
10:struct ReadingDayEntry: Hashable {
18:final class BookReadingStatusStore {
21:    private init() {}
26:    func startedAt(bookId: String) -> Date? {
30:    func finishedAt(bookId: String) -> Date? {
34:    func ensureStarted(bookId: String, now: Date = Date()) {
52:    func markWordsSaved(_ count: Int, on day: Date = Date()) {
63:    func markReadingMinutes(_ minutes: Int, on day: Date = Date()) {
74:    func didMeetDailyGoal(on day: Date = Date()) -> Bool {
80:    func resetDayMetrics(before day: Date = Date()) {
89:    func wordsSaved(on day: Date) -> Int {
93:    func readingMinutes(on day: Date) -> Int {
97:    func readingStreak(asOf day: Date = Date()) -> Int {
112:    func toggleFinished(bookId: String, now: Date = Date()) {
128:    func resetStarted(bookId: String) {
135:    func restartReading(bookId: String, now: Date = Date()) {
146:    func removeBook(bookId: String) {
158:    func startedCountsByDayKey(from start: Date, to end: Date) -> [String: Int] {
175:    func finishedCountsByDayKey(from start: Date, to end: Date) -> [String: Int] {
192:    func migrateBookId(from oldBookId: String, to newBookId: String) {
226:    func resetStartedForDay(_ day: Date) {
245:    func resetFinishedForDay(_ day: Date) {
264:    private func startedKey(_ bookId: String) -> String {
268:    private func finishedKey(_ bookId: String) -> String {
272:    private func firstStartedAtKey(_ bookId: String) -> String {
276:    private func firstStartedAt(bookId: String) -> Date? {
280:    private func setFirstStartedAt(bookId: String, date: Date) {
284:    private func upsertKnownBookId(_ bookId: String) {
290:    private func cleanKnownBookId(_ bookId: String) {
300:    private func knownBookIds() -> [String] {
310:    func allKnownBookIds() -> [String] {
314:    func allKnownDayKeys() -> [String] {
318:    func resetAll() {
340:    func reconcileDayMetricsAfterBookDeletion() {
379:    private func hasBookActivity(on day: Date, calendar: Calendar) -> Bool {
394:    func bookStatusUpdatedAt(bookId: String) -> Date? {
398:    func dayUpdatedAt(dayKey: String) -> Date? {
402:    func bookStatusEntries(since date: Date?) -> [BookStatusEntry] {
418:    func readingDayEntries(since date: Date?) -> [ReadingDayEntry] {
435:    func applyBookStatusFromRemote(bookId: String, startedAt: Date?, finishedAt: Date?, updatedAt: Date) {
459:    func applyReadingDayFromRemote(dayKey: String, wordsSaved: Int, minutesRead: Int, updatedAt: Date) {
471:    private func setDate(_ date: Date, forKey key: String) {
475:    private func date(forKey key: String) -> Date? {
482:    private func notifyChanged() {
486:    private func wordsKey(_ day: Date) -> String {
490:    private func minutesKey(_ day: Date) -> String {
519:    private func bookStatusUpdatedAtKey(_ bookId: String) -> String {
523:    private func dayUpdatedAtKey(_ dayKey: String) -> String {
527:    private func touchBookStatus(_ bookId: String, at date: Date) {
531:    private func touchDay(_ dayKey: String, at date: Date) {
535:    private func upsertKnownDayKey(_ dayKey: String) {
```


### readtap/readtap/OrderKey.swift
- action_hooks=, methods=1
- methods:
```
4:enum OrderKey {
```


### readtap/readtap/VocabularyListView.swift
- action_hooks=4, methods=8
- hooks:
```
35:                                Button(role: .destructive) {
62:            .onAppear {
68:            .fullScreenCover(item: $openRequest) { req in
154:        .onTapGesture {
```
- methods:
```
3:struct VocabularyListView: View {
76:    private func wordRow(_ item: VocabularyEntry) -> some View {
165:    private func masteryColor(_ mastery: MasteryState) -> Color {
174:    private func masteryIcon(_ mastery: MasteryState) -> some View {
193:    private func deleteItem(_ item: VocabularyEntry) {
200:    private func toggleMastery(_ item: VocabularyEntry) {
228:    private func openRequestFor(_ item: VocabularyEntry) -> OpenBookRequest? {
237:    private func itemDateText(_ date: Date) -> String {
```


### readtap/readtap/OCRTuning.swift
- action_hooks=, methods=1
- methods:
```
6:enum OCRTuning {
```


### readtap/readtap/WordPopupView.swift
- action_hooks=1, methods=15
- hooks:
```
368:      .onAppear {
```
- methods:
```
10:struct WordPopupState: Equatable {
11:  enum MeaningSource: String {
21:  enum MeaningConfidence: Int {
28:  struct MeaningCandidate: Equatable, Identifiable {
34:    init(word: String, meaning: String, synonyms: [String]) {
63:struct WordPopupView: View {
76:  init(
236:  private struct PopupActionItem: Identifiable {
283:  private func actionsRow<C: Collection>(_ actions: C) -> some View
341:private struct PopupCandidateButtonStyle: ButtonStyle {
344:  func makeBody(configuration: Configuration) -> some View {
362:private struct ShimmerEffect: ViewModifier {
365:  func body(content: Content) -> some View {
376:  struct AnimatedMask: AnimatableModifier {
384:    func body(content: Content) -> some View {
```


### readtap/readtap/ReaderViewModel.swift
- action_hooks=, methods=11
- methods:
```
7:final class ReaderViewModel: ObservableObject {
70:  func toggleChrome() {
79:  func resetChromeToggleState() {
84:  func dismissPopup() {
90:  func resetPrefetchState() {
113:  func beginReaderSession() {
134:  func prepareForReaderExit() {
184:  func beginCorrectionFlow() {
197:  func currentLookupRectOnView() -> CGRect? {
207:  func currentLookupPageIndex() -> Int {
211:  func setPopupIfNeeded(_ next: WordPopupState?) {
```


### readtap/readtap/HomeView.swift
- action_hooks=36, methods=80
- hooks:
```
80:            .toolbar(.hidden, for: .navigationBar)
88:            .onChange(of: isImportDialogPresented) { _, isOpen in
91:            .onChange(of: isImportLoadingActive) { _, _ in
94:            .onDisappear {
101:            .confirmationDialog("Add Book", isPresented: $isImportDialogPresented, titleVisibility: .visible) {
102:                Button("Import PDF") {
105:                Button("Import from Photos") {
108:                Button("Scan Document") {
111:                Button("Cancel", role: .cancel) {}
146:            .sheet(item: $activeImportSheet) { sheet in
174:            .task(id: isActive) {
191:            .fullScreenCover(item: $readerSelection, onDismiss: { readerSelection = nil }) { selection in
211:            .alert("Rename", isPresented: $isRenamePresented) {
213:                Button("Cancel", role: .cancel) {}
214:                Button("Save") {
222:            .alert("Import failed", isPresented: Binding(
226:                Button("OK", role: .cancel) {}
230:            .confirmationDialog(deleteConfirmTitle, isPresented: $isDeleteConfirmPresented, titleVisibility: .visible) {
231:                Button(deleteConfirmBookAndWordsLabel, role: .destructive) {
238:                Button(deleteConfirmBookOnlyLabel, role: .destructive) {
245:                Button("Cancel", role: .cancel) {}
247:            .sheet(item: $folderSheetBook) { book in
262:            .sheet(isPresented: $isFolderManagerPresented) {
287:            .sheet(isPresented: $isSharePresented) {
533:                Button(role: .destructive) {
925:                    .onTapGesture { openBook(book) }
982:                    Button("Import PDF", systemImage: "doc") {
985:                    Button("Import from Photos", systemImage: "photo.on.rectangle") {
988:                    Button("Scan Document", systemImage: "doc.text.viewfinder") {
1106:        Button(action: action) {
1423:        .task(id: book.coverImagePath) {
1671:        Button(action: action) {
1774:        Button(action: action) {
1828:                Button("닫기") {
1843:                Button("삭제") {
1879:        Button(action: action) {
```
- methods:
```
8:struct HomeView: View {
17:    private struct ReaderSelection: Identifiable {
22:    private enum ImportSheet: String, Identifiable {
340:    private struct GridMetrics {
347:    private func gridMetrics(for totalWidth: CGFloat) -> GridMetrics {
633:    private func startImport(images: [UIImage], imageURL: URL?, preview: UIImage?) {
687:    private struct ImageImportPayload {
693:    private func beginPDFImport(from url: URL) {
725:    private func prepareImageImportPayload(images: [UIImage], imageURL: URL?, preview: UIImage?) async throws -> ImageImportPayload {
778:    private func cleanupFile(_ url: URL) {
784:    private func loadFullImage(from url: URL, fallback: UIImage?) -> UIImage? {
794:    private func booksGrid(
839:    private func deleteSelectedBooks(deleteAssociatedData: Bool) {
850:    private func moveSelectedBooksToFolder(_ folderId: String) {
861:    private func duplicateSelectedBook(_ book: BookRow) async {
894:    private func bookCard(for book: BookRow, itemWidth: CGFloat, itemHeight: CGFloat) -> some View {
937:    private func startBookSelection(with id: String) {
944:    private func toggleBookSelection(_ id: String) {
957:    private func openBook(_ book: BookRow) {
1072:    private func summaryIconCount(systemName: String, value: Int, tint: Color) -> some View {
1101:    private func refreshTodayCounts() {
1105:    private func filterChip(icon: String? = nil, label: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
1138:    private func folderChip(_ folder: BookFolderWithBooks, isSelected: Bool) -> some View {
1160:    private func loadFolders() {
1164:    private func reloadFoldersAndBooks() {
1184:    private func requestImport(_ request: ImportRequest) {
1203:    private enum ImportRequest {
1209:    private func closeImportPickers() {
1214:    private func handlePhotoPickerFailure(_ error: Error) {
1219:    private func createFolder(named name: String) -> BookFolderWithBooks {
1236:    private func handleDrop(providers: [NSItemProvider], folderId: String) -> Bool {
1255:    private func handleReorder(dragId: String, targetId: String) {
1276:    private func move(_ ids: inout [String], from dragId: String, to targetId: String) {
1283:    private func highlight(for id: String, isHovered: Bool) -> HighlightRole? {
1288:    private func reorderFolders(dragId: String, targetId: String) {
1306:private struct BookCardView: View {
1433:    private func loadCoverIfNeeded() async {
1489:    private func lastAccessDescription(_ date: Date) -> String {
1496:private final class CoverImageCache {
1505:    func image(for path: String) -> UIImage? {
1509:    func insert(_ image: UIImage, for path: String) {
1514:private enum AddMenuStyle {
1520:private struct RadialAddMenu: View {
1590:private struct ExpandAddMenu: View {
1661:private struct ExpandMenuItem: View {
1696:private struct BubbleAddMenu: View {
1764:private struct BubbleMenuItem: View {
1799:private struct BubblePointer: Shape {
1800:    func path(in rect: CGRect) -> Path {
1810:private struct UnsupportedImageBookView: View {
1867:private struct RadialMenuItem: View {
1903:private enum ImportStage {
1923:private extension HomeView {
1925:    func beginImportLoading(with stage: ImportStage) {
1942:    func endImportLoading() {
1948:    func refreshImportOverlayVisibility() {
2000:private struct ImportingOverlay: View {
2042:private struct DocumentScannerView: UIViewControllerRepresentable {
2046:    func makeCoordinator() -> Coordinator {
2050:    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
2056:    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
2058:    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
2062:        init(onComplete: @escaping (Result<[UIImage], Error>) -> Void, onCancel: @escaping () -> Void) {
2067:        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
2075:        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
2083:        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
2102:private enum DocumentScanError: LocalizedError {
2114:private struct PhotoPickerView: UIViewControllerRepresentable {
2118:    func makeCoordinator() -> Coordinator {
2122:    func makeUIViewController(context: Context) -> PHPickerViewController {
2131:    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
2133:    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
2137:        init(onComplete: @escaping (Result<PhotoPickPayload, Error>) -> Void, onCancel: @escaping () -> Void) {
2142:        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
2180:private enum PhotoPickerError: LocalizedError {
2191:private struct PhotoPickPayload {
2196:private func makeThumbnail(from url: URL, maxPixel: CGFloat) -> UIImage? {
2210:struct ShareSheet: UIViewControllerRepresentable {
2214:    func makeUIViewController(context: Context) -> UIActivityViewController {
2222:    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
```


### readtap/readtap/VocabularyByBookView.swift
- action_hooks=18, methods=36
- hooks:
```
66:                    .onTapGesture {
111:            .onAppear { if isActive { reload() } }
112:            .onChange(of: isActive) { _, active in
120:                    .onTapGesture { cancelDelete() }
144:        .fullScreenCover(item: $openRequest) { req in
148:        .onAppear {
152:        .onChange(of: folders) { _, _ in
156:        .onChange(of: folderSections) { _, _ in
159:        .onChange(of: searchText) { _, _ in
162:        .onChange(of: filter) { _, _ in
165:        .onChange(of: sortMode) { _, _ in
168:        .onChange(of: groupByFolder) { _, _ in
171:        .onChange(of: openFromReaderRequest) { _, newRequest in
196:            Button(role: .destructive) {
1147:                .contextMenu {
1164:        .fullScreenCover(item: $openRequest) { req in
1290:                Button(AppText.t(.cancel), role: .cancel, action: onCancel)
1292:                Button(AppText.t(.delete), role: .destructive, action: onDelete)
```
- methods:
```
3:struct VocabularyByBookView: View {
31:    init() {
36:    func with(isActive: Bool = true, openFromReaderRequest: OpenWordsTabRequest? = nil) -> VocabularyByBookView {
421:    private func attemptReaderFolderOpen(using request: OpenWordsTabRequest? = nil) {
443:    private func folder(forReaderRequest request: OpenWordsTabRequest) -> VocabBookFolder? {
468:    private func folder(forReaderMatchKeys keys: Set<String>) -> VocabBookFolder? {
476:    private func readerFolderMatchKeys(for folder: VocabBookFolder) -> Set<String> {
485:    private func readerBookIdMatchKeys(for rawBookId: String) -> Set<String> {
529:    private func normalizedTitleCandidates(for title: String) -> Set<String> {
540:    private func titleCandidatesMatch(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
551:    private func recomputeVisibleData() {
570:    private func applyFilters(to folder: VocabBookFolder) -> VocabBookFolder? {
600:    private func applySort(to list: [VocabBookFolder]) -> [VocabBookFolder] {
611:    private func sectionHeader(_ section: VocabFolderSection) -> some View {
639:    private func enterSelectionMode(selecting folder: VocabBookFolder) {
645:    private func folderRow(for folder: VocabBookFolder) -> some View {
737:    private func exitSelectionMode() {
742:    private func beginDelete(folders: [VocabBookFolder]) {
753:    private func confirmDelete() {
778:    private func cancelDelete() {
783:    private func shouldSkipDeleteConfirmToday() -> Bool {
787:    private func toggleSelection(_ folder: VocabBookFolder) {
798:    private func pruneSelectionToVisibleFolders() {
810:    private func reload() {
1093:    private func resetReadingStartIfNeeded(bookId: String, earliestBeforeDelete: Date?) {
1111:private struct VocabularyListDetailView: View {
1170:    private func openRequestFor(_ item: VocabularyEntry) -> OpenBookRequest? {
1180:private struct VocabFolderSection: Identifiable, Equatable {
1188:private struct VocabBookFolder: Identifiable, Equatable {
1221:    func withFiltered(items: [VocabularyEntry]) -> VocabBookFolder {
1238:private enum VocabBookFilter: String, CaseIterable, Identifiable {
1254:private enum VocabBookSort: String, CaseIterable, Identifiable {
1270:private struct DeleteFolderConfirmView: View {
1318:struct BookCoverThumbnail: View {
1351:struct MasteryProgressBar: View {
1375:struct WordCountBadge: View {
```


### readtap/readtap/AppWarmup.swift
- action_hooks=, methods=6
- methods:
```
8:final class AppWarmup {
17:    private init() {}
19:    func warmUpIfNeeded(progress: @escaping @Sendable (String) -> Void) async {
41:    func warmUpIfNeeded() {
47:    func consumeFirstRunInteractionPriority() -> Bool {
60:        func report(_ message: String) async {
```


### readtap/readtap/ReaderChromeStateMachine.swift
- action_hooks=, methods=2
- methods:
```
3:struct ReaderChromeToggleResult: Equatable {
12:enum ReaderChromeStateMachine {
```


### readtap/readtap/AppSettings.swift
- action_hooks=, methods=9
- methods:
```
4:enum PopupSizeMode: String, CaseIterable {
20:final class AppSettings: ObservableObject {
32:    private init() {
84:    func setTheme(_ newTheme: LibraryTheme) {
89:    func setLanguage(_ newLanguage: AppLanguage) {
94:    func setAutoSave(_ enabled: Bool) {
99:    func setReaderLongPress(_ enabled: Bool) {
104:    func setTranslationTarget(_ target: String) {
109:    func setWordPopupSizeMode(_ mode: PopupSizeMode) {
```


### readtap/readtap/AppFeatures.swift
- action_hooks=, methods=1
- methods:
```
3:enum AppFeatures {
```


### readtap/readtap/StreakCalendarView.swift
- action_hooks=3, methods=7
- hooks:
```
24:                    .onTapGesture { isPresented = false }
59:        .onAppear { readingStreakDays = BookReadingStatusStore.shared.readingStreak() }
191:                Button(action: onClose) {
```
- methods:
```
3:struct StreakCalendarOverlay: View {
50:struct StreakCalendarOverlayAuto: View {
66:struct StreakCalendarView: View {
301:    private func startedBadge(count: Int) -> some View {
314:    private func finishedBadge(count: Int) -> some View {
457:    private func localeForAppLanguage() -> Locale {
462:private struct GoalStatus {
```


### readtap/readtap/SettingsView.swift
- action_hooks=13, methods=12
- hooks:
```
123:        .toolbar(.hidden, for: .navigationBar)
124:        .onChange(of: appSettings.language) { _, _ in
131:            NavigationLink(destination: LibraryThemePickerView()) {
235:        .toolbar(.hidden, for: .navigationBar)
236:        .alert("Sign-in Failed", isPresented: Binding(
240:            Button("OK", role: .cancel) {}
244:        .onChange(of: appSettings.language) { _, _ in
258:                Button(role: .destructive) {
301:            NavigationLink(destination: LibraryThemePickerView()) {
427:                Button(AppText.t(.save)) {
450:                Button(AppText.t(.clear)) {
470:        .onAppear {
529:                    Button(role: .destructive) {
```
- methods:
```
4:struct SettingsView: View {
16:private struct GlassSection<Content: View>: View {
26:    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
63:private struct SettingsRow<Trailing: View>: View {
72:    init(icon: String, title: String, @ViewBuilder trailing: () -> Trailing) {
97:private struct LocalSettingsView: View {
191:    private func popupSizeLabel(_ mode: PopupSizeMode) -> String {
205:private struct CloudSettingsView: View {
361:    private func popupSizeLabel(_ mode: PopupSizeMode) -> String {
376:private struct ContextServerSettingsView: View {
481:private struct KoreanDictSettingsSection: View {
564:    private func saveDictKey() {
```


### readtap/readtap/FolderPickerSheet.swift
- action_hooks=6, methods=4
- hooks:
```
85:            .toolbar {
97:                    Button("Done") {
118:                        Button("완료") {
124:            .onTapGesture {
128:        .onAppear {
172:        Button(action: action) {
```
- methods:
```
3:struct FolderPickerSheet: View {
134:    private func toggle(_ id: String) {
142:    private func addFolder() {
162:    private struct MultipleSelectionRow: View {
```


### readtap/readtap/ImageReaderView.swift
- action_hooks=13, methods=138
- hooks:
```
93:    .onChange(of: viewModel.popup) { _, newValue in
98:    .onAppear {
104:    .onChange(of: viewModel.image) { _, _ in
110:    .onDisappear {
114:    .onChange(of: scenePhase) { _, phase in
117:    .sheet(isPresented: $isWordbookPresented) {
120:    .sheet(isPresented: $isManualEntryPresented) {
143:        .toolbar {
145:            Button(AppText.t(.cancel)) { cancelManualEntry() }
148:            Button(AppText.t(.done)) { commitManualEntry() }
154:    .alert("조정 영역 오류", isPresented: shouldPresentAdjustBoxError) {
155:      Button(AppText.t(.cancel), role: .cancel) {
201:            .onTapGesture {
```
- methods:
```
8:enum ImageLookupLimits {
22:struct ImageReaderView: View {
163:  private struct DisplayLayout {
168:  private func computeLayout(uiImage: UIImage, size: CGSize) -> DisplayLayout {
182:  private func canvas(size: CGSize) -> some View {
216:  private func imageLayer(uiImage: UIImage, displayFit: CGRect) -> some View {
227:  private func highlightLayer(uiImage: UIImage, displayFit: CGRect) -> some View {
311:  private func ocrOverlay(uiImage: UIImage, layout: DisplayLayout, size: CGSize) -> some View {
348:  private func popupLayer(uiImage: UIImage, displayFit: CGRect) -> some View {
372:  private func adjustOverlay(uiImage: UIImage, displayFit: CGRect, size: CGSize) -> some View {
396:  private func aspectFit(imageSize: CGSize, containerSize: CGSize) -> CGRect {
407:  private func scaledFitRect(_ rect: CGRect, scale: CGFloat, offset: CGSize) -> CGRect {
416:  private func clampOffset(
430:  private func magnificationGesture(baseFit: CGRect, containerSize: CGSize) -> some Gesture {
456:  private func clampRect(_ rect: CGRect) -> CGRect {
464:  private func startBoxAdjust() {
477:  private func cancelBoxAdjust() {
486:  private func commitBoxAdjust(uiImage: UIImage, displayFit: CGRect) {
549:  private func commitCommitRetryRect(from source: CGRect) -> CGRect {
562:  private func shrinkRectToMaxArea(_ source: CGRect, maxArea: CGFloat) -> CGRect {
574:  private func centeredRect(_ source: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
586:  private func startManualEntry() {
597:  private func cancelManualEntry() {
606:  private func commitManualEntry() {
637:  private func maxAdjustedPhraseWords(for rect: CGRect) -> Int {
647:  private func phraseFromWords(
663:    func phraseCandidateScore(_ word: OCRWord) -> Double {
702:    struct Line {
708:      init(item: OCRWord) {
753:    func verticalDistance(from y: CGFloat, to minY: CGFloat, _ maxY: CGFloat) -> CGFloat {
855:      func overlaps(_ lhs: OCRWord, _ rhs: OCRWord) -> Bool {
925:  private func panGesture(baseFit: CGRect, containerSize: CGSize) -> some Gesture {
945:func mapNormalizedRectToViewRect(_ normalized: CGRect, imageSize: CGSize, fitRect: CGRect)
962:func normalizedPoint(from viewPoint: CGPoint, fitRect: CGRect) -> CGPoint? {
971:func normalizedRect(from viewRect: CGRect, fitRect: CGRect) -> CGRect? {
985:final class ImageReaderViewModel: ObservableObject {
1017:  private struct CachedImageLookupResult {
1038:  private enum OCRLanguageHint {
1049:  private struct OCRRetryState {
1054:  private func updateLanguageHint(from words: [OCRWord]) {
1122:  private func chineseRecognitionLanguages(for text: String) -> [String] {
1134:  private func containsHangul(_ text: String) -> Bool {
1145:  private func containsJapaneseKana(_ text: String) -> Bool {
1157:  private func containsHan(_ text: String) -> Bool {
1169:  private func isLikelyLatinToken(_ text: String) -> Bool {
1184:  private func isMostlyLatinText(_ text: String) -> Bool {
1199:  func load(imageURL: URL, bookId: String) {
1226:    func tryLoad(retryCount: Int) {
1270:  func loadSavedHighlights() {
1285:  private func setSavedHighlight(entryId: Int, rect: CGRect) {
1291:  private func clearSavedHighlights() {
1295:  private func removeSavedHighlight(entryId: Int) {
1302:  private func preparedOrientedCIImage(for image: UIImage) -> CIImage? {
1315:  private func imageFingerprint(for url: URL) -> String {
1386:  func select(word: String, normalizedBox: CGRect, anchor: CGPoint, forceSave: Bool = false) {
1598:  private func makePopupState(
1628:  private func persistLookupResultIfNeeded(
1677:  func saveFromPopup() {
1704:  func dismissPopup() {
1710:  func beginCorrectionFlow() {
1728:  func refinePopupAccuracy() {
1956:  func handleLongPress(at location: CGPoint, imageSize: CGSize, fitRect: CGRect) {
2102:  private func shouldUseCachedSelection(_ candidate: OCRWordCandidate) -> Bool {
2107:  private func roiCandidatesForPress(at point: CGPoint, words: [OCRWord]) -> [CGRect] {
2116:  private func roiCandidatesAroundTextBox(_ boundingBox: CGRect) -> [CGRect] {
2128:  private func shouldAcceptLongPress(signature: String, at timestamp: Date) -> Bool {
2141:  private func makeLongPressSignature(
2163:  private func expandNormalizedRect(_ rect: CGRect, factor: CGFloat) -> CGRect {
2175:  private func runOCR(on image: UIImage) {
2231:  private func performOCRSequence(
2245:    func runNext(modeIndex: Int, best: OCRResult) {
2282:  private func buildFullOCRExecutionPlan(
2295:    func addStep(_ step: (mode: OCRMode, regions: [CGRect]?, languages: [String]?)) {
2334:  private func shouldRunBinarizedPass(languages: [String]) -> Bool {
2341:  private func tryLanguageAdaptiveRetryIfNeeded(
2365:    func run(attempt: Int, current: OCRResult) {
2401:  private func isHighQualityOCRResult(_ result: OCRResult) -> Bool {
2424:  private struct CachedImageOCRResult {
2429:  private struct ImageOCRCacheKey: Hashable {
2436:  private enum OCRMode: Hashable {
2445:  private struct OCRResult {
2450:  private struct OCRResultText {
2456:  private struct OCRSelection {
2464:  private struct OCRWordCandidate {
2470:  private func performROISelection(
2481:    func runNext(index: Int, best: OCRSelection?) {
2532:  private func ocrSelectionModes(for languages: [String]) -> [OCRMode] {
2555:  private func performROISelection(
2573:  private func shouldFinishSelection(_ selection: OCRSelection) -> Bool {
2583:  private func shouldFinishSelection(_ selection: OCRSelection, mode: OCRMode) -> Bool {
2604:  private func imageSelectionContext(selectedWord: String, selectedBox: CGRect, words: [OCRWord])
2647:  private func normalizeImageContextToken(_ text: String) -> String {
2660:  private func normalizeImageContextText(_ text: String) -> String {
2669:  private func performOCR(
2766:  private func performOCR(
2787:  private func requestIDMatchesLatestOCR(_ requestID: Int?) -> Bool {
2792:  private func markOCRRequestCompleted(
2813:  private func tryScheduleOCRRetry(
2862:  private func isImageOCRRetryAllowed(for fingerprint: String) -> Bool {
2876:  private func makeImageOCRCacheKey(
2890:  private func touchImageOCRCache(accessing key: ImageOCRCacheKey) {
2903:  private func ocrLanguageSignature(_ languages: [String]) -> String {
2912:  private func ocrRegionSignature(_ regions: [CGRect]?) -> Int {
2925:  private func requestIDMatchesLatestFallbackOCR(_ requestID: Int?) -> Bool {
2930:  private func imageLookupResultKey(
2959:  private func cachedLookupMeaning(for key: String) -> String? {
2973:  private func storeLookupMeaning(_ meaning: String, for key: String) {
2983:  private func touchImageLookupMeaningCache(accessing key: String) {
2996:  private func roiCandidates(around point: CGPoint) -> [CGRect] {
3014:  private func nearestWord(to point: CGPoint, in words: [OCRWord]) -> OCRWordCandidate? {
3029:    func scoreWord(_ candidate: WordSnap.Item<OCRWord>) -> Float {
3041:  private func distanceFrom(_ point: CGPoint, to rect: CGRect) -> CGFloat {
3057:    func clampRect(_ rect: CGRect) -> CGRect {
3065:    func mapRect(_ rect: CGRect, within region: CGRect) -> CGRect {
3074:    func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
3082:    func dedupe(_ words: [OCRWord]) -> [OCRWord] {
3174:  private func bestResult(_ results: [OCRResult]) -> OCRResult {
3178:  private func score(_ result: OCRResult) -> Float {
3184:  private func hasAtLeastTwoScriptFamilies(_ languages: [String]) -> Bool {
3196:  private func ocrAdaptiveRetryLanguages(base: [String], sampleText: String) -> [[String]] {
3210:  private func normalizeOCRLanguageList(_ languages: [String]) -> [String] {
3226:  private func languageFallbackPlans(for baseLanguages: [String], sampleText: String) -> [[String]]
3292:  private func ocrRecognitionLanguageHint(for token: String) -> [String]? {
3345:  private func ocrRecognitionLanguages(for token: String? = nil) -> [String] {
3400:  private func enhancedCIImage(from image: UIImage) -> CIImage? {
3449:  private func normalizedCIImage(from image: UIImage) -> CIImage? {
3515:  private func binarizedCIImage(from image: UIImage) -> CIImage? {
3840:  func teardown() {
3873:  deinit {
3881:private func detectTextRegions(in image: CIImage) -> [CGRect] {
3905:private func clampRect(_ rect: CGRect) -> CGRect {
3913:private func expandRect(_ rect: CGRect, by padding: CGFloat) -> CGRect {
3918:private func mergeRects(_ rects: [CGRect]) -> [CGRect] {
3944:private func rectsShouldMerge(_ a: CGRect, _ b: CGRect) -> Bool {
3965:private func upscaledCIImage(_ image: CIImage) -> CIImage {
3987:private func normalizeImageSelectionText(_ text: String) -> String {
4003:private func ocrWords(
4011:  struct Pending {
```


### readtap/readtap/PDFKitView.swift
- action_hooks=1, methods=154
- hooks:
```
1418:            // prefetch는 ContentView.onChange(of: currentPageIndex)에서
```
- methods:
```
6:struct PDFKitView: UIViewRepresentable {
7:    private enum Timing {
40:    private enum Threshold {
46:    private enum Gesture {
57:        private enum LookupPoint {
97:        private enum FirstLookupWarmup {
101:    private enum Layout {
106:    private enum PagePrefetch {
146:    func makeCoordinator() -> Coordinator {
165:    func makeUIView(context: Context) -> PDFView {
195:    func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
206:    func updateUIView(_ pdfView: PDFView, context: Context) {
280:        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
281:        private enum GestureMode: Equatable {
287:        private enum GestureRuntimePhase: Equatable {
294:        private struct GestureState: Equatable {
305:        private struct GestureRefreshSignature: Equatable {
321:            init(
482:        private func startLookupSession() -> UInt64 {
498:        private func isLookupSessionCurrent(_ sessionId: UInt64) -> Bool {
503:        private func currentLookupPageIndex(for pdfView: PDFView) -> Int {
508:        private func isLookupSessionUsable(_ sessionId: UInt64) -> Bool {
516:        private func endLookupSession() {
527:        private func cancelLookupSessionEndTimer() {
532:        private func invalidateLookupSessionForPageChange() {
551:        private func scheduleLookupSessionEnd(
582:        private struct LayoutSignature: Equatable {
587:        private struct PendingPageTurn: Equatable {
592:            enum Direction: Equatable {
598:        init(onSelection: @escaping (WordSelection, PDFView) -> Void,
631:        func updateCallbacks(
647:        func attach(to pdfView: PDFView) {
746:        fileprivate func areGesturesDetached() -> Bool {
753:        fileprivate func consumePendingGestureReactivation() -> Bool {
761:        fileprivate func detach(from pdfView: PDFView?) {
898:        private func pendingDocumentLoadGeneration() {
913:        private func bypassInitialLookupWarmup() {
926:        private func clearDocumentLoadInFlight(for requestToken: Int) {
934:        private func enqueueStateMutation(_ mutation: @escaping () -> Void) {
951:        private func queueBindingValue<T: Equatable>(_ binding: Binding<T>, to value: T) {
959:        fileprivate func queueStateMutation(_ mutation: @escaping () -> Void) {
963:        private func lastLookupTaskReset() {
980:        func reapplyZoomAfterLayout() {
990:        deinit {
995:        func updateInteractionMode(_ mode: ReaderInteractionMode, using pdfView: PDFView) {
1011:        func updateInteractionIfNeeded(
1033:        fileprivate func reactivateGesturesAfterReopen(using pdfView: PDFView) {
1077:        fileprivate func ensureGesturesHealthy(using pdfView: PDFView) {
1134:        private func desiredGestureRuntimePhase() -> GestureRuntimePhase {
1147:        private func transitionGestureRuntime(to next: GestureRuntimePhase, using pdfView: PDFView?) {
1154:        private func isSingleTapRuntimeEnabled() -> Bool {
1161:        private func isLongPressRuntimeEnabled() -> Bool {
1165:        private func shouldAllowSingleTapFlow() -> Bool {
1172:        private func shouldAllowLookupFlow() -> Bool {
1178:        func gestureRecognizer(
1193:        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
1203:        func gestureRecognizer(
1216:        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
1257:        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
1480:        private func goToNextPage(preserving ratio: CGFloat) {
1487:        private func goToPreviousPage(preserving ratio: CGFloat) {
1529:        private func clampedZoomRatio(_ raw: CGFloat) -> CGFloat {
1533:        private func normalizedZoomRatio(_ raw: CGFloat) -> CGFloat {
1538:        private func applyZoomRatio(_ ratio: CGFloat, resetPosition: Bool) {
1574:        private func resetViewportToTopLeft() {
1608:        private func processSelectionChanged() {
1967:        private func performLookupForLongPress(
2077:        private func performLookupForLongPress(
2090:        private func scheduleDebouncedLookup(
2135:        private func setLookupLongPressEnabled(_ enabled: Bool, lookupInteractionReady: Bool) {
2259:        private func setLookupLongPressEnabled(_ enabled: Bool) {
2263:        private func performLookup(
2406:        private func requestOCRLookupProbe(
2421:        private func lookupFallback(from location: CGPoint, in pdfView: PDFView) -> WordSelection? {
2427:        private func performDeferredOCRFallback(
2491:        private func lookupCandidateLimit(
2510:        private func shouldAttemptLookupFallback(at location: CGPoint) -> Bool {
2536:        private func lookupBounds(for page: PDFPage) -> CGRect? {
2559:        private func lookupCandidatePoints(
2597:        private func lookupPointKey(for point: CGPoint) -> UInt64 {
2606:        private func lookupSignatureQuantizedCoordinate(_ value: CGFloat) -> Int {
2613:        private func lookupSignatureComponentString(_ point: CGPoint) -> String {
2617:        private func performLookupCandidate(
2735:        private func pickWordSelectionFromPoint(
2778:        private func emitLookupSelection(
2799:        func updateLayoutIfNeeded(using pdfView: PDFView) {
2863:        private func scheduleLookupPressRecovery(timeout: TimeInterval) {
2897:        private func resetLookupPressState(force: Bool = false, preserveDismissHint: Bool = false) {
2937:        private func cancelLookupTransitionState() {
2951:        private func forceResetLookupInteractions() {
2957:        private func scheduleInitialLongPressLookupDelay(
3002:        private func cancelInitialLongPressLookupDelay() {
3007:        private func emitLongPressLookupHaptic() {
3013:        func loadDocumentAsync(
3069:            func bind(_ document: PDFDocument) {
3136:            func loadDocumentFromDisk() -> PDFDocument? {
3172:            func scheduleLoadAttempt(_ attempt: Int) {
3248:        private func onLoadFailedMainThread(
3263:        private func schedulePDFReadySignal(
3295:        private func startOpenWarmupSequence(
3344:        private func runOpenWarmupGeometry(
3390:        private func runOpenWarmupLookupBounds(
3434:        private func runOpenPhasePagePrefetchAsync(
3469:        private func scheduleOpenPhasePagePrefetch(
3501:        private func cancelPendingPagePrefetch() {
3506:        private func schedulePagePrefetchWindow(
3549:        private func prefetchCandidateIndexes(center: Int, total: Int, radius: Int) -> [Int] {
3568:        private func schedulePagePrefetchStep(
3618:        private func scheduleWork(delay: TimeInterval, workItem: DispatchWorkItem) {
3630:        private func cancelSingleTapReadiness() {
3635:        private func cancelInitialInteractionReadiness() {
3640:        private func scheduleInitialInteractionReadiness(
3678:        private func scheduleSingleTapReadiness(
3691:        private func scheduleSingleTapReadiness(
3746:        private func cancelLookupPressReadiness() {
3751:        private func resetGestureStateBeforeDocumentReload(using pdfView: PDFView) {
3818:        private func scheduleLookupPressReadiness(
3831:        private func scheduleLookupPressReadiness(
3898:        fileprivate func scheduleBindingSyncIfNeeded(using pdfView: PDFView) {
3949:        func scheduleGeometryWarmup(for page: PDFPage?, using pdfView: PDFView, delay: TimeInterval) {
3996:        private func scheduleLookupBoundsWarmup(
4049:        private func prewarmLongPressLookup(
4096:        func ensureDisplayBoxValid(for page: PDFPage) {
4116:        private func scheduleRefreshLongPressEnabled(recollect: Bool, delay: TimeInterval) {
4139:        private func refreshLongPressEnabledNow(recollect: Bool) {
4174:        private func expectedGestureMode() -> GestureMode {
4181:        private func isLongPressMode() -> Bool {
4185:        private func canHandleSingleTapGesture() -> Bool {
4212:        private func shouldDropDuplicateSingleTapEvent(
4235:        private func recordSingleTapDelivery(
4245:        private func canHandleLookupPressGesture() -> Bool {
4253:        private func ensureLookupPressReadinessIfNeeded() {
4265:        private func canHandleLookupLongPressMode() -> Bool {
4273:        private func applyGestureMode(using pdfView: PDFView, recollect: Bool) {
4342:            func setIfChanged(_ recognizer: UIGestureRecognizer?, _ enabled: Bool) {
4347:            func setIfChangedLongPressCancels(_ enabled: Bool) {
4387:        private func setSystemLongPresses(enabled: Bool, in pdfView: PDFView, recollect: Bool) {
4401:        private func refreshSystemLongPresses(in pdfView: PDFView, force: Bool = false) {
4433:        private func queueProgrammaticPageTurn(_ direction: PendingPageTurn.Direction, preserving ratio: CGFloat, for pdfView: PDFView) {
4464:        private func suppressSingleTapTemporarily(_ delay: TimeInterval? = nil) {
4489:        private func suppressSingleTap(for duration: TimeInterval) {
4498:        private func collectLongPressRecognizers(in view: UIView, maxDepth: Int) -> [UILongPressGestureRecognizer] {
4523:        private func clearSelectionIfNeeded(on pdfView: PDFView) {
4534:        private func longPressEnabled() -> Bool {
4538:        private func isSingleTapEnabled() -> Bool {
4545:        private func clearSingleTapSuppression() {
4551:        private func autoSaveEnabled() -> Bool {
4558:        private func shouldEmitDebug(tag: String, signature: String, throttle: TimeInterval? = nil) -> Bool {
4576:        private func debugLongPressState(_ tag: String) {
4591:        private func debugSingleTapState(_ tag: String) {
4605:        private func currentZoomRatio(from pdfView: PDFView) -> CGFloat {
4612:        private func syncZoomRatioFromView(_ pdfView: PDFView) {
4621:        private func quantizedSize(_ size: CGSize) -> CGSize {
4625:        private func resolvedZoomRatio(using pdfView: PDFView, fallback: CGFloat) -> CGFloat {
```


### readtap/readtap/ContextMeaningService.swift
- action_hooks=, methods=60
- methods:
```
5:struct ContextMeaningCandidate: Decodable, Equatable {
11:struct ContextMeaningResponse: Decodable, Equatable {
17:    func resolvedCandidates() -> [ContextMeaningCandidate] {
24:struct ContextMeaningRequest: Decodable, Encodable, Equatable {
35:struct ContextTranslateRequest: Encodable {
47:private struct ServerTranslationResponse: Decodable {
58:private struct ServerTranslationPayload: Decodable {
66:private struct ServerErrorPayload: Decodable {
73:private struct ContextServerHealthResponse: Decodable {
80:enum ContextMeaningError: Error {
87:private enum ContextServerDefaults {
93:private enum ContextServerEmbeddedDefaults {
102:private struct ContextServerRuntimeConfig {
110:enum ContextServerTokenStore {
174:enum ContextServerSigningSecretStore {
234:final class ContextMeaningService {
248:    private init() {}
254:        func runMeaning(
270:        func runTranslate(
287:    private func requestCacheKey(
312:    private func requestCacheKeyForTranslate(
335:    func isConfigured(defaults: UserDefaults = .standard) -> Bool {
351:    func fetchMeaning(
413:    func translate(
511:    func testConnection(
579:    private func serverConfig(
678:    private func readEmbeddedConfig() -> (baseURL: String?, token: String?, clientId: String?, certificatePin: String?, signingSecret: String?, allowUserOverrides: Bool?) {
698:    private func boolValue(from raw: Any?) -> Bool? {
717:    private func serverConfig(defaults: UserDefaults = .standard) throws -> ContextServerRuntimeConfig {
721:    private func logContextEnvironmentProbeIfNeeded() {
766:    private func resolveServerValue(_ value: String?) -> String? {
785:    private func resolveServerEnvPlaceholder(_ value: String) -> String? {
794:    private func resolveSingleMacroName(from value: String) -> String? {
811:    private func logServerConfigState(
832:    private func resolveServerEnvValue(_ keys: [String]) -> String? {
841:    private func resolvedContextEndpoint(from baseURL: URL) -> URL {
858:    private func resolvedTranslateEndpoint(from baseURL: URL) -> URL {
886:    private func resolvedHealthEndpoint(from baseURL: URL) -> URL {
904:    private func ensureValidServerURL(_ rawURL: String) throws -> URL {
929:    private func isAllowedScheme(_ scheme: String, host: String?) -> Bool {
942:    private func buildRequest(
983:    private func postJSON<Response: Decodable, Request: Encodable>(
1017:    private func isHealthy(_ response: ContextServerHealthResponse) -> Bool {
1034:    private func parseContextServerErrorMessage(from data: Data) -> String {
1055:    private func isNotConfiguredResponse(message: String) -> Bool {
1078:    private func tokenPreview(_ token: String?) -> String {
1090:    private func debugContextServerFailure(url: URL, token: String?, statusCode: Int, message: String) {
1095:    private func requestSignature(
1112:    private func makeURLSession(pinnedSHA256: String?) -> URLSession {
1147:    private func translatedText(from response: ServerTranslationResponse) -> String? {
1190:    private func normalizePinValue(_ raw: String) -> String {
1200:    private func normalizeCandidates(_ candidates: [String], primary: String, maxCandidates: Int) -> [String] {
1224:    private func normalizedContextProvider(_ provider: String?) -> String? {
1239:    private func normalizedAPIKey(_ apiKey: String?) -> String? {
1245:    private func normalizedAPIKeyHint(_ apiKey: String?) -> String? {
1254:private final class ContextServerTrustEvaluator: NSObject, URLSessionDelegate {
1257:    init(pinnedSHA256: String) {
1261:    func urlSession(
1295:    private func sha256Base64(_ data: Data) -> String {
1300:    private func sha256Hex(_ data: Data) -> String {
```


### readtap/readtap/PDFHighlightManager.swift
- action_hooks=, methods=9
- methods:
```
18:final class PDFHighlightManager {
20:    private init() {}
32:    func attach(to pdfView: PDFView, bookId: String) {
57:    func detach() {
69:    private func handleDocumentChanged() {
93:  func addHighlight(
117:    func removeHighlight(entryId: Int) {
125:  private func forceRedraw(for page: PDFPage) {
132:    private func restoreHighlights(for document: PDFDocument, entries: [VocabularyEntry]) {
```


### readtap/readtap/ReviewDeckView.swift
- action_hooks=2, methods=4
- hooks:
```
69:            .toolbar(.hidden, for: .navigationBar)
70:            .onAppear {
```
- methods:
```
4:struct ReviewDeckView: View {
77:private struct ReviewCardView: View {
125:final class ReviewDeckViewModel: ObservableObject {
128:    func reload() {
```


### readtap/readtap/ReaderViewModel+OCR.swift
- action_hooks=, methods=22
- methods:
```
6:extension ReaderViewModel {
8:  func ocrSignature(for words: [PDFOCRWord]) -> String {
26:  func setOCRStateIfNeeded(pageIndex: Int, languageSignature: String, words: [PDFOCRWord]) {
42:  func loadOCRCache(
54:  func persistOCRCache(
71:  func trySchedulePrefetch(
117:  func scheduleDeferredPrefetch(
158:  func scheduleInitialSurroundingPrefetch(
207:  func updateOCR(
404:  func prefetchNearbyPages(
444:      func isSessionValid() async -> Bool {
451:      func buildQueue(_ offsets: [Int]) async -> [(Int, PDFPage)] {
508:      func runQueue(_ queue: [(Int, PDFPage)]) async {
596:  func ocrSelection(
606:    func pickSelection(
676:  func limitedSelectionCandidates(
715:  func lookupFocusArea(around pointOnPage: CGPoint, scaleFactor: CGFloat) -> CGRect {
727:  func lineText(near pickedRect: CGRect, in items: [WordSnap.Item<PDFOCRWord>]) -> String {
742:  func ocrRecognitionLanguageHint(for token: String) -> [String]? {
798:  func chineseRecognitionLanguages(for token: String) -> [String] {
808:  func ocrRecognitionLanguages(for page: PDFPage? = nil, selectedToken: String? = nil) -> [String] {
873:  func ocrLanguageSignature(_ languages: [String]) -> String {
```


### readtap/readtap/BooksStore.swift
- action_hooks=, methods=62
- methods:
```
4:struct BookRecord: Identifiable, Hashable {
16:struct BookFolder: Identifiable, Hashable {
26:struct BookFolderWithBooks: Identifiable, Hashable {
37:final class BooksStore {
43:    private init() {
47:    private func createTableIfNeeded() {
149:    func fetchAll(includeDeleted: Bool = false) -> [BookRecord] {
190:    func title(for bookId: String) -> String? {
201:    func titles(forBookIds bookIds: [String]) -> [String: String] {
223:    func record(forId id: String) -> BookRecord? {
255:    func record(forFilePath filePath: String, includeDeleted: Bool = false) -> BookRecord? {
288:    func folderRecord(forId id: String) -> BookFolder? {
312:    func insert(id: String, title: String, filePath: String, fileType: BookFileType, createdAt: Date) {
334:    func updateTitleAndPath(id: String, title: String, filePath: String) {
347:    func updateMetadataFromRemote(id: String, title: String, fileType: BookFileType, orderKey: String, updatedAt: Date, deletedAt: Date?) {
364:    func insertFromRemote(id: String, title: String, filePath: String, fileType: BookFileType, createdAt: Date, updatedAt: Date, orderKey: String) {
383:    func updateId(from oldId: String, to newId: String) {
396:    func delete(id: String) {
402:    func softDeleteBook(id: String, at date: Date = Date()) {
425:    func fetchFolders(includeDeleted: Bool = false) -> [BookFolder] {
459:    func fetchFoldersWithBooks() -> [BookFolderWithBooks] {
476:    func createFolder(name: String) -> BookFolder {
498:    func upsertFolderFromRemote(id: String, name: String, createdAt: Date, updatedAt: Date, orderKey: String) {
514:    func renameFolder(id: String, newName: String) {
526:    func deleteFolder(id: String) {
530:    func softDeleteFolder(id: String, at date: Date) {
544:    func setBooks(_ bookIds: [String], inFolder folderId: String) {
562:    func appendBook(_ bookId: String, toFolder folderId: String) {
571:    func setFolders(_ folderIds: [String], forBook bookId: String) {
591:    func removeBook(_ bookId: String, fromFolder folderId: String) {
599:    func folderIds(forBookId bookId: String) -> [String] {
618:    func fetchBookIds(folderId: String) -> [String] {
637:    func folderItemRecord(folderId: String, bookId: String) -> (orderKey: String, updatedAt: Date, deletedAt: Date?)? {
656:    func upsertFolderItemFromRemote(folderId: String, bookId: String, orderKey: String, updatedAt: Date) {
672:    func deleteFolderItemFromRemote(folderId: String, bookId: String, at date: Date) {
680:    private func bookCount(inFolder folderId: String) -> Int {
691:    private func upsert(bookId: String, folderId: String, order: Int) {
696:    private func upsert(bookId: String, folderId: String, order: Int, orderKey: String, at date: Date) {
714:    private func nextFolderItemOrderKey(folderId: String) -> String {
732:    private func markFolderItemsDeleted(folderId: String? = nil, bookId: String? = nil, at date: Date) {
754:    private func hardDeleteFolderItemsForBook(_ bookId: String) {
761:    private func recordFolderItemChange(folderId: String, bookId: String, action: SyncAction) {
766:    private func recordFolderItemChanges(folderId: String, bookIds: [String], action: SyncAction) {
772:    private func touchFolder(id: String) {
780:    func setBookOrder(_ ids: [String]) {
792:    func setFolderOrder(_ ids: [String]) {
804:    func updateBookOrderKey(id: String, key: String) {
814:    func updateFolderOrderKey(id: String, key: String) {
824:    private func backfillBookDisplayOrder() {
838:    private func backfillBookUpdatedAt() {
855:    private func backfillFolderDisplayOrder() {
869:    private func nextBookDisplayOrderForInsert() -> Int {
881:    private func nextFolderDisplayOrderForInsert() -> Int {
892:    private func backfillBookOrderKeys() {
909:    private func backfillFolderOrderKeys() {
926:    private func backfillFolderItemOrderKeys() {
949:    private func backfillFolderItemUpdatedAt() {
954:    private func assignOrderKeys(_ ids: [String], table: String) {
968:    private func assignFolderItemOrderKeys(folderId: String, bookIds: [String]) {
983:    private func nextBookOrderKeyForInsert() -> String {
997:    private func nextFolderOrderKeyForInsert() -> String {
1011:    private func hasColumn(table: String, column: String) -> Bool {
```


### readtap/readtap/FirebaseStorageProvider.swift
- action_hooks=, methods=1
- methods:
```
5:enum FirebaseStorageProvider {
```


### readtap/readtap/ImageReaderViewModel+Extensions.swift
- action_hooks=, methods=1
- methods:
```
3:extension ImageReaderViewModel {
```


### readtap/readtap/ReaderViewModel+Lookup.swift
- action_hooks=, methods=20
- methods:
```
6:extension ReaderViewModel {
8:  private func normalizedLookupToken(_ text: String) -> String {
16:  private enum LookupSignature {
21:  func loadCachedMeaningCandidates(
54:  func persistLookupMeaningCandidates(
90:  func handleSingleTap() {
100:  func handleSelection(
717:  private struct LookupPersistResult {
724:  private func persistLookupResult(
784:  private func applySavedArtifactsIfNeeded(
798:  func reportMeaningAsIncorrect() {
812:  func loadGoogleCorrectedMeaningCandidates(from popup: WordPopupState) async {
921:  func fetchGoogleMeaningCandidates(
996:  func fallbackGoogleMeaningCandidates(
1038:  func applyMeaningCandidate(_ candidate: WordPopupState.MeaningCandidate) {
1319:  func refinePopupAccuracy(in pdfView: PDFView, bookId: String) {
1589:  func pickOCRWord(
1641:  func saveFromPopup() {
1691:  func undoSaveFromPopup() {
1724:  private func addHighlightForSavedEntryIfNeeded(
```


### readtap/readtap/ReaderUsageTracker.swift
- action_hooks=, methods=7
- methods:
```
5:final class ReaderUsageTracker: ObservableObject {
17:    private init() {}
19:    func start(bookId: String) {
33:    func stop() {
46:    func noteInteraction() {
53:    func setAppActive(_ isActive: Bool) {
57:    private func tick() {
```


### readtap/readtap/FlashcardDeckView.swift
- action_hooks=9, methods=16
- hooks:
```
122:                            .gesture(
145:            .toolbar {
174:            .sheet(isPresented: $isEditPresented) {
183:            .alert(editErrorTitle, isPresented: $isEditErrorPresented) {
184:                Button(okTitle, role: .cancel) {}
434:            .toolbar {
436:                    Button(cancelTitle) { onCancel() }
439:                    Button(saveTitle) { onSave() }
477:        .onTapGesture {
```
- methods:
```
10:struct FlashcardRoute: Identifiable {
15:struct FlashcardDeckView: View {
40:    init(
194:    private func swipeFeedbackOverlay(cardSize: CGSize) -> some View {
235:    private func handleSwipeEnd(_ translation: CGSize) {
247:    private enum SwipeDirection { case left, right }
249:    private func swipeCard(direction: SwipeDirection, mastery: MasteryState) {
270:    private func applyMasteryAndAdvance(id: Int, state: MasteryState) {
288:    private func scheduleAutoDismiss() {
297:    private func updateDeckItem(id: Int, mastery: MasteryState) {
332:    private func openInBook() {
340:    private func beginEdit() {
348:    private func saveEdits() {
381:    private func presentEditError(_ result: VocabularyUpdateResult) {
407:private struct FlashcardEditSheet: View {
456:private struct FlashcardCardView: View {
```


### readtap/readtap/SyncEngine.swift
- action_hooks=, methods=52
- methods:
```
9:final class SyncEngine: ObservableObject {
12:    enum State: Equatable {
18:    enum Phase: String, Equatable {
27:    enum SyncError: LocalizedError {
53:    private init() {}
61:    func syncNow() async {
68:    func runStorageDiagnostic() async {
134:    private func syncNowInternal(uid: String, allowRetry: Bool) async {
180:    private func userFacingErrorMessage(_ error: Error) -> String {
209:    private func extractBookIdFromStorageError(_ message: String) -> String? {
218:    private func extractStoragePathFromStorageError(_ message: String) -> String? {
227:    private func isMissingRemoteObjectError(_ error: Error) -> Bool {
234:    private func attemptHealMissingRemoteObject(uid: String, error: Error) async -> Bool {
261:    private func derivedStoragePath(uid: String, bookId: String, fileType: BookFileType) -> String {
267:    private func uploadLocalChanges(uid: String) async throws -> Bool {
303:    private func pullRemoteChanges(uid: String, lastSync: Date?) async throws {
313:    private func uploadReadingStatus(uid: String, lastSync: Date?) async throws {
351:    private func uploadBookChange(_ change: SyncChange, uid: String, db: Firestore, forceFullPull: inout Bool) async throws -> Bool {
423:    private func repairMissingBookUploads(uid: String) async throws {
471:    private func uploadFolderChange(_ change: SyncChange, uid: String, db: Firestore, forceFullPull: inout Bool) async throws -> Bool {
512:    private func uploadFolderItemChange(_ change: SyncChange, uid: String, db: Firestore, forceFullPull: inout Bool) async throws -> Bool {
556:    private func uploadVocabChange(_ change: SyncChange, uid: String, db: Firestore, forceFullPull: inout Bool) async throws -> Bool {
603:    private func remoteUpdatedAt(_ doc: DocumentReference) async throws -> Date? {
610:    private func pullBooks(uid: String, db: Firestore, lastSync: Date?) async throws {
617:        struct DownloadCandidate {
691:    private func pullFolders(uid: String, db: Firestore, lastSync: Date?) async throws {
731:    private func pullFolderItems(uid: String, db: Firestore, lastSync: Date?) async throws {
770:    private func pullVocab(uid: String, db: Firestore, lastSync: Date?) async throws {
826:    private func pullBookStatus(uid: String, db: Firestore, lastSync: Date?) async throws {
844:    private func pullReadingDays(uid: String, db: Firestore, lastSync: Date?) async throws {
863:    private struct RemoteBook {
874:    private struct RemoteFolder {
883:    private struct RemoteVocab {
899:    private struct PendingBookDownload {
909:    private struct RemoteBookStatus {
916:    private struct RemoteReadingDay {
923:    private struct RemoteFolderItem {
931:    private func parseBook(doc: QueryDocumentSnapshot) -> RemoteBook? {
954:    private func parseFolder(doc: QueryDocumentSnapshot) -> RemoteFolder? {
965:    private func parseFolderItem(doc: QueryDocumentSnapshot) -> RemoteFolderItem? {
975:    private func parseBookStatus(doc: QueryDocumentSnapshot) -> RemoteBookStatus? {
984:    private func parseReadingDay(doc: QueryDocumentSnapshot) -> RemoteReadingDay? {
993:    private func parseVocab(doc: QueryDocumentSnapshot) -> RemoteVocab? {
1026:    private func parseFolderItemId(_ value: String) -> (String, String)? {
1032:    private func enqueueDownload(_ pending: PendingBookDownload) {
1037:    private func processPendingDownloads(uid: String) async throws {
1089:    private func isStorageObjectNotFound(_ error: Error) -> Bool {
1099:    private func clearRemoteStoragePath(uid: String, bookId: String) async {
1113:    private func storageObjectExists(storagePath: String) async throws -> Bool {
1130:    private func downloadBookFile(storagePath: String, bookId: String, fileType: BookFileType) async throws -> URL {
1157:    private func uploadBookFile(record: BookRecord, uid: String, storagePathOverride: String?) async throws -> String {
1176:    private func uploadBookFileIfNeeded(record: BookRecord, uid: String) async throws -> String {
```


### readtap/readtap/StreakView.swift
- action_hooks=5, methods=5
- hooks:
```
30:        .onAppear {
34:        .onDisappear {
46:        .onChange(of: scenePhase) { _, phase in
55:        .onChange(of: appSettings.language) { _, _ in
76:        .contextMenu {
```
- methods:
```
5:struct StreakView: View {
17:    init(isCalendarPresented: Binding<Bool>) {
102:    private func summaryIconCount(systemName: String, value: Int, tint: Color) -> some View {
122:    private func refresh() {
151:    private func rescheduleMidnightRefresh() {
```


### readtap/readtap/PDFMarkupAction.swift
- action_hooks=, methods=1
- methods:
```
3:enum PDFMarkupAction: Equatable {
```


### readtap/readtap/LibraryTheme.swift
- action_hooks=, methods=7
- methods:
```
4:enum LibraryTheme: String, CaseIterable, Identifiable {
81:struct CalendarPalette {
110:extension CalendarPalette {
116:extension LibraryTheme {
117:  func calendarPalette(for colorScheme: ColorScheme) -> CalendarPalette {
118:    func makeBadgeStyle(for base: Color) -> (fill: Color, symbol: Color, page: Color, stroke: Color, shadow: Color) {
234:private struct AdaptiveThemeBackground: View {
```


### readtap/readtap/NotificationManager.swift
- action_hooks=, methods=8
- methods:
```
4:final class NotificationManager {
10:    private init() {}
12:    func requestAuthorizationIfNeeded() async {
19:    func refreshSchedule() {
27:    private func scheduleReviewReminderIfNeeded() async {
65:    private func localizedTitle() -> String {
74:    private func localizedBody() -> String {
83:    private func currentLanguage() -> AppLanguage {
```


### readtap/readtap/PDFTapStatePolicy.swift
- action_hooks=, methods=2
- methods:
```
3:struct PDFTapSingleTapDecision: Equatable {
12:enum PDFTapSingleTapPolicy {
```


### readtap/readtap/AppNotifications.swift
- action_hooks=, methods=3
- methods:
```
3:struct OpenWordsTabRequest: Identifiable, Equatable {
8:    init(bookId: String, bookTitle: String, id: UUID = UUID()) {
15:extension Notification.Name {
```


### readtap/readtap/VocabularyByDateView.swift
- action_hooks=4, methods=5
- hooks:
```
62:            .onAppear {
65:            .fullScreenCover(item: $openRequest) { req in
123:        .onTapGesture {
128:        .contextMenu {
```
- methods:
```
3:struct VocabularyByDateView: View {
72:    private func dateItemRow(_ item: VocabularyEntry) -> some View {
139:    private func reload() {
162:    private func openRequestFor(_ item: VocabularyEntry) -> OpenBookRequest? {
172:private struct DateSection: Identifiable {
```


### readtap/readtap/BookStore.swift
- action_hooks=, methods=26
- methods:
```
7:extension Notification.Name {
13:final class BookStore: ObservableObject {
17:    struct ImportedBookHandle {
56:    func loadBooks() {
86:    func updateOrderKey(bookId: String, orderKey: String) {
103:    func importFile(from sourceURL: URL) throws {
126:    func importFileFast(from sourceURL: URL) async throws -> ImportedBookHandle {
172:    func replaceBookFileContents(bookId: String, with sourceURL: URL) async throws {
193:    func delete(book: BookRow) {
197:    func delete(book: BookRow, deleteAssociatedData shouldDeleteAssociatedData: Bool) {
221:    func deleteById(_ id: String) {
225:    func deleteById(_ id: String, deleteAssociatedData shouldDeleteAssociatedData: Bool) {
240:    func removeLocalFiles(bookId: String, fileURL: URL) {
248:    func rename(book: BookRow, to newTitle: String) {
276:    func deleteAssociatedData(bookId: String, documentURL: URL? = nil, shouldDeleteAssociatedData: Bool = true) {
300:    private func uniqueFileURL(for baseName: String, ext: String) -> URL {
316:    private func coverPathForBookId(_ bookId: String) -> URL {
320:    func coverImagePath(forBookId bookId: String) -> String? {
325:    func ensureCoverIfNeeded(bookId: String, fileURL: URL, fileType: BookFileType) {
331:    func generateCover(for fileURL: URL, type: BookFileType, bookId: String) {
336:    private func fileType(for url: URL) -> BookFileType? {
347:    private func migrateOrInsertBooksForFilesystem(urls: [URL]) {
376:    private func migrateLegacyBookIdsIfNeeded() {
398:    private func setFirstBookAddedAtIfNeeded(date: Date) {
403:    private func setFirstBookAddedAtIfNeeded(fromExistingFiles urls: [URL]) {
422:    private func schedulePostImportProcessing(for handle: ImportedBookHandle, includeOCRPrime: Bool) {
```


### readtap/readtap/OpenBookRequest.swift
- action_hooks=, methods=1
- methods:
```
3:struct OpenBookRequest: Identifiable, Hashable {
```


### readtap/readtap/BadgeComponents.swift
- action_hooks=, methods=2
- methods:
```
3:struct PaletteBadgeView: View {
13:    init(
```


### readtap/readtap/BookVocabularyListView.swift
- action_hooks=2, methods=2
- hooks:
```
47:            .onAppear {
83:            .onTapGesture {
```
- methods:
```
3:struct BookVocabularyListView: View {
54:    private func bookWordRow(_ item: VocabularyEntry) -> some View {
```
