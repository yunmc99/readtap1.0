# ReadTap Backend MVP (v1)

현재 앱은 Cloudflare Worker 번역 서버를 사용하고 있습니다.  
다음 단계는 **동기화/구독/회원 데이터 API 서버**를 별도 Spring Boot로 추가하는 구조입니다.

## 구성 파일

- `PLAN_BACKEND_MVP.md` : 아키텍처/우선순위/운영 전략
- `api-v1.yaml` : API 계약
- `schema.sql` : PostgreSQL 초기 스키마
- `docker-compose.yml` : 로컬 DB/Redis 환경 구성
- `.env.example` : 서버 환경변수 예시

## 1분기 실행 순서 (권장)

1. `schema.sql` 기준으로 PostgreSQL 생성
2. Spring Boot 기반 API 서버 뼈대 생성 (`/v1/auth`, `/v1/sync`, `/v1/books`, `/v1/words`, `/v1/subscription`, `/v1/translate`)
3. `api-v1.yaml` 스키마 기반 DTO/컨트롤러 생성
4. Redis 캐시 + idempotency 키 적용
5. 앱의 `SyncEngine`에서 기존 Firebase Sync와 병행 호출
6. 테스트 시나리오 통과 후 Firebase Sync 비중 점진 축소

## 빠른 검증 체크

- 사용자 토큰 발급/갱신 성공
- `/v1/sync` incremental pull/push 성공
- 책/단어 CRUD + 소프트삭제 동작
- `/v1/translate`가 번역 Worker로 정상 중계
- 구독 상태 API가 App Store 검증 결과 반영

## 개발 팁

- API 계약 변경 시 `api-v1.yaml`부터 먼저 업데이트 후 서버/앱 순으로 반영
- 동기화 변경 충돌은 `updated_at` 기준 + soft delete 정책으로 우선 통제
- 비용 최적화는 `translation` 캐시/레이트리밋/fallback이 우선
