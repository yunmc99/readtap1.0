CREATE TABLE IF NOT EXISTS entries (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  word       TEXT NOT NULL,
  lang_pair  TEXT NOT NULL,
  pos        TEXT,
  freq_rank  INTEGER,
  source_tag TEXT NOT NULL,
  UNIQUE (word, lang_pair, pos, source_tag)
);
CREATE INDEX IF NOT EXISTS idx_entries_lookup ON entries(word, lang_pair);

CREATE TABLE IF NOT EXISTS meanings (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  entry_id     INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  sense_order  INTEGER NOT NULL,
  meaning      TEXT NOT NULL,
  register     TEXT
);
CREATE INDEX IF NOT EXISTS idx_meanings_entry ON meanings(entry_id);

CREATE TABLE IF NOT EXISTS feedback (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at      INTEGER NOT NULL,
  word            TEXT NOT NULL,
  lang_pair       TEXT NOT NULL,
  current_meaning TEXT,
  user_suggestion TEXT,
  client_id       TEXT,
  sentence_hash   TEXT,
  status          TEXT NOT NULL DEFAULT 'new'
);
CREATE INDEX IF NOT EXISTS idx_feedback_triage ON feedback(status, word, lang_pair);
