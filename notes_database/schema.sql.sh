#!/bin/bash
set -euo pipefail

# NoteMaster schema initializer (idempotent)
# - notes, tags, note_tags (many-to-many)
# - pinned flag, created_at/updated_at timestamps
# - indexes for search/tag filtering
#
# This script is designed to be called from startup.sh after database/user are ready.

DB_NAME="${DB_NAME:-notemaster}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"
DB_PORT="${DB_PORT:-5000}"

# Find PostgreSQL version and set paths (consistent with startup.sh pattern)
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Applying NoteMaster schema to DB='${DB_NAME}' as USER='${DB_USER}' on PORT='${DB_PORT}'..."

# Use ON_ERROR_STOP so any failing statement stops the script.
# Use single psql session; DDL is idempotent via IF NOT EXISTS patterns.
PGPASSWORD="${DB_PASSWORD}" ${PG_BIN}/psql -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;

-- Core table: notes
CREATE TABLE IF NOT EXISTS notes (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  pinned BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Core table: tags
CREATE TABLE IF NOT EXISTS tags (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (name)
);

-- Many-to-many mapping between notes and tags
CREATE TABLE IF NOT EXISTS note_tags (
  note_id BIGINT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (note_id, tag_id)
);

-- Keep updated_at current
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop/recreate triggers to ensure they exist and are correct
DROP TRIGGER IF EXISTS trg_notes_set_updated_at ON notes;
CREATE TRIGGER trg_notes_set_updated_at
BEFORE UPDATE ON notes
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_tags_set_updated_at ON tags;
-- Tags table doesn't have updated_at; keep only created_at for simplicity.
-- (If updated_at is later added, create trigger similarly.)

-- Indexes for pinned sorting and time-based ordering
CREATE INDEX IF NOT EXISTS idx_notes_pinned ON notes (pinned);
CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes (updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes (created_at DESC);

-- Indexes for tag filtering (join table)
CREATE INDEX IF NOT EXISTS idx_note_tags_note_id ON note_tags (note_id);
CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id ON note_tags (tag_id);

-- Simple search support
-- Prefer full text search (FTS) index using GIN.
-- Search vector includes title + content.
CREATE INDEX IF NOT EXISTS idx_notes_fts
ON notes
USING GIN (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(content,'')));

COMMIT;
SQL

echo "✓ Schema applied successfully."
