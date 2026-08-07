#!/usr/bin/env bash
# segment-cache.sh — refresh_segment_cache DB_PATH
#
# Atomically rewrites <state>/segment-cache with the pre-formatted statusline
# balance segment ("▲ 12.5kg" = lifetime emitted − verified removal). The
# statusline render path only ever `cat`s this file; all DB work happens here,
# at write time (Stop hook, backfill, recompute, offset recording).
#
# Never fails the caller — persist-session.sh runs without set -e in a hook
# that must exit 0.

refresh_segment_cache() {
  local db="$1" dir bal tmp
  dir="$(dirname "$db")"
  bal="$(sqlite3 "$db" "SELECT printf('▲ %.1fkg',
      (SELECT COALESCE(SUM(co2_grams),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
      - (SELECT COALESCE(SUM(kg_co2e),0) FROM offsets WHERE category='removal' AND verified=1)
    );" 2>/dev/null)" || return 0
  [ -n "$bal" ] || return 0
  tmp="${dir}/.segment-cache.$$"
  printf '%s' "$bal" >"$tmp" 2>/dev/null && mv -f "$tmp" "${dir}/segment-cache" 2>/dev/null
  return 0
}
