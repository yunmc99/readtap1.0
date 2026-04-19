# ReadTap 앱 전체 기능 명세서 (UI/UX 리디자인용)

> 이 문서는 ReadTap iOS 앱의 모든 기능을 빠짐없이 기술합니다. UI/UX만 대개편하고 기능은 100% 유지하기 위한 참고 자료입니다.

---

## 1. 앱 구조 개요

- **플랫폼**: iOS (iPhone + iPad)
- **프레임워크**: SwiftUI
- **화면 방향**: iPhone 세로/가로, iPad 전방향
- **다크모드**: 비활성 (라이트 모드 고정)
- **언어**: 영어 / 한국어 (인앱 전환)
- **탭 구조**: 4탭 (홈 / 라이브러리 / 단어장 / 설정)

---

## 2. 앱 진입 흐름

### 2.1 스플래시 화면
- 흰 배경에 "ReadTap" (42pt bold, 녹색 RGB(31,173,97)) + 태그라인 "Your reading companion" (14pt, 블루그레이)
- 펄싱 애니메이션: 스케일 1.0↔1.03, 투명도 1.0↔0.75 반복
- 최소 2.4초 표시 (앱 워밍업과 병렬)
- 종료 시 확대(1.2) → 축소(0.92) → 복귀(1.0) → 페이드아웃 애니메이션

### 2.2 인증 분기
- **로딩 중** → 스플래시 표시
- **미로그인** → 로그인 화면
- **로그인됨** → 메인 탭 화면
- **계정 정지** → 정지 안내 화면 (로그아웃만 가능)

### 2.3 로그인 화면
- **상단 히어로 영역 (화면 42%)**:
  - 소프트 녹색 그라데이션 배경
  - 애니메이션 글로우 오브 + 22개 파티클 필드
  - "Read" (검정) + "Tap" (녹색) 타이포그래피 + 드롭 셰도우
  - 태그라인: "Every word you tap, remembered"
  - 다국어 마이크로 태그: 읽다, 学ぶ, Leer

- **하단 폼 영역 (화면 60%)**:
  - 흰색 카드 + 둥근 모서리 + 그림자 + 풀 핸들
  - **Apple 로그인**: 네이티브 ASAuthorizationAppleIDButton
  - **Google 로그인**: 커스텀 필 버튼 (컬러풀 G 아이콘)
  - **이메일/비밀번호**: 접이식 폼
    - 로그인 모드: 이메일 + 비밀번호
    - 회원가입 모드: 이메일 + 비밀번호 + 비밀번호 확인
    - 비밀번호 표시/숨기기 토글
    - 최소 6자 검증, 이메일 형식 검증, 비밀번호 일치 검증
    - 포커스 상태 테두리 하이라이트
  - 에러 배너 (아이콘 + 닫기 버튼, 색상 구분)
  - 로딩 오버레이 (반투명 + 스피너 + 텍스트)
  - 하단 이용약관 / 개인정보처리방침 링크

### 2.4 계정 정지 화면
- 방패 아이콘 (빨강)
- "Account Suspended" 제목
- 정지 사유 (관리자 제공 시)
- 설명 메시지
- 로그아웃 버튼 (빨강)

---

## 3. 커스텀 탭 바

### 3.1 탭 4개
| 탭 | 아이콘 | 화면 |
|---|---|---|
| 홈 | house.fill | HomeDashboardView |
| 라이브러리 | books.vertical.fill | LibraryView |
| 단어장 | tray.full.fill | WordsHubView |
| 설정 | gearshape.fill | SettingsView |

### 3.2 탭 바 디자인
- HStack, 6px 간격
- 높이: max(76, safeBottom + 42)
- 배경: 테마별 LinearGradient (dockTop → dockBottom)
- 테두리: 1px dockBorder 색상
- 모서리: 26px continuous
- 그림자: 2층 (18px 0.07 + 6px 0.035 투명도)
- 좌우 마진: 20px

### 3.3 탭 버튼 디자인
- VStack (아이콘 + 라벨)
- 아이콘: 32×32 둥근 사각형 배경 (12px radius)
  - 활성: activeGlyphBackground + activeGlyphStroke 테두리
  - 비활성: glyphBackground + glyphStroke 테두리
- 글리프: 16pt bold filled
- 라벨: 10.5pt semibold
- 활성 색상: 테마 accentColor / 비활성: muted
- 전환 애니메이션: snappy 0.22초

### 3.4 iPad 대응
- Regular 너비: ManualTabContainer (opacity 기반 페이지 전환)
- Compact 너비: 네이티브 TabView

---

## 4. 홈 탭 (HomeDashboardView / HomeView)

### 4.1 빈 상태 (책 없을 때)
- book.closed 아이콘 (40pt, light weight)
- "아직 책이 없어요" / "No books yet" 헤드라인
- "PDF나 이미지를 가져와서\n읽기를 시작해 보세요" 서브텍스트
- "파일 가져오기" CTA 버튼 (plus.circle.fill, 테마 accentColor)

### 4.2 폴더 필터 바
- 수평 ScrollView (인디케이터 없음)
- "All" 칩 (항상 표시) + 동적 폴더 칩들
- 활성 칩: themeAccent 배경 16% 투명도, semibold
- 비활성 칩: secondarySystemBackground, regular
- 캡슐 모양, 12px 좌우/6px 상하 패딩, caption 폰트

### 4.3 책 그리드
- 2열 LazyVGrid
- 아이템 너비: (화면너비 - 24 - 32 - 14) / 2
- 아이템 높이: 너비 × 1.35
- 간격: 가로 14px, 세로 16px

### 4.4 책 카드
- **커버 이미지 영역**:
  - 높이: itemWidth × 1.35
  - 배경: theme.cardSurface
  - 모서리: 12px continuous
  - 커버 이미지 or 대체 아이콘 (doc.richtext, 28pt)
  - 테두리: theme.cardStroke 1px
  - 그림자: black 10%, radius 10, offset (0,6)

- **제목 영역**:
  - .subheadline, semibold
  - 최대 2줄
  - 색상: theme.titleColor
  - 커버와 8px 간격

- **드래그&드롭 피드백**:
  - 스케일 1.04 확대
  - 점선 테두리 (소스: 주황, 타겟: themeAccent)
  - 스프링 애니메이션 (response 0.3, damping 0.7)

### 4.5 컨텍스트 메뉴 (롱프레스)
- **이름 변경**: pencil 아이콘 → 이름 변경 다이얼로그
- **삭제**: trash 아이콘 (빨강) → 확인 다이얼로그
- **폴더 지정**: folder 아이콘 → FolderPickerSheet

### 4.6 드래그&드롭 정렬
- 책 드래그: NSItemProvider로 book.id 제공
- 드롭: OrderKey.between(prevKey, nextKey)로 새 키 생성
- 이동된 아이템만 orderKey 업데이트 (전체 리넘버링 없음)
- LexoRank-lite base-36 알고리즘

### 4.7 상단 툴바
- 좌측: StreakView (독서 연속 일수 표시)
- 우측: "folder.badge.plus" → FolderManagerView 시트 (medium/large detent)

### 4.8 플로팅 액션 버튼 (FAB)
- 위치: 우하단 (18px trailing, 18px bottom)
- 아이콘: plus (18pt, semibold)
- 크기: 54×54 원형
- 색상: themeAccent fill
- 그림자: black 18%, radius 10, offset (0,6)
- 탭 → 파일 임포터 열기

### 4.9 파일 가져오기
- 지원 형식: .pdf, .image
- 보안 스코프 리소스 접근
- 중복 파일명 자동 처리 (basename 2.ext, 3.ext...)
- 가져오기 후 처리: 커버 생성 + 페이지 수 캐싱 + OCR 프라이밍
- 커버: 첫 페이지 240px 너비 PNG

---

## 5. 라이브러리 탭 (LibraryView)

### 5.1 헤더 섹션
- **검색 바**: 돋보기 아이콘, 클리어 버튼, 실시간 필터링
  - 대소문자 무시, 제목 + 폴더명 + 타입 키워드 검색
- **액션 버튼들**: 52×52 둥근 사각형
  - 선택 모드 토글 (체크박스 아이콘)
  - 폴더 관리 메뉴
  - 활성: themeAccent 배경 + 흰색 아이콘
  - 비활성: surfaceStrong + accent 아이콘

### 5.2 "지금 읽는 중" 패널
- **섹션 헤더**: 아이브로우 텍스트 (11pt bold, uppercase) + 제목 (18pt heavy) + 배지 (책 수)
- **카드 레이아웃**: Wide(iPad): HStack / Narrow(iPhone): VStack
- **카드 내용**:
  - 커버 썸네일 (작은 크기)
  - 제목 (subheadline, semibold)
  - 독서 진행 메타데이터:
    - 마지막 열람 시간 (상대 시간)
    - 페이지 (예: "Page 42 of 287")
    - 진행률 배지
  - 스타일: 20px 모서리, 1px 테두리
  - 선택 상태: accent 투명도 22% 테두리

- **카드 부제목 로직**:
  - 오늘 읽는 중: "Spent 12 min reading • 18 more min until goal"
  - 최근 열람: "Last read 2 hours ago • Page 42 of 287"
  - 시작함: "Started 5 days ago"
  - 기본: "Ready to read"

### 5.3 서재 패널 (전체 책)
- **그리드 레이아웃**: iPad 3열(min 220px) / iPhone 2열(min 160px), 14px 간격
- **서재 카드**: 커버 이미지 + 오버레이 + 제목 + 폴더 배지 + 마지막 열람 날짜
- 드래그&드롭, 컨텍스트 메뉴, 선택 모드 지원

### 5.4 다중 선택 모드
- 원형 체크박스 (24×24)
  - 미선택: surfaceStrong fill + borderSoft stroke 1.2px
  - 선택됨: accent fill + accent stroke 1.2px
- **하단 액션 바** (선택 시 표시):
  - X 닫기 버튼
  - 삭제 버튼 → 확인 다이얼로그 ("Delete selected N PDFs?")

### 5.5 빈 서재 상태
- "책이 없어요" 헤드라인 + "PDF 가져오기" CTA 버튼

### 5.6 메타데이터 칩
- 카드당 최대 2개: 폴더명, 마지막 열람, 진행률
- 테마 색상 배지

---

## 6. PDF 리더 (ContentView)

### 6.1 리더 모드
- **읽기 모드** (.reading): 롱프레스 단어 조회 활성
- **쓰기 모드** (.writing): 마크업/드로잉 활성

### 6.2 상단 크롬 바
- 페이지 수 표시
- 언어 대상 피커 버튼
- 썸네일 사이드바 토글 버튼
- 페이지 이동 버튼 (모달 입력)

### 6.3 하단 크롬 바
- 북마크 토글 버튼
- 이전/다음 페이지 네비게이션
- 프로그레스 슬라이더

### 6.4 크롬 표시/숨기기
- 싱글 탭으로 토글
- 디바운스 처리 (0.16초)
- 팝업 열려있을 때는 무시

### 6.5 썸네일 사이드바
- 레이지 로딩 PDF 페이지 썸네일
- 캐싱 처리
- 타임아웃 처리
- 너비 컨테이너 적응

### 6.6 롱프레스 단어 조회

#### 제스처 인식
- 최소 프레스 시간: 0.15~0.20초
- 허용 이동 거리: 12pt
- 커스텀 제스처 인식기 (시스템 돋보기 회피)
- 디바운스: 중복 0.22초, 선택 변경 0.14초, 폴백 쿨다운 0.02초

#### 텍스트 선택 해상도 (우선순위 순)
1. **텍스트 레이어** (PDFKit 네이티브, 가장 빠름)
2. **OCR 캐시** (사전 계산, 페이지별 인덱싱)
3. **라이브 OCR 폴백** (온디맨드, 텍스트 레이어 실패 시)

#### 히트 거리 검증
- 최소: 4pt / 스케일: 단어 rect 짧은 변의 0.6배 / 최대: 24pt

#### 텍스트 정규화
- 공백 정리, 구두점 제거, 악센트 처리
- CJK 단어 경계 감지
- 합쳐진 단어 분리 ("contraryto" → "contrary" + "to")
- UITextChecker 맞춤법 기반 3분할/2분할 시도

### 6.7 단어 팝업 (WordPopupView)

#### 팝업 콘텐츠 섹션
1. **단어 헤더**: Bold 20pt (refined) / 18pt (classic), 1~2줄
2. **기본 뜻** (무료): 14pt, 최대 4줄
3. **로딩 상태**: 프로그레스 인디케이터 + "Looking up meaning..."
4. **품질 안내**: 의미 출처, 신뢰도 표시
5. **하위 단어 제안** ("이 뜻인가요?" / "Did you mean?"): 단어 카드 (단어 + 품사 + 정의)
6. **문장 번역** (프리미엄): 문맥 문장 한국어 번역 (12pt, muted)
7. **동의어** (프리미엄 폴백): 쉼표 구분 목록
8. **프리미엄 LLM 로딩**: 3개 시머 애니메이션 박스
9. **프리미엄 구문 모드**: "PHRASE TRANSLATION" 라벨 + 번역 + 설명
10. **프리미엄 품사별 뜻**: 품사 그룹별 의미 목록, 선택/해제 가능, 취소선

#### 액션 버튼 행 (동적 레이아웃)
- **선택 범위 조정** (Adjust Selection): onAdjustBox 제공 시
- **저장 취소** (Undo Save): 자동저장 활성 + 저장됨 상태일 때
- **수동 입력** (Manual Entry): onManualEntry 제공 시
- **저장** (Save/Saved): 주요 액션, 저장됨/로딩 중 시 비활성
- 레이아웃: 수평 (다 들어가면) or 2×2 그리드 (오버플로 시)
- 캡슐 모양 + stroke

#### 팝업 스타일링
- **Refined 모드**: warmSurface 배경, 22pt 모서리, 20pt 그림자, rounded 폰트
- **Classic 모드**: ultraThinMaterial + glassTint, 16pt 모서리, 12pt 그림자
- **최대 크기**: 너비 208~316pt, 높이 168~404pt + 프리미엄/제안 오버플로

### 6.8 하이라이트 시스템
- 저장된 단어 → PDF에 하이라이트 어노테이션 자동 표시
- 알파: 0.40~0.45
- 커스텀 하이라이트 색상 지원 (preset: themeDefault, yellow, peach, lavender, mint, skyBlue, coral)
- 겹침 감지: 큰 하이라이트가 작은 것에 우선
- 문서 변경/어휘 변경 시 자동 갱신

### 6.9 마크업/드로잉 시스템
- PencilKit PKCanvasView 오버레이
- **잉크 도구**: 펜, 마커, 형광펜 (색상 & 굵기 프리셋)
- **지우개 도구**: 벡터(깔끔) or 비트맵(부분)
- 자동 저장 (BookDrawingStore)
- 실행 취소/다시 실행 지원

### 6.10 가로 모드 페이지 넘기기
- 팬 제스처 (2페이지 가로 모드)
- 최소 속도: 280pt/s
- 최소 거리: 42pt
- 최대 수직 비율: 55%
- 쿨다운: 0.28초
- 줌 상태에서도 동작

### 6.11 북마크
- 하단 크롬 토글 버튼
- UserDefaults 저장 (bookmarks_{bookId})
- 페이지 인덱스 저장

### 6.12 독서 진행 추적
- 페이지 변경 시 자동 저장 (BookReadingStatusStore + ReadingProgressStore)
- 줌 리셋, 선택 초기화, 조회 상태 무효화

### 6.13 페이지 이동 (Jump to Page)
- 모달 입력 + 키보드

### 6.14 PDF 로딩 & 에러 처리
- 로딩 오버레이: 0.08초 후 표시
- 진행 메시지: "Loading PDF..." → "Finding first page..." → "Waiting for interaction..."
- 재시도 로직: 점진적 백오프 + 수동 재시도 버튼
- 타임아웃: 10초 이상 시 수동 인터랙션 요청

### 6.15 인-리더 단어장 시트 (ReaderWordbookSheet)
- 모달 시트 (리더 닫지 않음)
- 현재 책의 저장된 단어 모두 표시
- 마스터리 상태 필터: 전체 / 모름 / 앎
- 탭 → 해당 위치에서 플래시카드 시작
- 왼쪽 스와이프 → 마스터리 토글 (모름 ↔ 앎)
- 오른쪽 스와이프 → 삭제

---

## 7. 이미지/OCR 리더 (ImageReaderView)

### 7.1 핵심 기능
- 전체화면 이미지 표시 + 줌/팬
- Vision 기반 OCR (줄 단위 감지)
- 탭-투-셀렉트 단어 인터랙션
- 실시간 OCR 단어 오버레이 그리드
- 이미지별 OCR 결과 캐싱

### 7.2 UI 요소
- **상단 크롬**: 닫기 버튼 + 페이지 번호 + 언어 감지 인디케이터
- **하단 크롬**: 이전/다음 이미지 버튼 + 페이지 카운터
- **OCR 단어 오버레이**: 각 OCR 단어 바운딩 박스, 탭-투-셀렉트 하이라이팅

### 7.3 제스처
- **싱글 탭 (OCR 단어)**: 단어 선택 → 팝업 즉시 표시
- **드래그 (다중 선택)**: 줄 간 선택 확장, 인접 단어 병합, 최대 12단어
- **핀치 줌 & 팬**: 네이티브

### 7.4 OCR 처리
- **캐시**: 이미지별 핑거프린팅, LRU 축출 (24개), TTL 3분
- **적응형 처리**: 최대 3패스 + 점진적 개선
- **언어 기반 튜닝**: 한글 vs 라틴 vs CJK
- **최소 요청 간격**: 0.24초
- **재시도**: 지수 백오프 (35~45초 기본 딜레이)

### 7.5 언어 감지
- 한글 비율 계산
- 혼합 스크립트 처리
- CJK 문자 감지
- 오버라이드 메커니즘

---

## 8. 단어 조회 파이프라인

### 8.1 조회 소스 (우선순위 순)
1. **저장된 어휘** - 로컬 DB
2. **번역 캐시** - 이전 결과
3. **한국어 사전** - 단일어 한국어 사전 API
4. **컨텍스트 서비스** - 서버 기반 문맥 조회 API
5. **MyMemory** - 폴백 번역 API
6. **시스템 사전** - macOS 사전

### 8.2 조회 파이프라인
1. 선택 처리 → 페이지/위치 검증, 앵커 위치 계산, 언어 감지
2. 단어 정규화 → 구두점 제거, CJK 처리, 합쳐진 토큰 분리
3. 의미 조회 → 캐시 확인 → 자동저장(활성 시) → 라이브 조회 → 캐싱
4. 후보 확장 → 번역 서비스 후보 로드, 캐시된 의미 활용
5. 프리미엄 보강 → OpenAI 엔드포인트 호출, 품사별 의미 or 구문 번역
6. 팝업 표시 → WordPopupState 생성, 앵커 위치 설정, 프로모 체크

### 8.3 캐싱 전략
- **의미 캐시**: 단어 + 문맥 해시 키
- **후보 캐시**: 단어 + 소스언어 + 대상언어 키, 최대 5개
- **프리미엄 캐시**: 단어 키, 인메모리, 팝업 닫기 시 클리어

### 8.4 한국어 사전 서비스
- 정확/접두어 매치 조회
- 복합어 분해 (subword suggestions)
- 앞축소 + 뒤축소 하위 단어 생성
- 동시 배치 조회

### 8.5 번역 서비스
- **Apple Translation** (온디바이스)
- **DeepL** (클라우드)
- **MyMemory** (폴백)
- **Papago** (한국어)
- **CompositeTranslator** (자동 선택)
- 자동 언어 감지, 캐싱, 실패 시 폴백 체인

### 8.6 프리미엄 조회 서비스 (OpenAI)
- `/premium-lookup` 엔드포인트
- 모드: "word" (사전) or "phrase" (번역)
- **word 응답**: 품사별 의미 배열
- **phrase 응답**: 번역 + 설명
- 인증: Bearer 토큰 + Client ID + HMAC-SHA256 서명

### 8.7 컨텍스트 서비스
- 서버 기반 문맥 단어 조회
- 다국어 지원
- 사전 + 번역 반환
- Keychain API 키 저장
- HMAC-SHA256 요청 서명

---

## 9. 단어장 탭 (WordsHubView / WordsTabView)

### 9.1 주요 모드 2가지
1. **날짜별 보기** - 캘린더 + 날짜별 어휘 분류
2. **책별 보기** - 책별 단어 수, 검색, 필터, 정렬

### 9.2 날짜별 보기

#### 스트립 모드
- 날짜 필(pill)에 단어 수 표시 (시작/완료 인디케이터)
- 오늘로 스크롤 기능
- 일별 폴더 브라우저
- 다중 선택 모드 (폴더 일괄 삭제)
- 폴더 이름 변경 다이얼로그 (유효성 검사)
- 독서 스트릭 마커 (일별 읽기 시작/완료)
- 마스터리 상태 배지 (unknown/started/finished/known)

#### 월간 모드
- 월간 캘린더 선택기
- 일별 어휘 수 (전체/모름/앎 분류)
- 독서 스트릭 표시

#### 일별 상세 (DayBookWordsView)
- 마스터리 상태 필터 (전체/모름/시작/완료/앎)
- 롱프레스 다중 선택
- 일괄 삭제 + 확인 다이얼로그
- 개별 삭제 (스와이프/버튼)
- 원본 책에서 단어 열기
- 마스터리 토글 (모름 ↔ 앎, 스와이프)

### 9.3 책별 보기
- **검색**: 책 제목 or 단어로 검색
- **필터**: 전체 / 무료 / 프리미엄 / 미분류
- **정렬**: 최근 / 알파벳 / 단어 수 많은 순
- **책 폴더 카드**:
  - 커버 이미지 (폴백: 시드 기반 그라데이션)
  - 단어 수 (전체/모름/프리미엄)
  - 날짜 추적 (최근 저장 날짜 표시)
  - 다중 선택 + 일괄 작업
  - 리더에서 열기

### 9.4 폴더 상세 (WordsFolderDetailView)

#### 히어로 카드
- 커버 이미지 (시드 기반 폴백 그라데이션)
- 책 제목 + 단어 통계
- 빠른 액션: 플래시카드 복습, 책에서 열기, 프리미엄 기능
- 성능 메트릭: 저장 단어 수, 학습 진행률

#### 콘텐츠 섹션
- 마스터리 상태 필터 + 배지 카운트
- 정렬: 최근/알파벳/조회 수 많은 순
- 폴더 내 검색
- 다중 선택 일괄 삭제 + 개별 삭제/스와이프

#### 단어 행
- 단어 + 뜻 + 문장 미리보기
- 마스터리 상태 배지 (체크마크/물음표/X)
- 페이지 참조 + 저장 날짜
- 책에서 열기 버튼
- 컨텍스트 메뉴

#### 선택 모드
- 개별 선택/해제 + 전체 선택/해제
- 선택 수 표시
- 일괄 삭제 + 확인
- 뒤로가기 시 선택 모드 종료

### 9.5 날짜별 어휘 (VocabularyByDateView)
- 날짜별 섹션 (최신 순)
- 섹션 헤더 (예: "March 24, 2026")
- 단어 행: 단어 + 뜻 + 문장 미리보기(2줄) + 페이지 참조
- 탭 → 책에서 열기
- 빈 상태 아이콘 + 메시지

### 9.6 간단 어휘 리스트 (VocabularyListView)
- 최근 200개 단어
- 탭 → 확장/축소 상세
- 오른쪽 스와이프: 삭제 (빨강)
- 왼쪽 스와이프: 마스터리 토글 (모름 ↔ 앎)
- 단어 행: 4px 좌측 색상 스트라이프 (마스터리 색상) + 단어 + 뜻 + 아이콘
- 확장 시: 문장, 페이지 참조, 날짜, 책에서 열기 버튼
- 빈 상태 메시지

### 9.7 플래시카드 (FlashcardDeckView)

#### 카드 인터랙션
- **탭**: 앞면/뒷면 플립 애니메이션
- **위로 스와이프**: "앎" (Known, 녹색)
- **아래로 스와이프**: "모름" (Unknown, 빨강)
- **왼쪽 스와이프**: "불확실" (Unsure, 노랑)
- **오른쪽 스와이프**: 건너뛰기 (변경 없음)

#### 카드 표시 정보
- **앞면**: 단어 (CJK 텍스트 크기 조정)
- **뒷면**: 뜻 + 프리미엄 기능:
  - 품사별 의미 (명사/동사 등)
  - 문장 번역
  - 동의어
- **컨텍스트**: 책 이름, 저장 날짜, 페이지 참조

#### 오버레이 모드
- 상세 시트: 전체 뜻, 문장, 메타데이터
- 편집 시트: 인라인 편집 (단어/뜻/문장 3섹션)
- 삭제 확인
- 카드 복사

#### 카드별 액션
- 편집, 삭제, 복사, 마스터리 토글, 책에서 열기
- 스와이프 방향 피드백 오버레이
- 현재 카드 위치 인디케이터
- "다음" 버튼 or 스와이프 자동 진행
- 토스트 알림

---

## 10. 설정 탭 (SettingsView)

### 10.1 계정 섹션
- 로그아웃 버튼
- 사용자 이메일/표시 이름 (로그인 시)
- 계정 상태 (무료/프리미엄)
- 트라이얼 남은 일수 배지
- 프리미엄 업그레이드 버튼

### 10.2 외관 설정
- **테마 피커**: Studio / Paper / Dusk / Mint / Ocean 등
  - 무료: Studio, Ocean (2개)
  - 프리미엄: + Paper, Mint (4개)
  - 잠긴 테마: 자물쇠 아이콘 + "PREMIUM" 배지
  - 미리보기 버튼 → 전체화면 프리뷰 시트

- **테마 프리뷰 시트 내용**:
  1. 헤더: 테마 제목 (22pt heavy) + 부제 (13pt)
  2. 히어로 카드: 계정 미리보기 + RT 배지 + 프리미엄 배지
  3. 비주얼 테마 섹션: 테마 이름 필 + 설명
  4. 독서 캘린더 섹션: 21일 캘린더 그리드 + 활동 점
  5. 탭 컨트롤 섹션: 세그먼트 컨트롤 미리보기
  - 하단 액션: "Unlock Premium to Apply" (잠긴 경우) / "Apply This Theme" / "Cancel"

- **언어 선택**: 영어/한국어
- **팝업 크기**: Compact / Normal / Large (스케일 미리보기)

### 10.3 읽기 설정
- **자동 저장 토글**: 롱프레스 시 자동 단어 저장
- **롱프레스 모드 토글**: 팝업 활성화/비활성화
- **하이라이트 색상 프리셋 선택기**: themeDefault, yellow, peach, lavender, mint, skyBlue, coral
- **리더 비주얼 스타일** (밝기/대비/폰트)
- **번역 소스**: 자동감지/언어 선택
- **번역 대상 언어**

### 10.4 고급 설정
- **컨텍스트 서버 설정**:
  - 서버 URL 입력
  - Bearer 토큰 입력
  - 연결 테스트 버튼
  - 사용법 도움말
- **한국어 사전 API 키 입력**
- **API 검증 테스트 버튼**
- **번역 엔진 선택** (DeepL/Context Server)

### 10.5 정보
- 앱 버전 표시
- 이용약관 링크
- 개인정보처리방침 링크

---

## 11. 테마 시스템

### 11.1 테마 목록 & 색상

| 테마 | Accent RGB | 유형 | 비고 |
|---|---|---|---|
| Studio | (31, 169, 100) 녹색 | 무료 | 기본값 |
| Ocean | (115, 188, 231) 파랑 | 무료 | |
| Paper | (180, 108, 72) 갈색 | 프리미엄 | 따뜻한 톤 |
| Dusk | (140, 100, 255) 보라 | 프리미엄 | 은퇴(fallback→Studio) |
| Mint | (61, 107, 86) 민트 | 프리미엄 | 시원한 녹색 |

### 11.2 테마 속성
- `glassTint`: 반투명 오버레이 색상
- `cardSurface`: 카드 배경 (라이트/다크 대응)
- `cardStroke`: 1px 테두리 색상
- `mutedText`: 보조 텍스트 색상
- `titleColor`: 주요 제목 텍스트
- `subtitleColor`: 보조 제목 텍스트
- `background`: AdaptiveThemeBackground (리니어 그라데이션)

### 11.3 캘린더 팔레트
- text, muted, offMonth (색상)
- accent, highlight, highlightStroke (브랜드 색상)
- started, finished (활동 인디케이터)
- goalBadge 스타일들 (fill, symbol, page, stroke, shadow)
- todayRing, danger, dangerText (특수 인디케이터)

### 11.4 적응형 배경
- 테마별 LinearGradient
- 라이트 모드: 파스텔 그라데이션
- 다크 모드: 깊고 대비 높은 그라데이션

---

## 12. 구독 & 결제 (SubscriptionManager + PaywallView)

### 12.1 상품
- com.realtap.readtap.premium.monthly (월간)
- com.realtap.readtap.premium.yearly (연간)

### 12.2 트라이얼 시스템
- 7일 무료 트라이얼
- 로컬 UserDefaults + 서버 RPC 검증
- 기기 ID 기반 악용 방지 (기기당 1회, Keychain 저장)
- 로그인 시 서버 프로필에서 동기화

### 12.3 프리미엄 상태 로직
- `isEffectivelyPremium`: 관리자 오버라이드 먼저 확인 → StoreKit
- `isPremium`: StoreKit 엔타이틀먼트 (트라이얼 OR 활성 구독)
- `premiumOverride`: 관리자 강제 프리미엄/차단
- `isBanned`: 계정 정지 플래그
- `banReason`: 정지 사유

### 12.4 트라이얼 상태
- `.notStarted`: 트라이얼 미시작
- `.active(daysRemaining)`: 진행 중, X일 남음
- `.expired`: 7일 경과

### 12.5 StoreKit2 연동
- 상품 로딩, 구매 플로우, 검증
- 트랜잭션 업데이트 (갱신, 환불, 취소)
- 구매 복원

### 12.6 페이월 화면
1. **헤더**: "ReadTap Premium" + 트라이얼 상태
2. **기능 카드** (3가지 혜택):
   - Sparkles: 더 정확한 번역 (문맥 인식 AI)
   - List: 품사별 의미 분류
   - Palette: 프리미엄 테마 (Paper/Dusk/Mint)
3. **상품 섹션**:
   - 월간/연간 상품 카드 (라디오 선택)
   - 가격 표시 (StoreKit 포맷)
   - 연간: 월 환산가 + 할인율 배지
4. **액션 버튼**:
   - 무료 트라이얼 시작 (미시작 시)
   - 구독하기 (로딩 상태)
   - 구매 복원
5. **약관 푸터**: 자동 갱신 고지 + 링크

### 12.7 프리미엄 프로모 시트 (인-리더)
- **트리거**: 10회 이상 단어 조회 후 (세션당 1회, 비프리미엄만)
- **내용**: "Read Deeper" 헤더, 조회 수 표시, 3가지 기능 행
- **액션**: "Start 7-Day Free Trial" / "Subscribe to Premium" / "Maybe Later"

---

## 13. 데이터 & 영속성

### 13.1 어휘 데이터 모델 (VocabularyEntry)
| 필드 | 타입 | 설명 |
|---|---|---|
| id | Int | SQLite row ID |
| uuid | String | 고유 식별자 (동기화용) |
| word | String | 저장 단어 |
| meaning | String | 단어 정의 |
| sentence | String? | 문맥 문장 |
| language | String? | 소스 언어 코드 |
| bookId | String? | 연결된 책 ID |
| pageIndex | Int? | 저장된 페이지 |
| masteryState | Enum | none/unknown/unsure/known |
| createdAt | Date | 저장 시점 |
| updatedAt | Date | 수정 시점 |
| deletedAt | Date? | 소프트 삭제 시점 |
| ownerUID | String? | Supabase 사용자 ID |
| lookupCount | Int | 조회 횟수 |
| highlightRect | CGRect? | PDF 하이라이트 위치 |
| targetLanguage | String? | 번역 대상 언어 |
| posJson | String? | 품사 JSON (프리미엄) |
| highlightColorHex | String? | 커스텀 하이라이트 색상 |

### 13.2 마스터리 상태
- `.none` (0): 상태 없음
- `.unknown` (1): 모르는 단어
- `.unsure` (2): 어느 정도 앎
- `.known` (3): 아는 단어/마스터

### 13.3 책 데이터 (BookRecord)
- id, title, filePath, fileType, createdAt, updatedAt, deletedAt, ownerUID, orderKey

### 13.4 폴더 데이터 (BookFolder)
- id, name, createdAt, updatedAt, deletedAt, ownerUID, orderKey

### 13.5 스트릭 데이터
- date (TEXT PK), didRead (INT), didSaveWord (INT), readSeconds (INT)
- **독서 스트릭**: didRead == true OR readSeconds >= 600 연속일
- **어휘 스트릭**: didSaveWord == true 연속일
- 최대 365일 백필

### 13.6 독서 상태 추적
- 시작 시점, 완료 시점, 완료 토글, 다시 읽기
- 일별 활동: 저장 단어 수, 독서 분
- 일일 목표: 30단어 또는 10분 독서
- 연속 일수 계산

### 13.7 소프트 삭제 & 복구
- deletedAt 타임스탬프 설정 (DB 유지)
- 파일 존재 시 고아 책 자동 복구
- 삭제 후 독서 메트릭 재조정

### 13.8 경로 관리
- 상대 경로 변환 (Documents 기준)
- Unicode NFC 정규화 (한국어 파일명/APFS 호환)
- 앱 재설치 시 컨테이너 경로 변경 처리
- UUID 기반 ID 마이그레이션

---

## 14. 알림 시스템

### 14.1 앱 내부 알림 (NotificationCenter)
- `readingStatusDidChange`: 독서 진행 변경
- `readingProgressDidChange`: 독서 시간/스트릭 업데이트
- `vocabularyDidChange`: 단어 추가/삭제/수정
- `openWordsTabForReaderBook`: 리더 → 단어장 탭 이동
- `openWordsTabFromHome`: 홈 → 단어장 탭 이동
- `bookOpenStatusDidChange`: 책 열기/닫기 상태
- `highlightColorDidChange`: 하이라이트 색상 변경

### 14.2 로컬 푸시 알림
- 복습 리마인더 (최소 20개 저장 단어 이상 시 조건부 트리거)

---

## 15. 공통 UI 컴포넌트

### 15.1 테마 확인 다이얼로그 (ThemedConfirmationDialog)
- 제목 (bold, 최대 3줄) + 메시지 (옵션)
- 취소 + 확인 2버튼
- 톤: destructive (빨강) / accent (녹색) / ink (검정)
- 반투명 어두운 오버레이
- 스케일 + 투명도 전환 애니메이션
- 최소 310pt 너비

### 15.2 테마 이름 변경 다이얼로그 (ThemedRenameDialog)
- "Rename" 제목
- 자동 포커스 텍스트 입력
- 취소 + 저장 버튼
- 입력 유효성 검사 (비어있지 않은, 트림)
- 포커스 시 테두리 하이라이트
- Return 키로 제출

### 15.3 "오늘 다시 묻지 않기" 옵션
- 확인 다이얼로그에 체크박스 옵션
- 날짜 기반 리셋

---

## 16. 인증 & 세션 관리

### 16.1 인증 방법
- Apple Sign-in (ASAuthorizationAppleIDRequest, SHA256 nonce)
- Google Sign-in (GoogleSignIn SDK)
- Email/Password (Supabase auth)

### 16.2 세션 관리
- 자동 토큰 갱신
- 프로필 fetch 검증
- 오래된 세션 감지 (PGRST116 에러)
- 재설치 감지: 오래된 Keychain 클리어
- 프로필 새로고침 5분 쓰로틀 (포그라운드 이벤트)

### 16.3 프로필 동기화
- UserProfile (user_profile_view RPC)
- 트라이얼 시작일 + 기간
- 프리미엄 오버라이드 (관리자 강제)
- 차단 상태 + 사유

### 16.4 기기 식별
- UIDevice.identifierForVendor 기반
- IDFV 없으면 UUID 폴백
- Keychain 저장 (앱 삭제 후에도 유지)

---

## 17. 리더 비주얼 스타일

### 17.1 모드
- **Classic**: 전통 글래스모피즘
- **Refined**: 모던, 고대비 디자인

### 17.2 Refined 팔레트
- Ink: 어두운 텍스트 (Ocean: #1F3145, Default: #1F2733)
- Accent: 주요 색상 (Ocean: #66D6DE, Default: #1FD960)
- Highlight: 저장 단어 색상
- Surfaces: 페이지, 캔버스, 패널 배경

---

## 18. 전체 사용자 워크플로우 요약

### 워크플로우 1: 일상 독서
1. 라이브러리에서 PDF/이미지 열기
2. 롱프레스로 단어 조회 → 팝업 표시
3. 뜻 확인, 필요 시 선택 범위 조정
4. "Save" 탭 → DB에 단어 저장 (자동저장 활성 시 자동)
5. 하이라이트 자동 표시

### 워크플로우 2: 어휘 복습
1. 단어장 탭 → 날짜별 or 책별 보기
2. 스트립 모드: 캘린더 스크롤, 날짜 탭하여 단어 확인
3. 플래시카드 모드: 카드 플립, 스와이프로 평가
4. 일괄 작업: 다중 선택 → 삭제/마스터리 토글

### 워크플로우 3: 설정 커스터마이징
1. 앱 언어 (영어/한국어)
2. 테마 선택 (무료 2개, 프리미엄 4개)
3. 자동저장 토글
4. 팝업 크기 (Compact/Normal/Large)
5. 번역 엔진 설정
6. 하이라이트 색상 커스터마이징

### 워크플로우 4: 프리미엄
1. 트라이얼: 7일 무료 (기기 잠금)
2. 구독: 월간/연간
3. 기능: 품사별 의미, 프리미엄 테마, 정확한 번역
4. 복원: 기기 교체/재설치 대응

---

## 19. 텍스트 선택 필터링 규칙

- 최대 단어 수: 8
- 최대 문자 수: 160
- 최소 길이: 1
- 거부: 숫자만, 기호만
- 허용: CJK/한글 + 숫자
- 합쳐진 영어 단어 분리 (UITextChecker 맞춤법 기반)
- 3분할 → 2분할 시도
- 하위 단어 최소 4자

---

> **이 문서의 모든 기능은 현재 앱에 구현되어 있습니다. UI/UX 리디자인 시 이 기능들을 100% 유지하면서 디자인만 변경해야 합니다.**
