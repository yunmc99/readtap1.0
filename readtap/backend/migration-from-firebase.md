# Firebase Sync → App Server 마이그레이션 매핑

현재 앱은 `SyncEngine.swift`에서 Firestore 컬렉션을 직접 사용합니다.
아래 맵은 1:1 마이그레이션이 아니라, v1에서의 중간 호환 기준입니다.

## 공통 규칙

- `updatedAt`은 `server`와 `client` 모두 UTC ISO8601 기준 동기화
- 삭제는 `deleted_at`/`deleted=true` soft delete로 처리
- 동일 요청 중복 방지: `operation_id`(UUID)로 idempotency
- 실패 시 409 충돌 응답 + 서버가 유지한 값 반환

## 엔티티 매핑

### User
- 기존: `Auth.auth().currentUser?.uid`
- v1: `external_id` (provider별 값)로 users 등록/연동

### Book
- 기존: `books/{uid}/{bookId}` 문서
- v1:
  - `GET /v1/books`, `POST /v1/books`
  - 필드: `title`, `sourceType`, `sourceRef`, `storagePath`, `updatedAt`, `metadata`
- 파일은 초기 1차에는 직접 이전 안 함(`storagePath`만 유지)

### Folder
- 기존: `folders/{uid}/{folderId}`
- v1: `folders` 테이블 + `POST /v1/folders`(추가/수정), `DELETE /v1/folders/{id}`

### FolderItem
- 기존: `folder_items/{uid}/{id}`
- v1: `folder_items` 테이블 + `POST /v1/folder-items`, `DELETE /v1/folder-items/{id}`

### Word / Vocabulary
- 기존: `vocab/{uid}/{wordId}` + context/position/page fields
- v1: `words` 테이블 + `POST /v1/books/{bookId}/words` 또는 `/v1/sync` 배치
- 필드:
  - `term`, `context`, `meaning`, `memo`, `page`, `position`, `sourceLanguage`, `targetLanguage`

### ReadingStatus
- 기존: `bookStatus`, `readingDays` 컬렉션
- v1: `reading_statuses`, `reading_days` 테이블
- API:
  - `/v1/sync` pull/push에 통합
  - 또는 `/v1/reading-status/{bookId}`(확장 v1.1)

## 변경 이벤트 매핑 (SyncChange → API)

| SyncChange.entityType | API 전송 방식 |
| --- | --- |
| `book` | `/v1/books` upsert/delete |
| `folder` | `/v1/folders` upsert/delete |
| `folder_item` | `/v1/folder-items` upsert/delete |
| `word` | `/v1/books/{bookId}/words` upsert/delete |
| `book_status` | `/v1/sync` or dedicated reading status endpoint |
| `reading_day` | `/v1/sync` 또는 `/v1/stats` 수집 이벤트 |

## 롤아웃 제안 (무중단)

1) 앱 업데이트 1: `serverMode=OFF`(기본 Firebase)
2) 앱 업데이트 2: `/v1/sync` 병행 호출 추가 (`dual-write` or `compare-only`)
3) 서버에서 `operation_id` 중복율/충돌율 모니터링 후 스위치
4) 앱 업데이트 3: `serverMode=ON` 기본 전환, Firebase path는 읽기 전용 fallback
