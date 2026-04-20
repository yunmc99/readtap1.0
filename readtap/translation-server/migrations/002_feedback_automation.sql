-- 002_feedback_automation.sql — Phase 2 feedback automation support.
--
-- Adds:
--   1. overrides table — human-approved dictionary corrections. The
--      /dictionary handler prefers these over seeded entries so an
--      override always wins, regardless of whether Wiktionary/Kaikki
--      later regenerates the same word's entries.
--   2. feedback.rejection_reason column — audit trail for Tier 1
--      safety-filter rejections.
--
-- Design invariant: automated or semi-automated feedback flow NEVER
-- writes to `entries` or `meanings`. Approved corrections land here
-- in `overrides`. This keeps the Wiktionary-seeded dataset pure and
-- makes every human-approved change reviewable in one place.

CREATE TABLE IF NOT EXISTS overrides (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at   INTEGER NOT NULL,
  word         TEXT NOT NULL,
  lang_pair    TEXT NOT NULL,
  pos          TEXT,
  meaning      TEXT NOT NULL,
  source       TEXT NOT NULL,          -- 'feedback-approved' | 'manual' | 'wiktionary-fix'
  approved_by  TEXT,                   -- operator handle, e.g. 'yun'
  feedback_ids TEXT,                   -- CSV of supporting feedback.id rows
  UNIQUE (word, lang_pair, pos, meaning)
);

CREATE INDEX IF NOT EXISTS idx_overrides_lookup
  ON overrides(word, lang_pair);

-- Tier 1 filter needs a place to record WHY something was auto-rejected.
-- Old rows without this column simply stay NULL; SQLite ALTER ADD COLUMN
-- is safe on existing data.
ALTER TABLE feedback ADD COLUMN rejection_reason TEXT;
