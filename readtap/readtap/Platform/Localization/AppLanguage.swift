import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case korean
    case chinese

    var id: String { rawValue }

    static var allCases: [AppLanguage] { [.english, .korean, .chinese] }

    var title: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .korean: return "한국어"
        case .chinese: return "中文"
        }
    }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .korean: return Locale(identifier: "ko")
        case .chinese: return Locale(identifier: "zh-Hans")
        }
    }

    static func current() -> AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "appLanguage")
        let normalized = normalized(raw: raw)
        if raw != normalized.rawValue {
            UserDefaults.standard.set(normalized.rawValue, forKey: "appLanguage")
        }
        return normalized
    }

    static func normalized(raw: String?) -> AppLanguage {
        guard let raw else { return .english }
        if let value = AppLanguage(rawValue: raw) {
            return value == .system ? .english : value
        }
        // Backwards/forward compatibility: accept locale tags directly.
        if raw.hasPrefix("zh") { return .chinese }
        if raw.hasPrefix("ko") { return .korean }
        if raw.hasPrefix("en") { return .english }
        return .english
    }

    static func migrateIfNeeded() {
        _ = current()
    }
}

enum AppString {
    case library
    case review
    case settings
    case myLibrary
    case today
    case customizeLibrary
    case libraryTheme
    case noPDFTitle
    case noPDFBody
    case noWordsTitle
    case noWordsBody
    case refresh
    case startReadingTitle
    case startReadingBody
    case readingStreak
    case words
    case settingsLanguage
    case settingsReading
    case settingsAppLanguage
    case settingsAutoSave
    case settingsPopupSize
    case popupSizeCompact
    case popupSizeNormal
    case popupSizeLarge
    case settingsInterval
    case settingsTime
    case settingsDays3
    case settingsDays5
    case settingsDays7
    case settingsOff
    case save
    case saved
    case refine
    case adjustBox
    case manualEntry
        case streakMsg0
        case streakMsg1
    case streakMsgLow
    case streakMsgHigh
    case days
    case delete
    case cancel
    case done
    case deleteFolderTitle
    case deleteFolderMessage
    case confirmDeleteTitle
    case dontAskAgainToday
    case calendar
    case loading
    case translationEngine
    case translationEngineDeepL
    case translationEngineServer
    case contextServer
    case contextServerURL
    case contextServerURLPlaceholder
    case contextServerToken
    case contextServerTokenPlaceholder
    case contextServerHelp
    case contextServerTest
    case contextServerTesting
    case contextServerTestSuccess
    case contextServerTestFail
    case contextServerInvalidURL
        case meaningOptionsTitle
    case translationSource
    case translationSourceAuto
    case translationTarget
    case translationAuto
    case clear
    case keyEmpty
    case saveSuccess
    case saveFailed
    case clearSuccess
    case languageEnglish
    case languageKorean
    case languageChinese
    case koreanDictionarySection
    case koreanDictionaryKey
    case koreanDictionaryKeyPlaceholder
    case koreanDictionaryGetKey
    case koreanDictionaryTest
    case koreanDictionaryTestSuccess
    case koreanDictionaryTestFail
    // Reader
    case retry
    case reload
    case loadingPDF
    case loadingImage
    case loadingShort
    case loadingDelayed
    case loadingWait
    case loadingStill
    case loadingMoment
    case pdfLoadFailedTitle
    case pdfLoadFailedBody
    case imageLoadFailedTitle
    case imageLoadFailedBody
    case thumbnailTimeout
    case adjustBoxTitle
    case adjustBoxTruncatedMessage
    case adjustBoxNoWordMessage
    case adjustBoxEmptyMessage
    case selectionLimitToast
    case longPressMode
    // Words tab
    case modeStripTitle
    case folderDeleteHint
    case folderEditLabel
    case folderDeleteConfirmMessage
    case legendGoalText
    case legendStartedText
    case legendFinished
    case deleteAll
    case cannotUndo
    case rename
    case renameMessage
    case renamePlaceholder
    case openInBook
    case masteryUnknown
    case masteryKnown
    case masteryUnsure
    case masteryClear
    case flashcardFlipHint
    case flashcardEdit
    case wordSection
    case meaningSection
    case sentenceSection
    // Free-tier dictionary feedback (2026-04-17 spec)
    case popupTranslationFallbackBadge
    case popupDictionaryFeedbackLink
    case popupFeedbackSheetTitle
    case popupFeedbackOneTap
    case popupFeedbackEditAndShare
    case popupFeedbackToastSent
    case cannotSaveTitle
    case emptyWordError
    case emptyMeaningError
    case duplicateWordError
    case ok
    case selectAll
    case deselectAll
    case deleteSelected
    case selectedCount
    // HomeView
    case noBooksGlobal
    case noBooksInFolder
    case addBook
    case manageFolders
    // VocabularyByBookView
    case uncategorized
    case noSearchResults
    case noSearchResultsHint
    case noWordsInBook
    case noWordsInBookHint
    case searchBooksOrWords
    // Streak
    case resetTodayStarts
    case resetTodayFinishes
    // Theme titles
    case themeStudio
    case themePaper
    case themeDusk
    case themeMint
    case themeOcean
    case themeRose
    case themeNoir
    // WordPopup
    case meaningSourceCache
    case meaningSourceLive
    case meaningSourceCandidate
    case meaningSourceStale
    case meaningSourceManual
    case meaningSourceRetry
    case meaningSourceUnknown
    case meaningConfidenceHigh
    case meaningConfidenceMedium
    case meaningConfidenceLow
    case meaningConfidenceUnknown
    case meaningPlaceholderNotice
    case popupLoadingMeaning
    case popupMeaningNotFoundRetry
    case popupNoMoreMeanings
    case popupFindOtherMeanings
    case popupUndoSave
    case popupCandidateLoading
    case popupCandidateInvalid
    case popupCannotSavePlaceholder
    case popupAdjustSelection
    case popupEnterManually
    case popupPhraseTranslationLabel
    case popupPhraseUpgradeHint
    // Premium / Subscription
    case popupSentenceLabel
    case popupSynonymsLabel
    case popupAntonymsLabel
    case popupSynonymAntonymHint
    case popupSynonymAntonymTitle
    case popupSynonymLoading
    case popupSynonymEmpty
    case flashcardSynonymLabel
    case flashcardSynonymFront
    case flashcardSynonymBack
    case flashcardSynonymHidden
    case flashcardSynonymPlacementDesc
    case popupUpgradeHint
    case subscriptionFree
    case subscriptionPremium
    case heroEyebrowAccount
    case themeLocked
    // Premium feature descriptions (shared between PaywallView & PremiumPromoSheet)
    case premiumFeatureAccurateTitle
    case premiumFeatureAccurateSubtitle
    case premiumFeaturePosTitle
    case premiumFeaturePosSubtitle
    case premiumFeatureSynonymTitle
    case premiumFeatureSynonymSubtitle
    case premiumFeatureThemeTitle
    case premiumFeatureThemeSubtitle
    case premiumReadDeeper
    case premiumGoButton
    case premiumTrialButton
    case premiumMaybeLater
    case premiumSubscribe
    case premiumRestore
    case premiumTrialDaysLeft
    case premiumTrialEnded
}

struct AppText {
    static func t(_ key: AppString) -> String {
        switch AppLanguage.current() {
        case .chinese:
            return chinese(key)
        case .korean:
            return korean(key)
        case .english, .system:
            return english(key)
        }
    }

    /// 3-way inline localization helper for strings not in AppString.
    static func L(_ en: String, _ ko: String, _ zh: String) -> String {
        switch AppLanguage.current() {
        case .chinese: return zh
        case .korean: return ko
        case .english, .system: return en
        }
    }

    private static func english(_ key: AppString) -> String {
        switch key {
        case .library: return "Library"
        case .review: return "Review"
        case .settings: return "Settings"
        case .myLibrary: return "My Library"
        case .today: return "Today"
        case .customizeLibrary: return "Customize Library"
        case .libraryTheme: return "Theme"
        case .noPDFTitle: return "No PDF loaded"
        case .noPDFBody: return "Provide a document URL to start reading."
        case .noWordsTitle: return "No words yet"
        case .noWordsBody: return "Save words while reading to see them here."
        case .refresh: return "Refresh"
        case .startReadingTitle: return "Start reading"
        case .startReadingBody: return "Save one word or read 10 minutes."
        case .readingStreak: return "Reading streak"
        case .words: return "Words"
        case .settingsLanguage: return "Language"
        case .settingsReading: return "Reading"
        case .settingsAppLanguage: return "Language"
        case .settingsAutoSave: return "Auto-save words"
        case .settingsPopupSize: return "Popup size"
        case .popupSizeCompact: return "Compact"
        case .popupSizeNormal: return "Normal"
        case .popupSizeLarge: return "Large"
        case .settingsInterval: return "Interval"
        case .settingsTime: return "Time"
        case .settingsDays3: return "3 days"
        case .settingsDays5: return "5 days"
        case .settingsDays7: return "7 days"
        case .settingsOff: return "Off"
        case .save: return "Save"
        case .saved: return "Saved"
        case .refine: return "Refine"
        case .adjustBox: return "Adjust box"
        case .manualEntry: return "Type"
        case .streakMsg0: return "One small step is enough today."
        case .streakMsg1: return "Nice start. Keep it gentle."
        case .streakMsgLow: return "You are building a calm rhythm."
        case .streakMsgHigh: return "Steady habit. Stay in your flow."
        case .days: return "days"
        case .delete: return "Delete"
        case .cancel: return "Cancel"
        case .done: return "Done"
        case .deleteFolderTitle: return "Delete this folder?"
        case .deleteFolderMessage: return "This will remove all saved words in the folder."
        case .confirmDeleteTitle: return "Are you sure you want to delete?"
        case .dontAskAgainToday: return "Don't ask again today"
        case .calendar: return "Calendar"
        case .loading: return "Loading..."
        case .translationEngine: return "Engine"
        case .translationEngineDeepL: return "DeepL"
        case .translationEngineServer: return "Context Server"
        case .contextServer: return "Context Server"
        case .contextServerURL: return "Server URL"
        case .contextServerURLPlaceholder: return "https://..."
        case .contextServerToken: return "Server Token"
        case .contextServerTokenPlaceholder: return "Bearer token (required for hosted servers)"
        case .contextServerHelp: return "The app sends the selected word + sentence to your server. Hosted servers should require a bearer token and request-signing secret."
        case .contextServerTest: return "Test Connection"
        case .contextServerTesting: return "Testing..."
        case .contextServerTestSuccess: return "Connected."
        case .contextServerTestFail: return "Connection failed."
        case .contextServerInvalidURL: return "Invalid URL format."
        case .meaningOptionsTitle: return "Other Meanings"
        case .translationSource: return "Translate From"
        case .translationSourceAuto: return "Auto Detect"
        case .translationTarget: return "Translate To"
        case .translationAuto: return "Auto"
        case .clear: return "Clear"
        case .keyEmpty: return "Key is empty."
        case .saveSuccess: return "Saved."
        case .saveFailed: return "Failed to save."
        case .clearSuccess: return "Cleared."
        case .languageEnglish: return "English"
        case .languageKorean: return "Korean"
        case .languageChinese: return "Chinese"
        case .koreanDictionarySection: return "Korean Dictionary"
        case .koreanDictionaryKey: return "API Key"
        case .koreanDictionaryKeyPlaceholder: return "Paste API key"
        case .koreanDictionaryGetKey: return "Get free key"
        case .koreanDictionaryTest: return "Test"
        case .koreanDictionaryTestSuccess: return "Connected!"
        case .koreanDictionaryTestFail: return "Failed. Check the key."
        // Reader
        case .retry: return "Retry"
        case .reload: return "Reload"
        case .loadingPDF: return "Loading PDF"
        case .loadingImage: return "Loading"
        case .loadingShort: return "Loading"
        case .loadingDelayed: return "Loading"
        case .loadingWait: return "Loading slowly"
        case .loadingStill: return "Still loading"
        case .loadingMoment: return "Just a moment"
        case .pdfLoadFailedTitle: return "Unable to Open PDF"
        case .pdfLoadFailedBody: return "The file may be damaged or in an unsupported format."
        case .imageLoadFailedTitle: return "Unable to Open Image"
        case .imageLoadFailedBody: return "The file may be damaged or in an unsupported format."
        case .thumbnailTimeout: return "Thumbnail loading timed out. Try again."
        case .adjustBoxTitle: return "Selection too large"
        case .adjustBoxTruncatedMessage: return "It was too long, so it was shortened for a safer lookup."
        case .adjustBoxNoWordMessage: return "The selection result is empty. Please adjust the box."
        case .adjustBoxEmptyMessage: return "No words found. Please resize the box and try again."
        case .selectionLimitToast: return "Only the first 8 words are looked up"
        case .longPressMode: return "Long Press"
        // Words tab
        case .modeStripTitle: return "Strip"
        case .folderDeleteHint: return "Select entries then tap delete"
        case .folderEditLabel: return "Edit"
        case .folderDeleteConfirmMessage: return "This will delete these folders and all words in them. This action cannot be undone."
        case .legendGoalText: return "All mastered"
        case .legendStartedText: return "Started"
        case .legendFinished: return "Finished"
        case .deleteAll: return "Delete All"
        case .cannotUndo: return "This action cannot be undone."
        case .rename: return "Rename"
        case .renameMessage: return "Enter a new name."
        case .renamePlaceholder: return "Title"
        case .openInBook: return "Open in book"
        case .masteryUnknown: return "Unknown"
        case .masteryKnown: return "Known"
        case .masteryUnsure: return "Unsure"
        case .masteryClear: return "Clear"
        case .flashcardFlipHint: return "Tap to flip"
        case .flashcardEdit: return "Edit"
        case .wordSection: return "Word"
        case .meaningSection: return "Meaning"
        case .sentenceSection: return "Sentence"
        case .popupTranslationFallbackBadge: return "Translation (not dictionary)"
        case .popupDictionaryFeedbackLink: return "Is this meaning off?"
        case .popupFeedbackSheetTitle: return "Report this meaning"
        case .popupFeedbackOneTap: return "This meaning seems wrong"
        case .popupFeedbackEditAndShare: return "Edit and share a correction"
        case .popupFeedbackToastSent: return "Thanks — we'll review this and improve."
        case .cannotSaveTitle: return "Can't save"
        case .emptyWordError: return "Please enter a word."
        case .emptyMeaningError: return "Please enter a meaning."
        case .duplicateWordError: return "This word is already saved."
        case .ok: return "OK"
        case .selectAll: return "Select All"
        case .deselectAll: return "Deselect All"
        case .deleteSelected: return "Delete"
        case .selectedCount: return "selected"
        // HomeView
        case .noBooksGlobal: return "No books yet\nAdd a PDF to get started"
        case .noBooksInFolder: return "No books in this folder"
        case .addBook: return "Add Book"
        case .manageFolders: return "Manage Folders"
        // VocabularyByBookView
        case .uncategorized: return "Uncategorized"
        case .noSearchResults: return "No results"
        case .noSearchResultsHint: return "Try a different search term"
        case .noWordsInBook: return "No saved words yet"
        case .noWordsInBookHint: return "Tap words while reading a book\nand they'll appear here"
        case .searchBooksOrWords: return "Search books or words"
        // Streak
        case .resetTodayStarts: return "Reset Today's Starts"
        case .resetTodayFinishes: return "Reset Today's Finishes"
        // Theme titles
        case .themeStudio: return "Studio"
        case .themePaper: return "Paper"
        case .themeDusk: return "Dusk"
        case .themeMint: return "Mono"
        case .themeOcean: return "Ocean"
        case .themeRose: return "Rose"
        case .themeNoir: return "Noir"
        // WordPopup
        case .meaningSourceCache: return "Cached"
        case .meaningSourceLive: return "Live"
        case .meaningSourceCandidate: return "Selected"
        case .meaningSourceStale: return "Cached (updating)"
        case .meaningSourceManual: return "Manual"
        case .meaningSourceRetry: return "Retrying"
        case .meaningSourceUnknown: return "Checking"
        case .meaningConfidenceHigh: return "High confidence"
        case .meaningConfidenceMedium: return "Medium confidence"
        case .meaningConfidenceLow: return "Low confidence"
        case .meaningConfidenceUnknown: return "Checking"
        case .meaningPlaceholderNotice: return "Meaning may be imprecise"
        case .popupLoadingMeaning: return "Looking up meaning..."
        case .popupMeaningNotFoundRetry: return "No meaning found. Try again in a moment."
        case .popupNoMoreMeanings: return "No other meanings found."
        case .popupFindOtherMeanings: return "See Other Meanings"
        case .popupUndoSave: return "Unsave"
        case .popupCandidateLoading: return "Looking up other meanings..."
        case .popupCandidateInvalid: return "This suggestion can't be saved."
        case .popupCannotSavePlaceholder: return "This meaning isn't ready to save yet. Refresh and try again."
        case .popupAdjustSelection: return "Adjust"
        case .popupEnterManually: return "Manual"
        case .popupPhraseTranslationLabel: return "Translation"
        case .popupPhraseUpgradeHint: return "Phrase translation is a Premium feature. Upgrade to translate phrases and expressions."
        case .popupSentenceLabel: return "Sentence"
        case .popupSynonymsLabel: return "Synonyms"
        case .popupAntonymsLabel: return "Antonyms"
        case .popupSynonymAntonymHint: return "Synonyms & Antonyms"
        case .popupSynonymAntonymTitle: return "Synonyms & Antonyms"
        case .popupSynonymLoading: return "Loading..."
        case .popupSynonymEmpty: return "No synonyms or antonyms found."
        case .flashcardSynonymLabel: return "Synonyms & Antonyms"
        case .flashcardSynonymFront: return "Front"
        case .flashcardSynonymBack: return "Back"
        case .flashcardSynonymHidden: return "Hidden"
        case .flashcardSynonymPlacementDesc: return "Display on flashcard"
        case .popupUpgradeHint: return "Upgrade to Premium for meanings by part of speech, sentence translation, and synonyms."
        case .subscriptionFree: return "Free"
        case .subscriptionPremium: return "Premium"
        case .heroEyebrowAccount: return "Account"
        case .themeLocked: return "Premium"
        case .premiumFeatureAccurateTitle: return "More accurate translation"
        case .premiumFeatureAccurateSubtitle: return "Context-aware meanings powered by AI"
        case .premiumFeaturePosTitle: return "Meanings by part of speech"
        case .premiumFeaturePosSubtitle: return "See noun, verb, and more — all at once"
        case .premiumFeatureSynonymTitle: return "Synonyms & Antonyms"
        case .premiumFeatureSynonymSubtitle: return "Expand your vocabulary with related words"
        case .premiumFeatureThemeTitle: return "Premium themes"
        case .premiumFeatureThemeSubtitle: return "Unlock Paper, Dusk, and Mint themes"
        case .premiumReadDeeper: return "Read Deeper"
        case .premiumGoButton: return "Go Premium"
        case .premiumTrialButton: return "Try 7 Days Free"
        case .premiumMaybeLater: return "Maybe Later"
        case .premiumSubscribe: return "Subscribe"
        case .premiumRestore: return "Already subscribed? Restore"
        case .premiumTrialDaysLeft: return "days left in free trial"
        case .premiumTrialEnded: return "Your free trial has ended"
        }
    }

    private static func korean(_ key: AppString) -> String {
        switch key {
        case .library: return "책장"
        case .review: return "복습"
        case .settings: return "설정"
        case .myLibrary: return "내 책장"
        case .today: return "오늘"
        case .customizeLibrary: return "책장 꾸미기"
        case .libraryTheme: return "테마"
        case .noPDFTitle: return "PDF가 없습니다"
        case .noPDFBody: return "문서를 추가하면 바로 읽을 수 있어요."
        case .noWordsTitle: return "아직 단어가 없어요"
        case .noWordsBody: return "읽으면서 저장한 단어가 여기에 모여요."
        case .refresh: return "새로고침"
        case .startReadingTitle: return "시작해볼까요"
        case .startReadingBody: return "단어 하나 저장하거나 10분만 읽어도 돼요."
        case .readingStreak: return "연속 읽기"
        case .words: return "단어"
        case .settingsLanguage: return "언어"
        case .settingsReading: return "읽기"
        case .settingsAppLanguage: return "언어"
        case .settingsAutoSave: return "자동 저장"
        case .settingsPopupSize: return "팝업 크기"
        case .popupSizeCompact: return "작게"
        case .popupSizeNormal: return "보통"
        case .popupSizeLarge: return "크게"
        case .settingsInterval: return "주기"
        case .settingsTime: return "시간"
        case .settingsDays3: return "3일"
        case .settingsDays5: return "5일"
        case .settingsDays7: return "7일"
        case .settingsOff: return "끄기"
        case .save: return "저장"
        case .saved: return "저장됨"
        case .refine: return "재인식"
        case .adjustBox: return "박스 조정"
        case .manualEntry: return "직접 입력"
        case .streakMsg0: return "오늘은 작은 한 걸음이면 충분해요."
        case .streakMsg1: return "좋은 시작이에요. 가볍게 이어가요."
        case .streakMsgLow: return "차분한 리듬이 만들어지고 있어요."
        case .streakMsgHigh: return "꾸준한 습관이에요. 흐름을 유지해요."
        case .days: return "일"
        case .delete: return "삭제"
        case .cancel: return "취소"
        case .done: return "완료"
        case .deleteFolderTitle: return "폴더를 삭제할까요?"
        case .deleteFolderMessage: return "폴더 안의 단어가 모두 삭제됩니다."
        case .confirmDeleteTitle: return "정말 지우시겠습니까?"
        case .dontAskAgainToday: return "오늘은 다시 묻지 않기"
        case .calendar: return "달력"
        case .loading: return "불러오는 중..."
        case .translationEngine: return "엔진"
        case .translationEngineDeepL: return "DeepL"
        case .translationEngineServer: return "문맥 서버"
        case .contextServer: return "문맥 서버"
        case .contextServerURL: return "서버 URL"
        case .contextServerURLPlaceholder: return "https://..."
        case .contextServerToken: return "서버 토큰"
        case .contextServerTokenPlaceholder: return "베어러 토큰(운영/원격 서버 필수)"
        case .contextServerHelp: return "선택한 단어 + 문장을 서버로 보내 문맥에 맞는 뜻/동의어를 받아옵니다. 운영/원격 서버는 베어러 토큰과 요청 서명 시크릿을 함께 요구해야 합니다."
        case .contextServerTest: return "연결 테스트"
        case .contextServerTesting: return "연결 확인 중..."
        case .contextServerTestSuccess: return "연결 성공"
        case .contextServerTestFail: return "연결 실패"
        case .contextServerInvalidURL: return "올바르지 않은 URL입니다."
        case .meaningOptionsTitle: return "다른 뜻"
        case .translationSource: return "원문 언어"
        case .translationSourceAuto: return "자동 인식"
        case .translationTarget: return "번역 대상"
        case .translationAuto: return "자동"
        case .clear: return "지우기"
        case .keyEmpty: return "키가 비어있어요."
        case .saveSuccess: return "저장했어요."
        case .saveFailed: return "저장에 실패했어요."
        case .clearSuccess: return "지웠어요."
        case .languageEnglish: return "영어"
        case .languageKorean: return "한국어"
        case .languageChinese: return "중국어"
        case .koreanDictionarySection: return "한국어 사전"
        case .koreanDictionaryKey: return "API 키"
        case .koreanDictionaryKeyPlaceholder: return "API 키 붙여넣기"
        case .koreanDictionaryGetKey: return "무료 키 발급"
        case .koreanDictionaryTest: return "테스트"
        case .koreanDictionaryTestSuccess: return "연결 성공!"
        case .koreanDictionaryTestFail: return "실패. 키를 확인하세요."
        // Reader
        case .retry: return "다시 시도"
        case .reload: return "다시 불러오기"
        case .loadingPDF: return "문서 로딩 중"
        case .loadingImage: return "로딩중"
        case .loadingShort: return "로딩중"
        case .loadingDelayed: return "지연중"
        case .loadingWait: return "조금만 더 기다려 주세요"
        case .loadingStill: return "로딩 중입니다"
        case .loadingMoment: return "잠시만요, 로딩중입니다"
        case .pdfLoadFailedTitle: return "PDF를 열 수 없습니다"
        case .pdfLoadFailedBody: return "파일이 손상되었거나 지원되지 않는 형식일 수 있습니다."
        case .imageLoadFailedTitle: return "이미지를 열 수 없습니다"
        case .imageLoadFailedBody: return "파일이 손상되었거나 지원되지 않는 형식일 수 있습니다."
        case .thumbnailTimeout: return "썸네일이 바로 안 보이면 다시 시도해보세요."
        case .adjustBoxTitle: return "선택 범위 조정"
        case .adjustBoxTruncatedMessage: return "선택이 넓어서 번역 가능한 길이로 자동으로 줄였어요."
        case .adjustBoxNoWordMessage: return "선택 결과가 비었어요. 박스를 다시 맞춰주세요."
        case .adjustBoxEmptyMessage: return "선택 영역이 너무 넓어요. 박스가 자동으로 좁혀졌지만 단어를 찾지 못했어요. 조금 더 좁혀 주세요."
        case .selectionLimitToast: return "처음 8단어만 검색됩니다"
        case .longPressMode: return "롱프레스"
        // Words tab
        case .modeStripTitle: return "연속 보기"
        case .folderDeleteHint: return "선택 후 삭제 버튼을 누르세요"
        case .folderEditLabel: return "편집"
        case .folderDeleteConfirmMessage: return "폴더와 해당 폴더의 단어들이 삭제됩니다. 되돌릴 수 없습니다."
        case .legendGoalText: return "모두 외움"
        case .legendStartedText: return "시작"
        case .legendFinished: return "완독"
        case .deleteAll: return "전체 삭제"
        case .cannotUndo: return "삭제하면 되돌릴 수 없습니다."
        case .rename: return "이름 변경"
        case .renameMessage: return "새 이름을 입력하세요."
        case .renamePlaceholder: return "제목"
        case .openInBook: return "책에서 보기"
        case .masteryUnknown: return "모름"
        case .masteryKnown: return "알겠음"
        case .masteryUnsure: return "애매"
        case .masteryClear: return "해제"
        case .flashcardFlipHint: return "탭해서 뒤집기"
        case .flashcardEdit: return "수정"
        case .wordSection: return "단어"
        case .meaningSection: return "뜻"
        case .sentenceSection: return "문장"
        case .popupTranslationFallbackBadge: return "번역 결과(사전 아님)"
        case .popupDictionaryFeedbackLink: return "뜻이 맞지 않나요?"
        case .popupFeedbackSheetTitle: return "뜻 신고하기"
        case .popupFeedbackOneTap: return "이 뜻이 이상해요"
        case .popupFeedbackEditAndShare: return "직접 뜻 수정해서 공유"
        case .popupFeedbackToastSent: return "감사합니다. 사전 개선에 반영할게요."
        case .cannotSaveTitle: return "저장할 수 없어요"
        case .emptyWordError: return "단어를 입력해 주세요."
        case .emptyMeaningError: return "뜻을 입력해 주세요."
        case .duplicateWordError: return "이미 저장된 단어입니다."
        case .ok: return "확인"
        case .selectAll: return "전체 선택"
        case .deselectAll: return "전체 해제"
        case .deleteSelected: return "선택 삭제"
        case .selectedCount: return "개 선택"
        // HomeView
        case .noBooksGlobal: return "아직 책이 없습니다\nPDF를 추가해보세요"
        case .noBooksInFolder: return "이 폴더에 책이 없습니다"
        case .addBook: return "책 추가하기"
        case .manageFolders: return "폴더 관리"
        // VocabularyByBookView
        case .uncategorized: return "미분류"
        case .noSearchResults: return "검색 결과 없음"
        case .noSearchResultsHint: return "다른 검색어로 시도해 보세요"
        case .noWordsInBook: return "저장된 단어가 없어요"
        case .noWordsInBookHint: return "책을 읽으면서 단어를 탭하면\n여기에 자동으로 모아져요"
        case .searchBooksOrWords: return "책/단어 검색"
        // Streak
        case .resetTodayStarts: return "오늘 시작 기록 초기화"
        case .resetTodayFinishes: return "오늘 완독 기록 초기화"
        // Theme titles
        case .themeStudio: return "스튜디오"
        case .themePaper: return "페이퍼"
        case .themeDusk: return "더스크"
        case .themeMint: return "모노"
        case .themeOcean: return "오션"
        case .themeRose: return "로즈"
        case .themeNoir: return "누아르"
        // WordPopup
        case .meaningSourceCache: return "저장값"
        case .meaningSourceLive: return "실시간 번역"
        case .meaningSourceCandidate: return "직접 선택"
        case .meaningSourceStale: return "저장값(보완중)"
        case .meaningSourceManual: return "수동 입력"
        case .meaningSourceRetry: return "재요청"
        case .meaningSourceUnknown: return "확인중"
        case .meaningConfidenceHigh: return "신뢰 높음"
        case .meaningConfidenceMedium: return "신뢰 중간"
        case .meaningConfidenceLow: return "신뢰 낮음"
        case .meaningConfidenceUnknown: return "신뢰 미정"
        case .meaningPlaceholderNotice: return "의미가 어색할 수 있어요"
        case .popupLoadingMeaning: return "뜻 찾는 중..."
        case .popupMeaningNotFoundRetry: return "뜻을 찾지 못했어요. 잠시 후 다시 시도해 주세요."
        case .popupNoMoreMeanings: return "다른 뜻은 없어요."
        case .popupFindOtherMeanings: return "다른 뜻 보기"
        case .popupUndoSave: return "저장 해제"
        case .popupCandidateLoading: return "다른 뜻 찾는 중..."
        case .popupCandidateInvalid: return "이 뜻 후보는 저장할 수 없어요."
        case .popupCannotSavePlaceholder: return "지금 뜻은 아직 저장할 수 없어요. 다시 불러온 뒤 저장해 주세요."
        case .popupAdjustSelection: return "조정"
        case .popupEnterManually: return "입력"
        case .popupPhraseTranslationLabel: return "번역"
        case .popupPhraseUpgradeHint: return "구문 번역은 프리미엄 기능입니다. 업그레이드하면 구문과 표현을 번역할 수 있어요."
        case .popupSentenceLabel: return "문장 해석"
        case .popupSynonymsLabel: return "동의어"
        case .popupAntonymsLabel: return "반의어"
        case .popupSynonymAntonymHint: return "동의어 · 반의어"
        case .popupSynonymAntonymTitle: return "동의어 · 반의어"
        case .popupSynonymLoading: return "불러오는 중..."
        case .popupSynonymEmpty: return "동의어·반의어를 찾을 수 없어요."
        case .flashcardSynonymLabel: return "동의어·반의어"
        case .flashcardSynonymFront: return "앞면"
        case .flashcardSynonymBack: return "뒷면"
        case .flashcardSynonymHidden: return "숨김"
        case .flashcardSynonymPlacementDesc: return "플래시카드 표시 위치"
        case .popupUpgradeHint: return "프리미엄으로 업그레이드하면 품사별 뜻, 문장 해석, 동의어를 볼 수 있어요."
        case .subscriptionFree: return "무료"
        case .subscriptionPremium: return "프리미엄"
        case .heroEyebrowAccount: return "계정"
        case .themeLocked: return "프리미엄"
        case .premiumFeatureAccurateTitle: return "더 정확한 번역"
        case .premiumFeatureAccurateSubtitle: return "문맥을 반영한 정확한 뜻을 제공해요"
        case .premiumFeaturePosTitle: return "품사별 번역"
        case .premiumFeaturePosSubtitle: return "명사, 동사 등 품사별로 뜻을 확인해요"
        case .premiumFeatureSynonymTitle: return "동의어 · 반의어"
        case .premiumFeatureSynonymSubtitle: return "관련 단어로 어휘력을 넓혀보세요"
        case .premiumFeatureThemeTitle: return "프리미엄 테마"
        case .premiumFeatureThemeSubtitle: return "Paper, Dusk, Mint 테마를 자유롭게 사용해요"
        case .premiumReadDeeper: return "더 깊이, 더 넓게 읽어보세요"
        case .premiumGoButton: return "프리미엄 시작하기"
        case .premiumTrialButton: return "7일 무료 체험하기"
        case .premiumMaybeLater: return "나중에"
        case .premiumSubscribe: return "구독하기"
        case .premiumRestore: return "이미 구독 중이신가요? 복원하기"
        case .premiumTrialDaysLeft: return "일 남음"
        case .premiumTrialEnded: return "무료 체험이 종료되었습니다"
        }
    }

    private static func chinese(_ key: AppString) -> String {
        switch key {
        case .library: return "书架"
        case .review: return "复习"
        case .settings: return "设置"
        case .myLibrary: return "我的书架"
        case .today: return "今天"
        case .customizeLibrary: return "自定义书架"
        case .libraryTheme: return "主题"
        case .noPDFTitle: return "没有PDF文件"
        case .noPDFBody: return "添加文档即可开始阅读。"
        case .noWordsTitle: return "还没有单词"
        case .noWordsBody: return "阅读时保存的单词会显示在这里。"
        case .refresh: return "刷新"
        case .startReadingTitle: return "开始阅读"
        case .startReadingBody: return "保存一个单词或阅读10分钟即可。"
        case .readingStreak: return "连续阅读"
        case .words: return "单词"
        case .settingsLanguage: return "语言"
        case .settingsReading: return "阅读"
        case .settingsAppLanguage: return "语言"
        case .settingsAutoSave: return "自动保存单词"
        case .settingsPopupSize: return "弹窗大小"
        case .popupSizeCompact: return "紧凑"
        case .popupSizeNormal: return "普通"
        case .popupSizeLarge: return "大号"
        case .settingsInterval: return "间隔"
        case .settingsTime: return "时间"
        case .settingsDays3: return "3天"
        case .settingsDays5: return "5天"
        case .settingsDays7: return "7天"
        case .settingsOff: return "关闭"
        case .save: return "保存"
        case .saved: return "已保存"
        case .refine: return "重新识别"
        case .adjustBox: return "调整框选"
        case .manualEntry: return "手动输入"
        case .streakMsg0: return "今天迈出小小一步就够了。"
        case .streakMsg1: return "好的开始，继续保持。"
        case .streakMsgLow: return "平稳的节奏正在形成。"
        case .streakMsgHigh: return "坚持的习惯，保持你的节奏。"
        case .days: return "天"
        case .delete: return "删除"
        case .cancel: return "取消"
        case .done: return "完成"
        case .deleteFolderTitle: return "删除此文件夹？"
        case .deleteFolderMessage: return "文件夹内的所有单词将被删除。"
        case .confirmDeleteTitle: return "确定要删除吗？"
        case .dontAskAgainToday: return "今天不再询问"
        case .calendar: return "日历"
        case .loading: return "加载中..."
        case .translationEngine: return "引擎"
        case .translationEngineDeepL: return "DeepL"
        case .translationEngineServer: return "上下文服务器"
        case .contextServer: return "上下文服务器"
        case .contextServerURL: return "服务器URL"
        case .contextServerURLPlaceholder: return "https://..."
        case .contextServerToken: return "服务器令牌"
        case .contextServerTokenPlaceholder: return "Bearer令牌（托管服务器必填）"
        case .contextServerHelp: return "应用将选中的单词和句子发送到服务器，获取上下文相关的释义和同义词。托管服务器应要求Bearer令牌和请求签名密钥。"
        case .contextServerTest: return "测试连接"
        case .contextServerTesting: return "连接测试中..."
        case .contextServerTestSuccess: return "连接成功"
        case .contextServerTestFail: return "连接失败"
        case .contextServerInvalidURL: return "URL格式无效。"
        case .meaningOptionsTitle: return "其他释义"
        case .translationSource: return "翻译源语言"
        case .translationSourceAuto: return "自动检测"
        case .translationTarget: return "翻译目标语言"
        case .translationAuto: return "自动"
        case .clear: return "清除"
        case .keyEmpty: return "密钥为空。"
        case .saveSuccess: return "已保存。"
        case .saveFailed: return "保存失败。"
        case .clearSuccess: return "已清除。"
        case .languageEnglish: return "英语"
        case .languageKorean: return "韩语"
        case .languageChinese: return "中文"
        case .koreanDictionarySection: return "韩语词典"
        case .koreanDictionaryKey: return "API密钥"
        case .koreanDictionaryKeyPlaceholder: return "粘贴API密钥"
        case .koreanDictionaryGetKey: return "获取免费密钥"
        case .koreanDictionaryTest: return "测试"
        case .koreanDictionaryTestSuccess: return "连接成功！"
        case .koreanDictionaryTestFail: return "失败，请检查密钥。"
        // Reader
        case .retry: return "重试"
        case .reload: return "重新加载"
        case .loadingPDF: return "PDF加载中"
        case .loadingImage: return "加载中"
        case .loadingShort: return "加载中"
        case .loadingDelayed: return "加载延迟"
        case .loadingWait: return "请稍等"
        case .loadingStill: return "仍在加载"
        case .loadingMoment: return "请稍候"
        case .pdfLoadFailedTitle: return "无法打开PDF"
        case .pdfLoadFailedBody: return "文件可能已损坏或格式不受支持。"
        case .imageLoadFailedTitle: return "无法打开图片"
        case .imageLoadFailedBody: return "文件可能已损坏或格式不受支持。"
        case .thumbnailTimeout: return "缩略图加载超时，请重试。"
        case .adjustBoxTitle: return "选择范围过大"
        case .adjustBoxTruncatedMessage: return "选择内容过长，已自动缩短以便查询。"
        case .adjustBoxNoWordMessage: return "选择结果为空，请调整框选范围。"
        case .adjustBoxEmptyMessage: return "未找到单词，请缩小框选范围后重试。"
        case .selectionLimitToast: return "仅查找前8个单词"
        case .longPressMode: return "长按"
        // Words tab
        case .modeStripTitle: return "连续浏览"
        case .folderDeleteHint: return "选择后点击删除"
        case .folderEditLabel: return "编辑"
        case .folderDeleteConfirmMessage: return "将删除这些文件夹及其中的所有单词，此操作不可撤销。"
        case .legendGoalText: return "全部掌握"
        case .legendStartedText: return "已开始"
        case .legendFinished: return "已完成"
        case .deleteAll: return "全部删除"
        case .cannotUndo: return "此操作不可撤销。"
        case .rename: return "重命名"
        case .renameMessage: return "请输入新名称。"
        case .renamePlaceholder: return "标题"
        case .openInBook: return "在书中查看"
        case .masteryUnknown: return "不认识"
        case .masteryKnown: return "已掌握"
        case .masteryUnsure: return "不确定"
        case .masteryClear: return "清除"
        case .flashcardFlipHint: return "点击翻转"
        case .flashcardEdit: return "编辑"
        case .wordSection: return "单词"
        case .meaningSection: return "释义"
        case .sentenceSection: return "句子"
        case .popupTranslationFallbackBadge: return "翻译结果（非词典）"
        case .popupDictionaryFeedbackLink: return "释义不准确？"
        case .popupFeedbackSheetTitle: return "报告此释义"
        case .popupFeedbackOneTap: return "这个释义有问题"
        case .popupFeedbackEditAndShare: return "编辑并分享更正"
        case .popupFeedbackToastSent: return "谢谢。我们会审核并改进。"
        case .cannotSaveTitle: return "无法保存"
        case .emptyWordError: return "请输入单词。"
        case .emptyMeaningError: return "请输入释义。"
        case .duplicateWordError: return "该单词已保存。"
        case .ok: return "确定"
        case .selectAll: return "全选"
        case .deselectAll: return "取消全选"
        case .deleteSelected: return "删除"
        case .selectedCount: return "已选"
        // HomeView
        case .noBooksGlobal: return "还没有书\n添加PDF开始阅读"
        case .noBooksInFolder: return "此文件夹中没有书"
        case .addBook: return "添加书籍"
        case .manageFolders: return "管理文件夹"
        // VocabularyByBookView
        case .uncategorized: return "未分类"
        case .noSearchResults: return "无结果"
        case .noSearchResultsHint: return "试试其他搜索词"
        case .noWordsInBook: return "还没有保存的单词"
        case .noWordsInBookHint: return "阅读时点击单词\n它们会自动显示在这里"
        case .searchBooksOrWords: return "搜索书籍或单词"
        // Streak
        case .resetTodayStarts: return "重置今日开始记录"
        case .resetTodayFinishes: return "重置今日完成记录"
        // Theme titles
        case .themeStudio: return "工作室"
        case .themePaper: return "纸张"
        case .themeDusk: return "黄昏"
        case .themeMint: return "单色"
        case .themeOcean: return "海洋"
        case .themeRose: return "玫瑰"
        case .themeNoir: return "暗黑"
        // WordPopup
        case .meaningSourceCache: return "缓存"
        case .meaningSourceLive: return "实时翻译"
        case .meaningSourceCandidate: return "手动选择"
        case .meaningSourceStale: return "缓存（更新中）"
        case .meaningSourceManual: return "手动输入"
        case .meaningSourceRetry: return "重新请求"
        case .meaningSourceUnknown: return "检查中"
        case .meaningConfidenceHigh: return "高置信度"
        case .meaningConfidenceMedium: return "中等置信度"
        case .meaningConfidenceLow: return "低置信度"
        case .meaningConfidenceUnknown: return "置信度未定"
        case .meaningPlaceholderNotice: return "释义可能不够准确"
        case .popupLoadingMeaning: return "正在查询释义..."
        case .popupMeaningNotFoundRetry: return "未找到释义，请稍后重试。"
        case .popupNoMoreMeanings: return "没有其他释义了。"
        case .popupFindOtherMeanings: return "查看其他释义"
        case .popupUndoSave: return "取消保存"
        case .popupCandidateLoading: return "正在查找其他释义..."
        case .popupCandidateInvalid: return "此候选释义无法保存。"
        case .popupCannotSavePlaceholder: return "当前释义暂时无法保存，请刷新后重试。"
        case .popupAdjustSelection: return "调整"
        case .popupEnterManually: return "手动"
        case .popupPhraseTranslationLabel: return "翻译"
        case .popupPhraseUpgradeHint: return "短语翻译是高级功能。升级后可翻译短语和表达。"
        case .popupSentenceLabel: return "句子翻译"
        case .popupSynonymsLabel: return "同义词"
        case .popupAntonymsLabel: return "反义词"
        case .popupSynonymAntonymHint: return "同义词与反义词"
        case .popupSynonymAntonymTitle: return "同义词与反义词"
        case .popupSynonymLoading: return "加载中..."
        case .popupSynonymEmpty: return "未找到同义词或反义词。"
        case .flashcardSynonymLabel: return "同义词·反义词"
        case .flashcardSynonymFront: return "正面"
        case .flashcardSynonymBack: return "背面"
        case .flashcardSynonymHidden: return "隐藏"
        case .flashcardSynonymPlacementDesc: return "在闪卡上的显示位置"
        case .popupUpgradeHint: return "升级至高级版，可查看按词性分类的释义、句子翻译和同义词。"
        case .subscriptionFree: return "免费"
        case .subscriptionPremium: return "高级版"
        case .heroEyebrowAccount: return "账户"
        case .themeLocked: return "高级版"
        case .premiumFeatureAccurateTitle: return "更准确的翻译"
        case .premiumFeatureAccurateSubtitle: return "基于上下文的AI智能释义"
        case .premiumFeaturePosTitle: return "按词性分类释义"
        case .premiumFeaturePosSubtitle: return "一次查看名词、动词等各词性释义"
        case .premiumFeatureSynonymTitle: return "同义词与反义词"
        case .premiumFeatureSynonymSubtitle: return "通过相关词汇扩展词汇量"
        case .premiumFeatureThemeTitle: return "高级主题"
        case .premiumFeatureThemeSubtitle: return "解锁Paper、Dusk、Mint主题"
        case .premiumReadDeeper: return "更深入、更广泛地阅读"
        case .premiumGoButton: return "升级高级版"
        case .premiumTrialButton: return "免费试用7天"
        case .premiumMaybeLater: return "以后再说"
        case .premiumSubscribe: return "订阅"
        case .premiumRestore: return "已经订阅？恢复购买"
        case .premiumTrialDaysLeft: return "天试用剩余"
        case .premiumTrialEnded: return "免费试用已结束"
        }
    }

    static func popupMoreMeanings(_ count: Int) -> String {
        switch AppLanguage.current() {
        case .chinese:
            return "查看另外\(count)个释义"
        case .korean:
            return "뜻 \(count)개 더 보기"
        case .english, .system:
            return "See \(count) More Meanings"
        }
    }
}
