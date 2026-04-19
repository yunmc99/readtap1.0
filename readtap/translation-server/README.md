# ReadTap Translation Worker (Cloudflare Workers)

초기/베타/저비용 운영을 위한 **Cloudflare Workers 단독 구성** 템플릿입니다.
`ContextMeaningService`와 한국어 사전 프록시가 호출하는 `/health`, `/translate`, `/meaning`, `/krdict` 경로를 지원합니다.

> 중요: 이 Worker는 **번역 전용 경계**입니다.
> 동기화/구독/인증 API는 별도 `app server`(Spring Boot)로 분리하는 것을 권장합니다.
> `backend/PLAN_BACKEND_MVP.md`와 `backend/api-v1.yaml`이 해당 서버의 기준 API입니다.

## 1) 지원 경로

- `GET /health` : 서버 상태 조회
- `POST /translate` : 텍스트 번역
- `POST /meaning` : `word + sentence` 기반 후보 번역 반환(선택/후보/문장 번역 포함)
- `POST /krdict` : 한국어→한국어 뜻풀이 프록시

요청 포맷 예시:

```json
{
  "text": "Hello world",
  "source": "en",
  "target": "ko",
  "context": "문맥 문자열 (선택)"
}
```

의미 조회 예시:
```json
{
  "word": "Apple",
  "sentence": "The Apple is red.",
  "source": "en",
  "target": "ko",
  "candidates": ["Apple", "apple", "앵플"],
  "maxCandidates": 3
}
```

응답 예시:
```json
{
  "ok": true,
  "selected": { "word": "Apple", "meaningKo": "사과", "synonymsEn": ["orchard apple"] },
  "candidates": [
    { "word": "Apple", "meaningKo": "사과", "synonymsEn": ["orchard apple"] },
    { "word": "apple", "meaningKo": "애플", "synonymsEn": [] }
  ],
  "sentenceTranslationKo": "사과가 빨갛다."
}
```

## 2) 폴더 구조

```text
translation-server/
├─ index.js              # Cloudflare Workers 핸들러
├─ wrangler.toml         # Workers 배포 설정
├─ package.json          # wrangler 스크립트
├─ .env.example          # 로컬 개발 env 예시 (민감값은 .dev.vars/Secret로)
├─ .gitignore
```

## 3) 환경 변수

`.env.example` 기준으로 설정:

- `CONTEXT_SERVER_TOKEN`: 앱에서 보낸 Bearer 토큰 값
- `REQUEST_SIGNING_SECRET`: 요청 서명 키(선택)
- `REQUIRE_SIGNING`: `true/false`
- `TRANSLATION_PROVIDER`: `deepl`, `google`, `mock` 또는 `auto` (기본 `mock`)
- `DEEPL_API_KEY`: DeepL API 키
- `DEEPL_USE_PRO`: `1`이면 paid endpoint 사용
- `GOOGLE_TRANSLATE_API_KEY`: Google Translate API 키
- `KRDICT_API_KEY`: 국립국어원 한국어기초사전 API 키
- `CACHE_TTL_SECONDS`: 번역 캐시 TTL(초)
- `REQUEST_TIMEOUT_MS`: DeepL 요청 타임아웃(ms)
- `ALLOWED_ORIGINS`: CORS 허용 origin 목록(쉼표 구분). 비워두면 운영/스테이징 모두 브라우저에서 차단될 수 있음
- `MAX_REQUEST_BYTES`: 요청 body 최대 바이트 수(기본 12000)
- `RATE_LIMIT_ENABLED`: `true/false` (기본 `true`)
- `RATE_LIMIT_WINDOW_SECONDS`: rate-limit 윈도우(초)
- `RATE_LIMIT_MAX_REQUESTS`: 윈도우당 허용 최대 요청 수

### 보안 변수 권장 저장 위치
- 민감 값(`CONTEXT_SERVER_TOKEN`, `REQUEST_SIGNING_SECRET`, `DEEPL_API_KEY`, `GOOGLE_TRANSLATE_API_KEY`, `KRDICT_API_KEY`)은
  `wrangler secret put`로 등록하는 것을 권장합니다.

## 4) 로컬 실행

```bash
cd translation-server
npm install
cp .env.example .dev.vars
npm run dev
```

로컬 기본 URL: `http://127.0.0.1:8787`

헬스체크:

```bash
curl http://127.0.0.1:8787/health
```

## 5) Cloudflare KV 연결 (번역 캐시)

```bash
wrangler kv:namespace create "TRANSLATION_CACHE"
wrangler kv:namespace create "TRANSLATION_CACHE" --preview
```

발급된 `id`와 `preview_id`를 `wrangler.toml`의 `[[kv_namespaces]]`에 채웁니다.

## 6) 배포

```bash
cd translation-server
wrangler deploy
```

배포 후 `https://<workers-host>/health` 응답을 확인하세요.
운영/스테이징 배포 전에 `ALLOWED_ORIGINS`를 앱에서 실제 호출할 도메인으로 제한하고, `CONTEXT_SERVER_TOKEN`을 워커 secret로 등록했는지 확인하세요.

### 운영/스테이징 분리 배포 예시

운영/스테이징 분리를 위해 같은 프로젝트에 환경을 두는 방식으로 운영 중입니다.

```bash
cd translation-server

# 기본(운영) 배포
wrangler deploy

# 스테이징 배포
wrangler deploy --env staging
```

각 환경별 Secret 값은 별도로 등록해야 합니다.

```bash
wrangler secret put CONTEXT_SERVER_TOKEN
wrangler secret put REQUEST_SIGNING_SECRET
# 스테이징은 --env staging 추가
wrangler secret put CONTEXT_SERVER_TOKEN --env staging
wrangler secret put REQUEST_SIGNING_SECRET --env staging
# CORS 허용 Origin도 환경별로 분리해서 저장하세요(권장)
wrangler secret put ALLOWED_ORIGINS
wrangler secret put ALLOWED_ORIGINS --env staging
```

운영은 `https://readtap-translation-worker.workers.dev`  
스테이징은 `https://readtap-translation-worker-staging.workers.dev` 형태로 사용하고,  
앱은 빌드/실행 환경에 따라 해당 Base URL을 선택합니다.

> 참고: iOS/네이티브 앱은 보통 `Origin` 헤더를 보내지 않으므로 CORS 설정이 동작하지 않습니다.
> `ALLOWED_ORIGINS`는 웹뷰/웹 클라이언트가 직접 호출할 때만 필수입니다.

## 7) 앱 연결

앱에서 설정하는 컨텍스트 서버 URL은 Worker의 `BASE URL`로 맞춥니다.
예: `https://readtap-translation-worker.your-subdomain.workers.dev`

요청 헤더:
- `Authorization: Bearer <CONTEXT_SERVER_TOKEN>`
- `X-ReadTap-Client-Id` (서버 allowlist를 쓸 경우)
- `X-Request-Id`
- `X-Request-Timestamp`
- `X-ReadTap-Signature` (운영/스테이징 필수)

### 앱에서 꼭 설정할 항목 (iOS)

1) Settings > 번역 엔진(Engine) > **문맥 서버(server)**
2) Settings > 문맥 서버(Context Server)
   - `서버 URL`: `https://readtap-translation-worker.ymcyun99.workers.dev`
   - `서버 토큰`: `wrangler secret으로 등록한 CONTEXT_SERVER_TOKEN`와 동일한 값
   - `Request Signing Secret`: `REQUIRE_SIGNING=true`인 경우 필수
3) 저장 후 `연결 테스트` 실행하여 `연결 성공` 확인
4) 번역 실행 화면에서 실제 번역 요청이 잘 되면 완료

> 운영에서 서명 검증을 켜두려면:
> 1) `wrangler.toml`에서 `REQUIRE_SIGNING = "true"` 설정
> 2) 앱에서 `Request Signing Secret` 입력 후 테스트 통과

## 8) 마이그레이션 포인트 (기존 Railway/Firebase 템플릿에서)

- `railway.json`, Firebase 관련 설정 제거
- `/translate` 및 `/meaning` 핸들러를 Worker fetch 기반으로 교체
- 캐시는 Memory + KV 하이브리드: KV 바인딩 유무와 상관없이 동작
- `process.env` 대신 Workers env/binding 기반 사용
- CORS, 서명 검증, TTL 캐시, mock provider 흐름은 유지

## 9) 배포 후 quick check

- 헬스 체크:
```bash
curl "https://readtap-translation-worker.ymcyun99.workers.dev/health"
```

또는 스크립트로 한 번에 확인:

```bash
cd /Users/yunminchae/Desktop/read_tap/readtap/translation-server
./check-translation-server.sh
```

운영 기준으로 `/health`는 최소 readiness 신호만 공개합니다.
구성 진단(`diagnostics=1`)은 토큰 + 서명 검증이 통과한 요청에서만 확인해야 합니다.

예시:
```json
{
  "ok": true,
  "status": "ready"
}
```

- 번역 테스트:
```bash
curl -X POST https://readtap-translation-worker.ymcyun99.workers.dev/translate \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <CONTEXT_SERVER_TOKEN>" \
  -d '{"text":"Hello, this is a test.","source":"en","target":"ko","context":"Sample context","task":"translate"}'
```

Google Translate 사용 예시:
```bash
curl -X POST https://readtap-translation-worker.ymcyun99.workers.dev/translate \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <CONTEXT_SERVER_TOKEN>" \
  -d '{"provider":"google","text":"Hello","source":"en","target":"ko","context":"Sample context"}'
```

```bash
curl -X POST https://readtap-translation-worker.ymcyun99.workers.dev/meaning \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <CONTEXT_SERVER_TOKEN>" \
  -d '{"provider":"google","word":"Set","sentence":"Set the table.","source":"en","target":"ko","candidates":["set","Set","세트"],"maxCandidates":3}'
```

요청 서명이 켜져 있는 경우(REQUIRE_SIGNING=true):
```bash
export CONTEXT_TOKEN="<CONTEXT_SERVER_TOKEN>"
export SIGN_KEY="<REQUEST_SIGNING_SECRET>"
export REQUEST_BODY='{"text":"Hello, this is a test.","source":"en","target":"ko","context":"Sample context","task":"translate"}'
export REQUEST_ID="$(uuidgen)"
export REQUEST_TS="$(date +%s)"
export BODY_B64="$(printf '%s' "$REQUEST_BODY" | base64)"

export SIGNATURE="$(node - <<'NODE'
const crypto = require('node:crypto');
const method = 'POST';
const path = '/translate';
const reqId = process.env.REQUEST_ID;
const ts = process.env.REQUEST_TS;
const body = process.env.BODY_B64;
const secret = process.env.SIGN_KEY;
const msg = [method, path, ts, reqId, body].join('\n');
const sig = crypto.createHmac('sha256', Buffer.from(secret, 'utf8')).update(msg).digest('base64');
process.stdout.write(sig);
NODE")"

curl -X POST https://readtap-translation-worker.ymcyun99.workers.dev/translate \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${CONTEXT_TOKEN}" \
  -H "X-Request-Id: ${REQUEST_ID}" \
  -H "X-Request-Timestamp: ${REQUEST_TS}" \
  -H "X-ReadTap-Signature: HMAC-SHA256 ${SIGNATURE}" \
  -d "$REQUEST_BODY"
```

성공 시 응답:
```json
{"ok":true,"translatedText":"...","source":"en","target":"ko","cached":false}
```

## 10) 베타 운영 전환 체크리스트

### 즉시(당일)

- `wrangler.toml`:
  - `REQUIRE_SIGNING = "true"` 적용
  - KV namespace 바인딩 존재
- Cloudflare 시크릿 등록 확인:
  - `CONTEXT_SERVER_TOKEN`
  - `REQUEST_SIGNING_SECRET`
  - `DEEPL_API_KEY`
- 앱 설정 확인:
  - 번역 엔진을 `문맥 서버(server)`로 지정
  - `문맥 서버 URL` 등록
  - `서버 토큰` 및 `Request Signing Secret` 저장
- 연결 테스트 1회 통과
- 번역 3건 이상 성공:
  - 짧은 문장 1개
  - 긴 문장 1개
  - 한국어/영어 혼합문 1개

### 운영 안정성(3일차)

- 에러 케이스 분기 확인:
  - 토큰 미입력/오류: 연결 실패 메시지
  - 서명 미일치: 401 처리
  - 네트워크 오류: 재시도/알림 UX
- DeepL 지연 또는 실패 대비 fallback 경로 동작 확인
- 서버 응답 로그에서 인증/서명 로그 마스킹 여부 확인

### 공개 베타 전(7일차)

- 401/5xx 비율 임계치 기준 점검
- 캐시 hit/miss 추이 점검
- 키 회전(토큰/서명) 연습 및 반영 가이드 수립
- 앱 업데이트 시 토큰 재입력 가이드 노출
