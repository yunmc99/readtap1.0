ReadTap 작업 기록 (2026-02-14 ~ 2026-02-15)
================================================

## 2026-03-12 App Store 출시 전 점검 계획
- [x] 프로젝트 설정/Info.plist/배포 체크리스트 대조
- [x] Release 빌드 검증
  - `xcodebuild -project readtap/readtap.xcodeproj -scheme readtap -configuration Release -destination generic/platform=iOS -derivedDataPath /tmp/readtap-derived CODE_SIGNING_ALLOWED=NO build`
  - 결과: `** BUILD SUCCEEDED **`
- [x] Apple 공식 심사 기준(App Review Guidelines/App Privacy/App Icon) 대조
- [x] 출시 블로커/보완 필요 항목 정리
- [x] `readtap/readtap/PrivacyInfo.xcprivacy` 추가
  - `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`
  - `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1`
- [x] `readtap/readtap/SettingsView.swift` 로컬 저장/온라인 조회 안내 문구 정정
- [x] `readtap/readtap/Info.plist` 불필요 권한 문자열 제거
  - 제거: `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`
- [x] Release 빌드 재검증
  - 결과: `** BUILD SUCCEEDED **`
- [x] 앱 아이콘 에셋 이슈는 사용자 요청으로 이번 작업 범위에서 제외

## 2026-03-12 보안 점검 계획
- [x] 코드베이스 언어/프레임워크 및 보안 민감 지점 식별
- [x] Worker/iOS 앱의 인증·비밀값 저장·네트워크 경로 점검
- [x] 보안 리뷰 보고서 작성
  - 산출물: `readtap/security_best_practices_report.md`
- [x] 주요 리스크 정리
  - `PUBLIC_CLIENT_IDS` 기반 Worker 인증 우회
  - `/health?diagnostics=1` 구성/키 힌트 노출
  - KRDict 평문 HTTP 호출
  - iOS 릴리즈 로그의 응답 본문 출력
- [x] Worker 인증 경로 장기 보강
  - `X-ReadTap-Client-Id`를 인증이 아닌 allowlist 메타데이터로만 사용
  - `/translate`, `/meaning`, `/krdict`, `diagnostics=1` 요청에 Bearer token 검증 강제
  - `REQUIRE_SIGNING=true` 환경에서는 서명 검증도 필수화
  - 인증 비밀값 누락 시 `503 server_auth_not_configured`로 fail-closed
- [x] iOS 원격 문맥 서버 secure-by-default 적용
  - 원격/운영 서버는 Bearer token + Request Signing Secret 없으면 저장/사용 차단
  - `DEBUG` + localhost만 무서명 개발 예외 허용
- [x] Worker 설정/문서 동기화
  - `PUBLIC_CLIENT_IDS` -> `ALLOWED_CLIENT_IDS`
  - `translation-server/README.md`, `check-translation-server.sh`, `Secrets.xcconfig.example` 갱신
- [x] Worker 구문 검증
  - `node --check readtap/translation-server/index.js`
- [x] 잔여 보안 이슈 후속 조치
  - Worker KRDict 경로를 HTTPS 전용으로 전환
  - `KoreanDictionaryService`가 서버 프록시를 우선 사용하고 로컬 API 키는 fallback으로만 사용
  - `ContextMeaningService` 릴리즈 로그를 debug 전용으로 제한하고 secret preview 제거
  - `context-server`를 localhost 개발 외에는 fail-closed로 변경
  - `context-server` 기본 bind host를 loopback으로 제한하고 HTTP timeout 추가
- [x] 추가 구문 검증
  - `node --check context-server/server.js`
- [x] Release 빌드 재검증
  - `xcodebuild -project readtap/readtap.xcodeproj -scheme readtap -configuration Release -destination generic/platform=iOS -derivedDataPath /tmp/readtap-derived CODE_SIGNING_ALLOWED=NO build`
  - 결과: `** BUILD SUCCEEDED **`
- [x] 번역 API 인증 누락 원인 확인 및 연결 수정
  - 원인: Worker secret은 정상인데 앱 `Info.plist`에 `ContextServerToken` / `ContextServerSigningSecret`가 없어 `/translate` 요청이 인증 헤더 없이 나가고 있었음
  - 수정: `readtap/Info.plist`에 `ContextServerToken`, `ContextServerSigningSecret` 키 추가
  - 수정: `readtap.xcodeproj/project.pbxproj`에서 Debug/Release가 `Secrets.xcconfig`의 staging/prod token + signing secret을 실제 build setting으로 참조하도록 연결
  - 검증: 로컬 secret으로 prod/staging Worker `/translate` 직접 호출 시 둘 다 `200 translated`
  - 검증: 빌드된 앱 번들 `Info.plist`에서 `ContextServerBaseURL`, `ContextServerToken`, `ContextServerSigningSecret`, `ContextServerClientId` 모두 `set` 확인

## 2026-03-12 Reader 의미 placeholder 자동 fallback 계획
- [x] 원인 확인
  - 첫 조회는 placeholder로 종료되는데 `다른 뜻 찾기` 경로의 후보 보정은 자동 실행되지 않았음
  - 재탭 시에는 후보 캐시/후속 조회 결과가 붙어 뜻이 보이는 경우가 있었음
- [x] 수정: 첫 조회에서 same-word 후보가 있으면 즉시 primary meaning으로 승격
- [x] 수정: placeholder가 남으면 `다른 뜻 찾기` 후보 패널을 자동으로 열고 후보 조회를 즉시 시작
- [x] 수정: 자동 후보 조회 중 same-word 후보가 나오면 popup을 실제 뜻으로 자동 복구
- [x] Release 빌드 재검증
  - `xcodebuild -project /Users/yunminchae/Desktop/read_tap/readtap/readtap.xcodeproj -scheme readtap -configuration Release -destination generic/platform=iOS -derivedDataPath /tmp/readtap-derived CODE_SIGNING_ALLOWED=NO build`
  - 결과: `** BUILD SUCCEEDED **`

## 2026-03-12 Word popup 언어 일관성 정리
- [x] 원인 확인
  - `WordPopupView`와 `ReaderViewModel+Lookup`에 하드코딩된 한국어 문구가 남아 있어 앱 언어가 영어일 때 팝업에서 한/영 혼합 노출이 발생했음
- [x] 수정: 팝업 버튼/상태 문구용 `AppText` 키 추가
- [x] 수정: `WordPopupView`의 저장 취소, 다른 뜻 찾기, 더 보기, 로딩/placeholder 문구를 앱 언어 기반으로 전환
- [x] 수정: `ReaderViewModel+Lookup`의 후보 로딩/실패/저장 불가 notice를 앱 언어 기반으로 전환
- [x] 수정: Apple HIG Writing 기준으로 팝업 액션/상태 문구를 더 짧고 자연스러운 표현으로 재정리
  - 예: `Find other meanings` -> `See Other Meanings`, `Undo Save` -> `Unsave`, `단어 선택 조정` -> `범위 조정`
- [x] Release 빌드 재검증
  - `xcodebuild -project /Users/yunminchae/Desktop/read_tap/readtap/readtap.xcodeproj -scheme readtap -configuration Release -destination generic/platform=iOS -derivedDataPath /tmp/readtap-derived CODE_SIGNING_ALLOWED=NO build`
  - 결과: `** BUILD SUCCEEDED **`

## 2026-03-12 Word popup 문맥 풀이 실험
- [x] 수정: 문맥 서버의 `sentenceTranslationKo`를 메인 뜻과 분리해 팝업 하단 보조 설명으로 표시
- [x] 수정: `sentenceTranslationKo`는 기본적으로 보조 설명으로만 쓰고, 단어 뜻 후보가 없을 때만 메인 fallback으로 사용
- [x] 수정: Reader/Image long press 경로 모두 문맥 풀이를 팝업 상태로 전달
- [x] Release 빌드 재검증
  - `xcodebuild -project /Users/yunminchae/Desktop/read_tap/readtap/readtap.xcodeproj -scheme readtap -configuration Release -destination generic/platform=iOS -derivedDataPath /tmp/readtap-derived CODE_SIGNING_ALLOWED=NO build`
  - 결과: `** BUILD SUCCEEDED **`

## 2026-03-12 Word popup 문맥 풀이 실험 원복
- [x] 원복: 팝업 하단의 문맥 풀이 보조 설명 UI 제거
- [x] 원복: `sentenceTranslationKo`를 별도 popup display 레이어로 전달하던 Reader/Image 경로 제거
- [x] 원복: lookup 결과 모델을 실험 전 구조로 복원하고 `sentenceTranslationKo`는 다시 일반 후보 의미로만 반영
- [x] Release 빌드 재검증
  - `xcodebuild -project /Users/yunminchae/Desktop/read_tap/readtap/readtap.xcodeproj -scheme readtap -configuration Release -destination generic/platform=iOS -derivedDataPath /tmp/readtap-derived CODE_SIGNING_ALLOWED=NO build`
  - 결과: `** BUILD SUCCEEDED **`

## 2026-03-12 Reader 읽기 시간 tracking 엄격화
- [x] 원인 확인
  - 기존에는 마지막 인터랙션 후 90초 동안 읽기 시간이 계속 누적됐고, `팝업 닫기`, `크롬 토글`, `페이지 인덱스 변경` 같은 넓은 이벤트도 읽기 인터랙션으로 처리됐음
- [x] 수정: `ReaderUsageTracker` active interaction window를 45초로 축소
- [x] 수정: PDF 리더는 `단어 조회 long press`, `실제 페이지 전환`, `스크롤/팬`, `pinch`, `사용자 조작 페이지 이동`만 읽기 인터랙션으로 인정
- [x] 수정: `popup dismiss`, `two-finger dismiss`, `single-tap chrome toggle`, 초기/프로그램적 페이지 바인딩은 읽기 인터랙션에서 제외
- [x] 수정: Image 리더는 `단어 선택`, `long press fallback`, `zoom`, `pan`만 읽기 인터랙션으로 인정
- [x] Release 빌드 재검증
  - `xcodebuild -project /Users/yunminchae/Desktop/read_tap/readtap/readtap.xcodeproj -scheme readtap -configuration Release -destination generic/platform=iOS -derivedDataPath /tmp/readtap-derived CODE_SIGNING_ALLOWED=NO -quiet build`
  - 결과: `BUILD SUCCEEDED (Info.plist Copy Bundle Resources warning only)`

## 2026-03-05 en→en 사전 조회 복구 계획
- [x] 원인 확인: `AppleTranslation` en→en 경로가 `unsupportedLanguagePair`로 실패해 의미 후보가 비어있음
- [x] 수정: `WordLookupService.lookupEnglishDefinition`에 키 없는 영영 사전(`dictionaryapi.dev`) 폴백 추가
- [x] 동작: en→en에서 `Local → Wordnik(키 있으면) → Free Dictionary` 순으로 후보 정의 반환
- [x] 검증: 타입체크/빌드 확인

## 2026-03-05 en→en 활용형/시제 인식 강화 계획
- [x] 원인 확인: `extractBaseWord` 단일 규칙 기반이라 `emphasizing -> emphasiz` 같은 miss 발생
- [x] 수정: en lookup을 단일 단어가 아니라 `원문/lemma/활용형 변환/불규칙형` 후보 체인으로 조회
- [x] 동작: 후보마다 `Local → Wordnik → Free Dictionary` 순차 조회 후 첫 성공 후보 반환
- [x] 검증: 타입체크/빌드 확인

## 2026-03-05 en→kr 정확도 보강 계획
- [x] 원인 확인: 문맥 서버가 한글 번역 대신 영문 원형만 내려올 때 Google fallback이 실행되지 않음
- [x] 수정: `fetchDeepLMeaning`에서 의미 후처리 시 한글 포함/placeholder 여부 기반으로 유효 후보만 통과
- [x] 수정: `sentenceTranslationKo`를 보강 후보로 반영해 단어 번역 대체값 확보
- [x] 수정: 유효한 후보가 없으면 DeepL 경로를 실패로 간주해 Google fallback이 동작하도록 보장
- [x] 검증: 타입체크/로그로 `robust` 케이스의 fallback 동작 점검

## 2026-03-05 en→ko 사전형 후보 표시 계획
- [x] 수정: DeepL 요청 후보어를 단일 원형이 아닌 정규화/활용형 후보 집합으로 확장
- [x] 수정: DeepL 후보군을 `mergeMeaningCandidateStrings`로 정제해 사전형 후보 후보군 품질 정규화
- [x] 수정: en→ko에서 DeepL 후보가 부족할 때 `lookupKoreanDictionaryCandidates`로 영어 정의 기반 한글 후보를 보강
- [x] 수정: 보강 후보는 `translateDictionaryDefinitionToKorean`로 한글 변환 후 후보 유효성/중복 제거 후 노출

## 2026-03-05 삭제 버튼 가시성/일관성 개선 계획
- [x] 수정: `Words` 탭과 `Calendar` 탭(캘린더 워드 화면)의 삭제 버튼을 검정 계열 단색 스타일로 통일
- [x] 수정: 라이트/다크(흑백 톤)에서 액션바 배경/보더 대비를 높여 버튼과 텍스트 가독성 개선
- [x] 수정: 삭제 버튼 라벨 폰트를 `subheadline semibold`로 통일해 주변 컨트롤과 타이포 일관성 정리
- [x] 검증: `xcodebuild` 타입체크/빌드 `BUILD SUCCEEDED`

## 2026-03-05 언어 라벨 화살표 톤 개선 계획
- [x] 수정: 언어 설정 라벨 표기를 `->`에서 `➜` 스타일로 변경해 UI 톤 자연스럽게 정리
- [x] 수정: Reader 하단 라벨(`ContentView.languageModeLabel`)과 설정 힌트(`TranslationTarget.directionHint`) 표기를 동일 규칙으로 통일
- [x] 검증: `xcodebuild` 타입체크/빌드 `BUILD SUCCEEDED`

## 핵심 요약
- 목적: OCR/번역 성능 개선 + Swift 컴파일 에러 해결 + 통합 배포 준비.
- 현재 베이스 브랜치: `main`
- 원격 저장소: `https://github.com/yunmc99/realtap.readTap.git`

## 완료한 작업
1) 컴파일 에러 수정 (Swift 6 대응 포함)
- `readtap/ContextMeaningService.swift` 에서 `String?`/`Character` 타입 충돌 보정
- `readtap/TranslationLookupCache.swift`, `TranslationTelemetryStore.swift`, `OCRCacheStore.swift` 일부 타입/클로저 정합성 정리
- `readtap/TranslationService.swift`, `ImageReaderView.swift`, `ContentView.swift`에서 API/호출 시그니처 정합성 수정
- `readtap/Database/*`에서 옵셔널 튜플/guard/return 형태 오류 정리

2) 서버 템플릿 정리 (Cloudflare Workers 전환)
- `readtap/translation-server/*`를 Cloudflare Workers로 전면 전환
  - `index.js` (Express/Firebase 의존성 제거, Worker 바인딩 기반)
  - `package.json` (`wrangler` 기반 스크립트)
  - `wrangler.toml` (KV 바인딩/환경 변수)
  - `README.md` (배포/앱 연결 체크리스트 업데이트)
  - `.env.example`, `.gitignore`, `package-lock.json`
- 서명 보안 모드(`REQUIRE_SIGNING=true`) 기본 적용 후, 앱이 `Request Signing Secret`을 사용하도록 문서/설정 흐름 정비

3) 브랜치 정리 및 병합
- 작업 브랜치:
  - `codex/feature/translation-server-railway`
  - `codex/feature/context-server-client`
  - `codex/release/beta-v1.0` (통합 브랜치)
- `main`로 병합:
  - `Merge pull request #1 from yunmc99/codex/release/beta-v1.0` 반영
- 병합 후 정리:
  - `origin/main`으로 반영 완료
  - `origin/codex/release/beta-v1.0` 삭제
- 현재 로컬 정리 커밋: `chore: ignore Xcode shared workspace artifacts`

4) 불필요 아티팩트 관리
- `.gitignore`에 추가:
  - `readtap.xcodeproj/xcshareddata/`
  - `readtap.xcodeproj/project.xcworkspace/xcshareddata/`

## Git 이력(요약)
`main` 최신(최종 커밋 기준):
- `ff9cb0d` chore: enable request signing in workers config
- `64ba0a4` Merge PR #1 (release 통합)
- `212d88a` Initial Commit

## 현재 상태
- `translation-server/*`는 Cloudflare Workers 기준으로 수정됨
- `translation-server` 운영 값은 `REQUIRE_SIGNING=true` 반영됨
- 외부 네트워크 제한으로 `curl` 기반 서버 호출은 현재 환경에서 검증 불가
- 배포 성공 로그 기반으로 서버는 `readtap-translation-worker.ymcyun99.workers.dev` 준비 완료

## 주의
- `.env`, `.dev.vars`, `wrangler` 시크릿 값은 로컬/CI에만 보관하고 커밋하지 않습니다.

## 다음 단계 권장
1. TestFlight 배포 체크리스트 순차 실행
2. 번역 정확도 장기 개선(언어별 fallback, dedup, 캐시 히트율)
3. OCR 파이프라인 성능 계측(큐 길이, 중복 감지, 재시도 정책)
4. 번역/DB/UI 병목 계측 및 측정 기반 최적화

## 2026-02-15 서버 MVP 설계 산출 추가

### 완료 항목
- `backend/PLAN_BACKEND_MVP.md`
  - Cloudflare Worker(번역) + Spring Boot(App Server) 분리 구조 제시
  - API v1 범위, 동기화 정책, 보안/운영 체크포인트 정리
- `backend/api-v1.yaml`
  - ReadTap MVP API 계약(OpenAPI)
- `backend/schema.sql`
  - 초기 Postgres 스키마 초안(books/words/folders/learning/subscription)
- `backend/docker-compose.yml`
  - PostgreSQL + Redis + 앱 서버 실행 토폴로지 예시
- `backend/.env.example`
  - 앱 서버 실행 필수 환경변수 예시
- `translation-server/README.md`
  - Worker는 번역 경유 전용이며 앱 서버 분리가 필요함을 명시

## 2026-02-16 추가 반영 (안정성/UX 마무리)

### 완료 항목
- `readtap/ContentView.swift`
  - PDF 로딩 오버레이에 실시간 메시지 애니메이션 및 "로딩중/지연중" 톤으로 단순화
  - 장시간 PDF 로딩 시 재시도 버튼 노출 로직 정리
  - 제스처 게이트 안정성 개선:
    - 롱프레스 시작 시 `singleTap.require(toFail: lookupPress)` 제거
    - 롱프레스 제스처 시작 조건을 `gestureRecognizerShouldBegin`로 분기
- `readtap/ImageReaderView.swift`
  - 이미지 로딩 화면 텍스트를 "로딩중" 톤으로 정리하고 동적 패턴 로딩 뷰 적용 유지
- `readtap/ContentView.swift` 빌드 검증
  - `xcodebuild -project readtap.xcodeproj -scheme readtap -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/readtap-dd build`
  - `BUILD SUCCEEDED`
- `readtap/ImageReaderView.swift`
  - `phraseFromWords` 후보 정렬 블록 괄호 누락으로 인한 Swift 파싱 에러 수정
  - 동일 빌드 커맨드로 `BUILD SUCCEEDED` 재확인

## 공개 베타 체크리스트 (운영 전환)

### 1일차
- `translation-server/wrangler.toml` 운영값 점검:
  - `REQUIRE_SIGNING=true`
  - `TRANSLATION_PROVIDER=deepl`
- Cloudflare Secret 등록 확인:
  - `CONTEXT_SERVER_TOKEN`
  - `REQUEST_SIGNING_SECRET`
  - `DEEPL_API_KEY`
- 앱 `Settings > 문맥 서버`에서 URL/토큰/Signing Secret 저장
- 번역 엔진을 문맥 서버로 지정 후 연결 테스트 통과
- 번역 케이스 5개 수동 검증(짧은 문장/긴 문장/혼합문/한영섞임/재시도)

### 3일차
- 실패 분기 UX 점검:
  - 토큰 오류 시 메시지
  - 서명 오류 시 재입력 가이드
  - 오프라인/네트워크 복구 시 재시도 동작
- 서버 fallback 동작 및 장애 복구 시나리오 점검
- 요청 헤더/로그 민감정보 마스킹 점검

### 7일차
- 번역 오류율 및 지연 지표 정리
- 캐시 hit-rate/TTL 정책 점검
- 토큰/서명 키 회전 절차 테스트

## 2026-03-05 다른 뜻 보기 패널 레이아웃 긴급 수정

### 완료 항목
- [x] `readtap/WordPopupView.swift`
  - `isCandidatePanelExpanded == true` 상태에서 후보가 비어있을 때도 큰 스크롤 영역이 생기던 문제 수정
  - 후보가 없으면 안내 문구(`candidateTranslationNotice` 또는 "다른 뜻이 더 없어요.")만 짧게 표시하도록 변경
  - 후보가 1~2개면 스크롤 없이 즉시 표시, 3개 이상일 때만 스크롤 컨테이너 사용하도록 변경
  - 후보 렌더링 중복 코드를 `candidatePanelContent(candidates:)`로 정리
- [x] 타입체크/빌드 검증
  - `xcodebuild -project readtap.xcodeproj -scheme readtap -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/readtap-dd build`
  - 결과: `** BUILD SUCCEEDED **`

## 2026-03-05 후보 뜻 단일 노출 정책 적용

### 완료 항목
- [x] `readtap/WordPopupView.swift`
  - 다수 후보가 존재하더라도 후보 패널에서 표시 개수를 `uniqueCandidates.prefix(1)`로 제한

## 2026-03-06 홈 화면 Warm Editorial 시안 Figma 생성

### 완료 항목
- [x] `/Users/yunminchae/Desktop/read_tap/figma-homepage-warm-editorial.html`
  - ReadTap용 모바일 홈 화면 시안을 Warm Editorial 톤으로 별도 HTML 목업 생성
- [x] Figma MCP `newFile` 캡처 완료
  - 생성 파일 키: `pmb2pwmvFpNfN8za3Xus3R`
  - 생성 파일 URL: `https://www.figma.com/design/pmb2pwmvFpNfN8za3Xus3R`

## 2026-03-06 홈 화면 추가안 (2/3) Figma 생성

### 완료 항목
- [x] `/Users/yunminchae/Desktop/read_tap/figma-homepage-warm-editorial-option2.html`
  - Home Alternative 2(High-contrast dashboard) 화면 목업 생성
  - 피처: 좌측 홈 대시보드 + 우측 팝업 미리보기 카드
- [x] Figma MCP `newFile` 캡처 완료
  - 생성 파일 키: `PeGAVUUNncdNTwvfaiPCcl`
  - 생성 파일 URL: `https://www.figma.com/design/PeGAVUUNncdNTwvfaiPCcl`
- [x] `/Users/yunminchae/Desktop/read_tap/figma-homepage-warm-editorial-option3.html`
  - Home Alternative 3(Classic editorial-literary) 화면 목업 생성
  - 피처: 서체 중심 레이아웃 + 단어 팝업 상세 미리보기
- [x] Figma MCP `newFile` 캡처 완료
  - 생성 파일 키: `z5frGkBL2WFNGCV6KM5Ygz`
  - 생성 파일 URL: `https://www.figma.com/design/z5frGkBL2WFNGCV6KM5Ygz`

## 2026-03-06 1안 기반 탭별 시안 Figma 생성

### 완료 항목
- [x] `/Users/yunminchae/Desktop/read_tap/figma-reader-tab-warm-editorial-option1.html`
  - Reader 탭 1안 시안 생성
- [x] `/Users/yunminchae/Desktop/read_tap/figma-words-tab-warm-editorial-option1.html`
  - Words 탭 1안 시안 생성
- [x] `/Users/yunminchae/Desktop/read_tap/figma-calendar-tab-warm-editorial-option1.html`
  - Calendar 탭 1안 시안 생성
- [x] `/Users/yunminchae/Desktop/read_tap/figma-settings-tab-warm-editorial-option1.html`
  - Settings 탭 1안 시안 생성
- [x] Figma 캡처 진행
  - Reader 탭 파일 키: `uPW6yj5HWccboz1GSLwXAD`
  - Reader 페이지 노드: `https://www.figma.com/design/uPW6yj5HWccboz1GSLwXAD`
  - Words 페이지 노드: `https://www.figma.com/design/uPW6yj5HWccboz1GSLwXAD?node-id=2-2`
  - Calendar 페이지 노드: `https://www.figma.com/design/uPW6yj5HWccboz1GSLwXAD?node-id=3-2`
  - Settings 페이지 노드: `https://www.figma.com/design/uPW6yj5HWccboz1GSLwXAD?node-id=4-2`

## 2026-03-06 1안 기반 아이폰/아이패드 병행 시안 생성

### 완료 항목
- [x] 아이폰 1안 탭별 소스 정리 완료 (기존 1안 파일 유지)
- [x] 아이패드 1안 탭/홈 새 파일 생성
  - `/Users/yunminchae/Desktop/read_tap/figma-reader-tab-warm-editorial-option1-ipad.html`
  - `/Users/yunminchae/Desktop/read_tap/figma-words-tab-warm-editorial-option1-ipad.html`
  - `/Users/yunminchae/Desktop/read_tap/figma-calendar-tab-warm-editorial-option1-ipad.html`
  - `/Users/yunminchae/Desktop/read_tap/figma-settings-tab-warm-editorial-option1-ipad.html`
  - `/Users/yunminchae/Desktop/read_tap/figma-homepage-warm-editorial-option1-ipad.html`
- [x] iPad 탭별 Figma 캡처 완료
  - 파일 키: `JXM6y8hFtO8qfLCBpgwucd`
  - Reader: `https://www.figma.com/design/JXM6y8hFtO8qfLCBpgwucd`
  - Words: `https://www.figma.com/design/JXM6y8hFtO8qfLCBpgwucd?node-id=2-2`
  - Calendar: `https://www.figma.com/design/JXM6y8hFtO8qfLCBpgwucd?node-id=3-2`
  - Settings: `https://www.figma.com/design/JXM6y8hFtO8qfLCBpgwucd?node-id=4-2`
  - Home: `https://www.figma.com/design/JXM6y8hFtO8qfLCBpgwucd?node-id=5-2`
