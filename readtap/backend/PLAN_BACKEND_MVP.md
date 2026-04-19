ReadTap Backend MVP 설계 (v1)
===============================

작성일: 2026-02-15

목표
-----
`translation-server`(Cloudflare Worker)는 번역 호출 전담으로 유지하고,
동기화/구독/사용자 데이터 서버는 Spring Boot 기반 API 서버로 분리한다.

핵심 원칙
----------
- 초기엔 최소 기능으로 출발: 인증, 동기화, 구독 상태 조회, 번역 프록시만 운영.
- 앱에서 기존 Firebase Sync는 단기적으로 유지하다가, API 서버 동기화로 단계적 전환.
- 번역 API 키는 클라이언트에서 완전히 제거.
- 중복 요청과 비용 폭증을 줄이기 위해 서버 캐시 + 레이트리밋 우선.

권장 아키텍처 (최소 구성)
---------------------------
```text
iOS 앱
  ├─ Auth/회원동기화/번역요청
  ↓
API Gateway (또는 Nginx/Cloudflare Tunnel)
  ↓
Spring Boot App Server
  ├─ JWT + Refresh Token 인증
  ├─ User/Book/Word/Progress API
  ├─ 구독 상태/검증 모듈 (App Store 영수증 검증)
  ├─ Sync Change 처리
  └─ Translation Proxy Route (Worker 인증 토큰 포워드)
  ↓
PostgreSQL (영구 저장)
Redis (캐시/세션/레이트리밋/Idempotency)
  ↓
Cloudflare Translation Worker (기존 번역 엔진)
```

왜 이런 분리가 유리한가
-----------------------
1. 번역 API 키 노출 방지
2. 번역 결과 캐시로 비용 절감 + 속도 개선
3. Sync 충돌/재시도 정책 통합(로컬 Firebase 규칙보다 운영 단순화)
4. 구독 상태 검증을 API 서버에서 단일 진입점으로 관리
5. 장애 대응: 번역 서버만 죽어도 핵심 읽기/쓰기 일부 동작 유지

MVP 구현 범위 (2주)
--------------------
- 인증
  - `POST /v1/auth/apple` (AS 인증 토큰 전달 검증 후 JWT 발급)
  - `POST /v1/auth/refresh`
  - `POST /v1/auth/logout`
- 기본 동기화 API
  - `GET /v1/sync` (since 기반 증분)
  - `POST /v1/sync`
- 데이터 도메인
  - `GET/POST/PUT/DELETE /v1/books`
  - `GET/POST/PUT /v1/words`
  - `POST /v1/folders`, `POST /v1/folder-items`, `DELETE` 변경
  - `POST /v1/study/events`, `GET /v1/stats`
- 구독
  - `POST /v1/subscription/ios/verify`
  - `GET /v1/me/subscription`
- 번역 브릿지
  - `POST /v1/translate`
  - 내부에서 기존 Worker(`/translate`)로 전달 후 결과 캐싱/정책 적용

동일성 없는 변경(기능적)
-----------------------
- 기존 Firebase Firestore 컬렉션 구조를 1:1 복제하지 않고,
  앱에서 이미 존재하는 엔티티 기준으로 API payload를 표준화한다.
- 파일 업로드 동기화(`book file`)는 1차 MVP에서 제외하거나,
  최소한 `storage_path` 메타데이터만 전달.
  (큰 파일은 기존 클라우드 스토리지 경로 기반 참조로 전환 가능)

실행 순서
----------
1) Week 1: Spring Boot 뼈대 + DB + JWT
2) Week 2: 동기화 엔드포인트 + SyncChange 기반 Upsert/Soft delete
3) Week 3: 구독 검증 + 번역 프록시 + Redis 캐시
4) Week 4: 모니터링 + 장애 테스트 + iOS QA

데이터 동기화 전략
-------------------
- 클라이언트는 변경 내역을 `operation_id`(UUID)로 묶어 전송.
- 서버는 `operation_id` + 유저+리소스 키로 idempotency 처리.
- 타임스탬프 기반 충돌 해결:
  - 같은 필드 갱신 충돌 시 `updated_at` 최신 우선
  - 삭제(delete)가 마지막이라면 soft-delete 우선
- 동기화 응답은 `cursor`/`last_sync_token` 반환하여 다음 증분 요청에 사용

오류 정책
----------
- 번역 실패: 502 + 재시도 추천 `retryable=true`
- 동기화 충돌: 409 + `server_version`/`client_version` 반환
- 토큰 만료: 401 + refresh 지점으로 리다이렉트
- 과도 호출: 429 + `retry_after` 제공

보안 최소셋
------------
- HTTPS만 허용
- JWT secret 분리, Refresh token 회전
- API Key, 서명키는 Secret Store/Env로 주입
- 입력 검증 + SQL 인젝션 방지(jpa/query parameter)
- 요청 로그는 개인정보 마스킹 적용

단계적 전환 전략 (현재 코드 기반)
---------------------------------
- Step A: 앱에서 기존 Firebase 읽기 흐름은 유지
- Step B: 동기화 엔드포인트만 앱에서 백그라운드/오프라인 복구 용도로 병행 호출
- Step C: 검증 성공 후 Firebase Sync 경로에서 `server-first`로 스위치
- Step D: Firebase 연동 모듈(규모가 큰 경우) 정리

검증 체크리스트
---------------
1. 앱 로그인 후 `last_sync_token`이 지속 저장되는지 확인
2. 오프라인 후 재접속 동기화 충돌 0건 or 충돌 처리 UX 동작
3. 번역 실패율, 캐시 hit-rate, p95 latency 수치 수집
4. 구독 만료/갱신 시 권한 반영 지연이 1분 이내
5. 장애 주입 시 `translate` timeout > circuit breaker fallback 동작
