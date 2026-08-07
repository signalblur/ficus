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
    excluded INTEGER DEFAULT 0,
    energy_wh REAL,
    water_ml REAL,
    embodied_gco2e REAL
  ); CREATE INDEX IF NOT EXISTS idx_sessions_year ON sessions(started_at);" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN cache_read_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN cache_creation_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN methodology_version INTEGER DEFAULT 1;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN excluded INTEGER DEFAULT 0;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN energy_wh REAL;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN water_ml REAL;" 2>/dev/null || true
  sqlite3 "$db" "ALTER TABLE sessions ADD COLUMN embodied_gco2e REAL;" 2>/dev/null || true
  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS offsets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    purchase_date TEXT NOT NULL,
    vendor TEXT NOT NULL,
    pathway TEXT NOT NULL,
    kg_co2e REAL NOT NULL CHECK (kg_co2e > 0),
    usd REAL NOT NULL CHECK (usd >= 0),
    category TEXT NOT NULL CHECK (category IN ('removal', 'prevention')),
    payer TEXT NOT NULL,
    receipt_path TEXT,
    receipt_sha256 TEXT,
    verified INTEGER NOT NULL DEFAULT 1,
    retirement_id TEXT,
    notes TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  );" 2>/dev/null || true
  return 0
}
