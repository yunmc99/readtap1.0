-- ReadTap Backend v1 schema (PostgreSQL)
-- 목적: 현재 앱 엔티티를 서버 동기화 중심으로 담을 최소 스키마

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS users (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  external_id   TEXT UNIQUE NOT NULL,
  provider      TEXT NOT NULL,
  email         TEXT,
  display_name  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS books (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title         TEXT NOT NULL,
  author        TEXT,
  source_type   TEXT NOT NULL CHECK (source_type IN ('pdf', 'image')),
  source_ref    TEXT,
  storage_path  TEXT,
  file_sha256   TEXT,
  page_count    INT,
  last_page_idx INT DEFAULT 0,
  metadata      JSONB DEFAULT '{}'::jsonb,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at    TIMESTAMPTZ,
  operation_id  UUID NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, source_ref)
);

CREATE INDEX IF NOT EXISTS idx_books_user_updated ON books (user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_books_user_deleted ON books (user_id, deleted_at);

CREATE TABLE IF NOT EXISTS folders (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  color_code    TEXT,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at    TIMESTAMPTZ,
  operation_id  UUID NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, name)
);

CREATE INDEX IF NOT EXISTS idx_folders_user_updated ON folders (user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS folder_items (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  folder_id     UUID NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
  book_id       UUID NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  sort_order    INT NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at    TIMESTAMPTZ,
  operation_id  UUID NOT NULL,
  UNIQUE (folder_id, book_id)
);

CREATE INDEX IF NOT EXISTS idx_folder_items_user ON folder_items (user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS words (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  book_id          UUID NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  folder_id        UUID REFERENCES folders(id) ON DELETE SET NULL,
  term             TEXT NOT NULL,
  normalized_term   TEXT GENERATED ALWAYS AS (LOWER(TRIM(term))) STORED,
  context          TEXT,
  meaning          TEXT,
  memo             TEXT,
  source_language  TEXT,
  target_language  TEXT,
  page_number      INT,
  position         JSONB,
  known            BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at       TIMESTAMPTZ,
  operation_id     UUID NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_term_non_empty CHECK (LENGTH(TRIM(term)) > 0)
);

CREATE INDEX IF NOT EXISTS idx_words_user_updated ON words (user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_words_user_book ON words (user_id, book_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_words_term_fts ON words USING gin (to_tsvector('simple', normalized_term));

CREATE TABLE IF NOT EXISTS study_sessions (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  word_id       UUID NOT NULL REFERENCES words(id) ON DELETE CASCADE,
  action        TEXT NOT NULL CHECK (action IN ('reviewed', 'known', 'unknown')),
  score         INT CHECK (score BETWEEN 0 AND 100),
  reviewed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata      JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_study_sessions_user_time ON study_sessions (user_id, reviewed_at DESC);
CREATE INDEX IF NOT EXISTS idx_study_sessions_word ON study_sessions (word_id, reviewed_at DESC);

CREATE TABLE IF NOT EXISTS reading_statuses (
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  book_id      UUID NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  page_number  INT NOT NULL DEFAULT 0,
  progress     DOUBLE PRECISION NOT NULL DEFAULT 0,
  started_at   TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, book_id)
);

CREATE TABLE IF NOT EXISTS reading_days (
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day_key         DATE NOT NULL,
  total_read_sec   INT DEFAULT 0,
  words_learned    INT DEFAULT 0,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, day_key)
);

CREATE TABLE IF NOT EXISTS subscriptions (
  user_id        UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  platform       TEXT NOT NULL DEFAULT 'ios',
  plan_id        TEXT,
  status         TEXT NOT NULL CHECK (status IN ('active', 'expired', 'cancelled', 'trial')),
  source_tx_id   TEXT UNIQUE,
  started_at     TIMESTAMPTZ,
  expires_at     TIMESTAMPTZ,
  auto_renew     BOOLEAN NOT NULL DEFAULT false,
  raw_payload    JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sync_changes (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id       TEXT NOT NULL,
  operation_id    UUID NOT NULL,
  entity_type     TEXT NOT NULL,
  operation       TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
  entity_id       UUID NOT NULL,
  payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
  server_applied  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  applied_at      TIMESTAMPTZ,
  UNIQUE (user_id, operation_id)
);

CREATE INDEX IF NOT EXISTS idx_sync_changes_user_created ON sync_changes (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_changes_pending ON sync_changes (user_id, server_applied, created_at DESC);
