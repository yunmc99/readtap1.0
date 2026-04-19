# 정식 배포 전 체크리스트 (Pre-release Checklist)

생성일: 2026-03-02  
기준: `/Users/yunminchae/Desktop/read_tap` 코드베이스 기준  
참조: `readtap/IMPLEMENTATION_MAP.md`

> 목적  
> - 현재 구현에서 누락되기 쉬운 항목을 누적하지 않도록 하기 위한 배포 전 점검표  
> - 기능 단위, 데이터 안전성, 보안/개인정보, 배포 산출물, 운영 리스크를 나눠 확인

## 0) 출고 모드 결정

- [ ] v1 출시 모드를 `로컬 우선(클라우드 동기화 OFF)`으로 확정
  - 현재 기본값: `readtap/readtap/AppFeatures.swift`
  - `cloudSyncEnabled = false`, `bookFileSyncEnabled = false`
- [ ] 출시 문구 및 앱스토어 설명에 해당 모드 기준(오프라인 동작 중심/클라우드 미지원)을 명시
- [ ] 클라우드 동기화를 v2로 분리할지, v1에 포함할지 결정

## 1) 빌드/런타임 기초

- [ ] Xcode signing 설정 완료
  - Team/프로비저닝/Bundle ID(`com.realtap.readtap`) 일치
- [ ] Build configuration별 Info.plist 값 검증
  - `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` 최종 버전/빌드넘버 반영
  - `GoogleService-Info.plist` 유무 및 환경별 분기 점검
- [ ] Release 빌드로 앱 실행 성공
  - 최소 1회 Cold start + 홈 화면 진입 + 탭 이동
  - 크래시/로그인 루프/권한 요청 무한루프 미발생
- [ ] 최소 OS 대응 확인
  - iOS 지원 버전에서의 실행 테스트
  - iPad/아이폰 분기 UI 동작 검증 (`UISupportedInterfaceOrientations~ipad` 포함)
- [ ] 스토어 제출용 아카이브 생성(Ad Hoc / App Store) 확인

## 2) 핵심 기능 승인(Feature acceptance)

### 2.1 라이브러리(Home)

- [ ] 책 추가 플로우
  - PDF 가져오기/사진 가져오기/문서 스캔 모두 동작
  - 파일명 충돌/중복 처리 경로(`BookStore`) 검증
- [ ] 책 목록/썸네일
  - 폴더 목록 렌더링, 정렬(`OrderKey`) 안정성
  - 썸네일 표시/재생성, 커버 캐시 적정 동작
- [ ] 책 관리
  - 삭제(책만 삭제/단어 포함 삭제) 분기 동작 정확성
  - 복제, 이동, 폴더 지정, 공유 경로 정상성
- [ ] 검색/필터/상태
  - 홈 스티키 상태(미리보기/진행률/완독/책 제목 변경) 일관성

### 2.2 리더(PDF / Image)

- [ ] PDF 리더 핵심 내비게이션
  - 페이지 이동, 썸네일/2-up(지원 시) 동작
  - 페이지 복원(`ReadingProgressStore`) 동작
- [ ] OCR/단어 조회
  - 긴 탭/선택 후 팝업 뜨기, 의미 조회, 저장 흐름
  - 수동 입력/박스 조정 완료 후 저장/취소 흐름
- [ ] 단어 저장 후 상태 반영
  - 저장 후 단어 탭/단어장 즉시 반영
  - 중복 저장, 동시 저장 레이스 컨디션 검증
- [ ] 텍스트 읽기/완독 토글
  - PDF/이미지 리더에서 동일 규칙으로 토글되는지 확인

### 2.3 단어/복습

- [ ] 목록 조회
  - 일별, 책별, 기간/폴더 필터/정렬 동작
- [ ] 단어 CRUD
  - 생성/수정/삭제/일괄 삭제/마스터리 변경 일관성
- [ ] 플래시카드
  - 카드 열람, 학습 종료, 편집 동선 점검
- [ ] 단어 저장 통계
  - `WordsTabView`, `StreakView`의 하루/월 단위 수치 정합성

### 2.4 동기화/알림(현재 v1 상태 반영)

- [ ] 클라우드 동기화 기본 상태 확인
  - 현재 `AppFeatures.cloudSyncEnabled = false` 정책이 실제 릴리즈 문서와 일치
  - `SyncEngine` 경로가 비활성 모드에서 오탐 없이 대체되는지 확인
- [ ] 알림
  - 알림 권한 요청/철회 대응
  - 현재 `NotificationManager.refreshSchedule()`에서 reminder가 비활성화된 동작(`scheduleReviewReminderIfNeeded` 미호출)인지 확인 후 출시 노트 명시

## 3) 데이터 무결성·마이그레이션

- [ ] `VocabularyStore`, `BooksStore`, `BookReadingStatusStore`, `ReadingProgressStore` 마이그레이션 경로 테스트
  - 기존 DB 파일이 없는 신규 설치/기존 DB 업그레이드 모두 확인
- [ ] 삭제/복원 로직
  - 책 삭제 시 단어/진행률/북마크/드로잉 캐시/OCR 캐시 정리 검증
- [ ] 동시 접근 안정성
  - 빠른 연속 저장/삭제/폴더 이동에서 앱 상태 불일치 없음 확인
- [ ] 캐시 정합성
  - OCR 캐시(`OCRCacheStore`), 번역 캐시(`TranslationLookupCache`) 삭제/만료/복구 동작 점검

## 4) 보안/개인정보/권한

- [ ] 개인정보/권한
  - 카메라/포토 접근성 요청 문구(`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`) 사용자 이해 가능한지 확인
- [ ] GoogleSignIn/Auth
  - `AuthManager`에서 client ID 누락/콜백 오류 시 에러 처리 사용자 메시지 노출
  - 민감 토큰 처리, 로그 출력 금지
- [ ] 로컬 데이터 보호
  - 저장 DB 경로 정책(`Documents`) 및 사용자 데이터 접근 범위 재확인

## 5) 성능/안정성

- [ ] 대형 PDF 임포트/탐색
  - 메모리 급증 없이 썸네일 생성/표시가 유지되는지 확인
- [ ] OCR 부하
  - 다중 페이지/긴 문서에서 OCR 캐시 누수, 재시도 지연, 오탐 오류 로그 검토
- [ ] 크래시 후보 지점
  - PDF 파싱 실패, 깨진 이미지, 빈 파일, 네트워크 없음, 번역 API 실패 케이스에서 UI 안정성
- [ ] 성능 지표 수집
- [ ] 앱 종료/백그라운드 진입 복귀 시 상태 복원(읽기 진행, popup 상태) 확인

## 6) 앱스토어 제출 준비

- [ ] 앱 버전/빌드버전 고정 및 릴리즈 노트 작성
- [ ] 앱 설명/키워드/스크린샷(한국어/영문) 정리
- [ ] 앱 권한/개인정보 처리 방식(App Privacy) 항목 정리
- [ ] TestFlight smoke 테스트 10명 이상 패스(권장)

## 7) 배포 블로커(즉시 해결 필요)

- [ ] `NotificationManager.refreshSchedule()`가 reminder 비활성 처리된 점이 의도적이라면 출시 문구 반영
- [ ] 클라우드 동기화를 출시에서 노출할 계획이 있을 경우:
  - Firebase Auth/Firestore/Storage 설정 가이드, 규칙, 스키마/권한, 계정 분기 및 실패 처리 UX 보강
- [ ] 번역 서비스 실패 대응 UX가 사용자에게 노출되는 메시지/재시도 루틴으로 충분히 안내되는지 검증
- [ ] 단어 저장/삭제/마스터리 변경이 다중 화면에서 동일 store로 동작하므로 회귀 방지 테스트 추가

## 8) 최종 Release Gate

- [ ] QA 리드 승인
- [ ] 제품 오너 승인(기능 범위 확정: local-first인지, cloud-sync 포함 여부 포함)
- [ ] 배포 스크립트/노트 최종 승인
- [ ] 모든 필수 항목 `[x]` 전환 후 태그 생성 (`v1.0.0` 등)

---

### 체크표기 규칙
- `[ ]` 미확인
- `[x]` 완료
- `[~]` 조건부 완료(의존 기능 없음/릴리즈 정책상 비활성)
