#!/usr/bin/env bash
# segment-cache.sh — refresh_segment_cache DB_PATH
#
# Atomically rewrites <state>/segment-cache with the pre-formatted all-time
# statusline segment: "∑ ⚡ <kWh> 💧 <L> 💨 <tonnes> ▲ <balance kg>", where the
# balance = lifetime emitted − verified removal. The statusline render path
# only ever `cat`s this file; all DB work happens here, at write time
# (Stop hook, backfill, recompute, offset recording).
#
# Never fails the caller — persist-session.sh runs without set -e in a hook
# that must exit 0.

refresh_segment_cache() {
  local db="$1" dir seg tmp
  dir="$(dirname "$db")"
  seg="$(sqlite3 "$db" "SELECT printf('∑ ⚡ %.1fkWh 💧 %.0fL 💨 %.2ft ▲ %.1fkg',
      (SELECT COALESCE(SUM(energy_wh),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(water_ml),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(co2_grams),0)/1000000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(co2_grams),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
      - (SELECT COALESCE(SUM(kg_co2e),0) FROM offsets WHERE category='removal' AND verified=1)
    );" 2>/dev/null)" || return 0
  [ -n "$seg" ] || return 0
  tmp="${dir}/.segment-cache.$$"
  printf '%s' "$seg" >"$tmp" 2>/dev/null && mv -f "$tmp" "${dir}/segment-cache" 2>/dev/null
  return 0
}
