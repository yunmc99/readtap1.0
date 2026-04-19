# ReadTap 번역 서버 운영/스테이징 분리 가이드 (노션 정리본)

## 1) 운영(Production) vs 스테이징(Staging) 한 줄 정의
- **운영(Production)**: 실제 유저에게 공개되는 정식 서비스 환경
- **스테이징(Staging)**: 출시 전/릴리즈 직전 검증용, 실제 유저 노출 전 테스트 환경

## 2) 현재 프로젝트 기준 URL
- 운영: `https://readtap-translation-worker.workers.dev`
- 스테이징: `https://readtap-translation-worker-staging.workers.dev`

> 둘 다 같은 코드 기반으로 동작하지만, 설정값(토큰/시크릿/키)을 분리해 두는 것이 핵심이다.

## 3) 왜 분리해야 하나?
- 운영 서버를 건드리지 않고도 배포 변경사항을 검증 가능
- 앱 업데이트 전에 번역/인증/성능/보안 이슈 사전 확인
- 유저 트래픽 영향을 줄이고 장애 위험 감소

## 4) 변경한 파일(이미 적용)
- `translation-server/wrangler.toml`
  - `[env.staging]` 추가
  - 운영 host는 기본 배포, 스테이징은 `--env staging`로 배포
- `translation-server/README.md`
  - 운영/스테이징 배포 명령 및 Secret 등록 예시 추가

## 5) 배포 명령
```bash
cd /Users/yunminchae/Desktop/read_tap/readtap/translation-server

# 운영 배포
wrangler deploy

# 스테이징 배포
wrangler deploy --env staging
```

## 6) 시크릿 등록
- 운영
```bash
wrangler secret put CONTEXT_SERVER_TOKEN
wrangler secret put REQUEST_SIGNING_SECRET   # signing 사용 시
```
- 스테이징
```bash
wrangler secret put CONTEXT_SERVER_TOKEN --env staging
wrangler secret put REQUEST_SIGNING_SECRET --env staging
```

> 앱 스토어 정식 빌드는 운영 값으로, 테스트/데모 빌드는 스테이징 값으로 분리한다.

## 7) 헬스체크/동작 점검
각 환경에서:
```bash
curl https://<ENV_HOST>/health
```
성공(200) 확인 후 `/translate`, `/meaning` 동작 점검.

## 8) 401(Unauthorized) 발생 원인 체크
- URL 경로가 잘못됨 (예: `/translate`나 `/meaning` 아닌 다른 경로)
- 토큰 불일치 (`CONTEXT_SERVER_TOKEN`)
- Signing 활성 시 signature 누락/오류
- 앱이 스테이징/운영 토큰과 URL을 혼용

## 9) 앱 출시 전략(요약)
정식 출시에서는 유저가 직접 서버 URL/토큰을 넣지 않도록 앱에 고정 주입해야 함.
1. Build configuration 또는 Info.plist로 base URL/Token 분기
2. `translationEngine = .server` 기본값 강제
3. 유저 설정 화면에서 번역 서버 설정 항목 숨김(필요 시 디버그만 노출)
4. 운영/스테이징 각 환경별 로그인/번역 플로우 로그 확인

## 10) 정식 출시용 바로 적용 가이드 (운영/스테이징 자동 주입)

핵심 목적: 앱은 빌드 타입별로 값이 바뀌고, 유저 입력은 받지 않는다.

### A. 어디에 값 넣는가

- iOS는 이미 `readtap/ContextMeaningService.swift`에서 `Info.plist` 값을 우선 사용하도록 구성.
- `readtap/Info.plist` 키:
  - `ContextServerBaseURL` → `$(CONTEXT_SERVER_BASE_URL)`
  - `ContextServerToken` → `$(CONTEXT_SERVER_TOKEN)`
  - `ContextServerClientId` → `$(CONTEXT_SERVER_CLIENT_ID)`
  - `ContextServerCertificatePinSHA256` → `$(CONTEXT_SERVER_CERTIFICATE_PIN)`
  - `ContextServerSigningSecret` → `$(CONTEXT_SERVER_SIGNING_SECRET)`
  - `ContextServerAllowUserOverrides` → `$(CONTEXT_SERVER_ALLOW_USER_OVERRIDES)`
- `readtap.xcodeproj/project.pbxproj`에서 Debug/Release가 이 값을 환경 변수로 매핑함
  - Debug: `*_STAGING` 시리즈 (`CONTEXT_SERVER_STAGING_BASE_URL`, `CONTEXT_SERVER_STAGING_TOKEN` 등)
  - Release: `*_PROD` 시리즈 (`CONTEXT_SERVER_PROD_BASE_URL`, `CONTEXT_SERVER_PROD_TOKEN` 등)

### B. 앱이 유저 설정을 안 받는 이유

- `ContextMeaningService.serverConfig(...)`는 `ContextServerAllowUserOverrides` 값이 `NO`면 UserDefaults/KV 저장 토큰을 무시한다.
- 현재 Release 빌드는 `CONTEXT_SERVER_ALLOW_USER_OVERRIDES = NO`로 고정되어 있고,
- Debug 빌드는 `CONTEXT_SERVER_ALLOW_USER_OVERRIDES = YES`로 고정되어 있어 내부 QA가 필요 시 수동 오버라이드를 사용할 수 있다.

### C. 데모/릴리즈 분기 동작 예시

- 데모 빌드(Debug): `*.STAGING` 값이 들어가고, 필요하면 유저 오버라이드 허용.
- 정식 빌드(Release): `*.PROD` 값이 들어가고, 유저 오버라이드 차단.

### D. 실제 빌드시 주입 예시

아래 값은 **빌드 타입별로 다르게 주입**됩니다.

- Debug(스테이징): `CONTEXT_SERVER_STAGING_*`
- Release(운영): `CONTEXT_SERVER_PROD_*`

프로젝트는 아래 변수명을 기본으로 사용합니다.

```bash
export CONTEXT_SERVER_STAGING_BASE_URL="https://readtap-translation-worker-staging.workers.dev"
export CONTEXT_SERVER_STAGING_TOKEN="TOKEN_VALUE"
export CONTEXT_SERVER_STAGING_CLIENT_ID="readtap-ios-staging"
export CONTEXT_SERVER_STAGING_CERTIFICATE_PIN=""
export CONTEXT_SERVER_STAGING_SIGNING_SECRET="(운영과 분리한 스테이징 서명키, 필요 시)"

export CONTEXT_SERVER_PROD_BASE_URL="https://readtap-translation-worker.ymcyun99.workers.dev"
export CONTEXT_SERVER_PROD_TOKEN="TOKEN_VALUE"
export CONTEXT_SERVER_PROD_CLIENT_ID="readtap-ios-prod"
export CONTEXT_SERVER_PROD_CERTIFICATE_PIN=""
export CONTEXT_SERVER_PROD_SIGNING_SECRET="운영 서명키"
```
- Debug/Release 빌드 실행 시 위 값이 자동으로 `Info.plist`에 주입됨.

#### 로컬에서 빠르게 주입하기 (권장)

현재 레포에 `scripts/context-server-env.sh`를 추가해 두었고, 빌드 전에 아래처럼 실행하면
옛 변수명(`CONTEXT_SERVER_BASE_URL_STAGING`/`CONTEXT_SERVER_TOKEN_PROD` 스타일)도 호환됩니다.

```bash
source scripts/context-server-env.sh
xcodebuild -project readtap.xcodeproj -scheme readtap -configuration Debug build
```

또는 Xcode에서 빌드 전에 같은 값을 Export해두면 됩니다.

- Debug: `CONTEXT_SERVER_STAGING_*`
- Release: `CONTEXT_SERVER_PROD_*`

### E. 출시 전 최종 점검

1. 운영 워커: `/health` 200 확인
2. 운영 토큰으로 `/meaning`/`/translate` 응답 정상
3. 앱 배포본에서 `Settings`에 번역 서버 입력 UI가 사용자 동작 없이 작동하지 않는지(또는 숨김 처리) 확인
4. 서버 401 시 토큰/URL/Signing/환경 미스매치 우선 점검
