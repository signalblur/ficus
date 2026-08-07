#!/usr/bin/env bash
# schema.sh — single source of truth for the ledger schema.
# ensure_schema DB_PATH: CREATE-if-missing plus idempotent column migrations for
# pre-existing DBs. Always returns 0 and stays silent: it is called from the
# Stop/SessionStart hooks, which must never fail or block the session.
#
# Sourced by setup.sh, backfill.sh, and persist-session.sh; must stay
# side-effect-free beyond the DB it is handed.

ensure_schema() {
  local db="$1"
  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    project TEXT,
    model TEXT,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cache_read_tokens INTEGER DEFAULT 0,
    cache_creation_tokens INTEGER DEFAULT 0,
    cost_usd REAL,
    co2_grams REAL,
    started_at TEXT,
    ended_at TEXT,
    source TEXT DEFAULT 'live',
    methodology_version INTEGER DEFAULT 1,
    excluded INTEGER DEFAULT 0
  ); CREATE INDEX IF NOT EXISTS idx_sessions_year ON sessions(started_at);" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN cache_read_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN cache_creation_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN methodology_version INTEGER DEFAULT 1;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN excluded INTEGER DEFAULT 0;" 2>/dev/null || true
  return 0
}
