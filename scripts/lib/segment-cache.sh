#!/usr/bin/env bash
# segment-cache.sh — refresh_segment_cache DB_PATH
#
# Atomically rewrites <state>/segment-cache with the pre-formatted all-time
# statusline segment, two lines:
#   1: "∑ ⚡ <kWh> 💧 <L> 💨 <tonnes> ▲ <balance kg>"  (balance = emitted −
#      verified removal)
#   2: "<usd>"  — cost to clear the balance at the removal rate from
#      data/offset-constants.json (clamped at 0 when overbought)
# The statusline render path only ever reads this file; all DB work happens
# here, at write time (Stop hook, backfill, recompute, offset recording).
#
# Never fails the caller — persist-session.sh runs without set -e in a hook
# that must exit 0.

refresh_segment_cache() {
  local db="$1" dir seg rate cost tmp
  local lib_dir constants
  dir="$(dirname "$db")"
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  constants="${lib_dir}/../../data/offset-constants.json"

  rate="$(jq -r '.removal_usd_per_tonne // 160' "$constants" 2>/dev/null)" || rate=160
  case "$rate" in
  '' | *[!0-9.]*) rate=160 ;;
  esac

  seg="$(sqlite3 "$db" "SELECT printf('∑ ⚡ %.1fkWh 💧 %.0fL 💨 %.2ft ▲ %.1fkg',
      (SELECT COALESCE(SUM(energy_wh),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(water_ml),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(co2_grams),0)/1000000.0 FROM sessions WHERE COALESCE(excluded,0)=0),
      (SELECT COALESCE(SUM(co2_grams),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
      - (SELECT COALESCE(SUM(kg_co2e),0) FROM offsets WHERE category='removal' AND verified=1)
    );" 2>/dev/null)" || return 0
  [ -n "$seg" ] || return 0

  cost="$(sqlite3 "$db" "SELECT printf('%.2f', MAX(0,
      (SELECT COALESCE(SUM(co2_grams),0)/1000.0 FROM sessions WHERE COALESCE(excluded,0)=0)
      - (SELECT COALESCE(SUM(kg_co2e),0) FROM offsets WHERE category='removal' AND verified=1)
    ) * ${rate} / 1000.0);" 2>/dev/null)" || cost=""

  tmp="${dir}/.segment-cache.$$"
  printf '%s\n%s' "$seg" "$cost" >"$tmp" 2>/dev/null && mv -f "$tmp" "${dir}/segment-cache" 2>/dev/null
  return 0
}
