#!/usr/bin/env bash
# generate-dashboard.sh — build the self-contained HTML dashboard:
# five sqlite3 -json queries -> one jq -c DATA object -> concatenate
# templates/dashboard-head.html + "const DATA = {...};" + dashboard-tail.html
# -> <state>/dashboard/carbon-<ts>.html -> open (file://).
#
# Fully offline by construction: the templates carry inline CSS + vanilla-JS SVG
# only (tests/run-dashboard-tests.sh proves zero external references and
# deterministic output under a pinned CARBON_LEDGER_DASHBOARD_TS).
#
# DATA contract (what the templates render):
#   generated_at   ISO timestamp (pinned by CARBON_LEDGER_DASHBOARD_TS)
#   caveat         the ±50% uncertainty sentence — must stay visible
#   totals         {co2_g, energy_wh, water_ml, embodied_g, cost_usd, sessions}
#   monthly        [{month "YYYY-MM", co2_g, energy_wh, sessions}] ascending
#   by_model       [{family, co2_g, energy_wh, sessions}] desc by co2
#   offset_state   {removal_verified_kg, prevention_verified_kg, unverified_kg,
#                   balance_kg, offset_spent_usd}   — balance counts verified
#                   removal ONLY; prevention/unverified never fold in
#   offsets        [{id, purchase_date, vendor, pathway, kg_co2e, usd, category,
#                   verified, retirement_id, receipt_path}] desc by date

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DB_PATH="${CARBON_LEDGER_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/carbon-ledger/carbon.db}"
OUT_DIR="${CARBON_LEDGER_DASHBOARD_DIR:-$(dirname "$DB_PATH")/dashboard}"
TS="${CARBON_LEDGER_DASHBOARD_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
HEAD="${REPO_DIR}/templates/dashboard-head.html"
TAIL="${REPO_DIR}/templates/dashboard-tail.html"

NO_OPEN=0
case "${1:-}" in --no-open) NO_OPEN=1 ;; esac

[ -f "$DB_PATH" ] || {
  echo "No ledger DB at ${DB_PATH}. Run scripts/setup.sh first." >&2
  exit 1
}
[ -f "$HEAD" ] && [ -f "$TAIL" ] || {
  echo "Missing dashboard templates (templates/dashboard-head.html + dashboard-tail.html)." >&2
  exit 1
}

Q() { sqlite3 -json "$DB_PATH" "$1"; }
or_empty() {
  local v
  v="$(cat)"
  echo "${v:-[]}"
}

TOTALS="$(Q "SELECT COALESCE(SUM(co2_grams),0) AS co2_g,
    COALESCE(SUM(energy_wh),0) AS energy_wh, COALESCE(SUM(water_ml),0) AS water_ml,
    COALESCE(SUM(embodied_gco2e),0) AS embodied_g, COALESCE(SUM(cost_usd),0) AS cost_usd,
    COUNT(*) AS sessions
  FROM sessions WHERE COALESCE(excluded,0)=0;" | or_empty)"

MONTHLY="$(Q "SELECT substr(started_at,1,7) AS month,
    ROUND(SUM(co2_grams),1) AS co2_g, ROUND(COALESCE(SUM(energy_wh),0),1) AS energy_wh,
    COUNT(*) AS sessions
  FROM sessions WHERE COALESCE(excluded,0)=0 AND started_at != ''
  GROUP BY month ORDER BY month;" | or_empty)"

BY_MODEL="$(Q "SELECT fam AS family, ROUND(SUM(co2_grams),1) AS co2_g,
    ROUND(COALESCE(SUM(energy_wh),0),1) AS energy_wh, COUNT(*) AS sessions
  FROM (SELECT CASE
      WHEN model LIKE '%fable%' OR model LIKE '%mythos%' THEN 'fable'
      WHEN model LIKE '%opus%' THEN 'opus'
      WHEN model LIKE '%haiku%' THEN 'haiku'
      ELSE 'sonnet' END AS fam, co2_grams, energy_wh
    FROM sessions WHERE COALESCE(excluded,0)=0)
  GROUP BY fam ORDER BY SUM(co2_grams) DESC;" | or_empty)"

OFFSET_STATE="$(Q "SELECT
    ROUND(COALESCE(SUM(CASE WHEN category='removal' AND verified=1 THEN kg_co2e END),0),2) AS removal_verified_kg,
    ROUND(COALESCE(SUM(CASE WHEN category='prevention' AND verified=1 THEN kg_co2e END),0),2) AS prevention_verified_kg,
    ROUND(COALESCE(SUM(CASE WHEN verified=0 THEN kg_co2e END),0),2) AS unverified_kg,
    ROUND(COALESCE(SUM(usd),0),2) AS offset_spent_usd
  FROM offsets;" | or_empty)"

OFFSETS="$(Q "SELECT id, purchase_date, vendor, pathway, kg_co2e, usd, category,
    verified, COALESCE(retirement_id,'') AS retirement_id,
    COALESCE(receipt_path,'') AS receipt_path
  FROM offsets ORDER BY purchase_date DESC, id DESC;" | or_empty)"

DATA="$(jq -cn --arg ts "$TS" \
  --argjson totals "$TOTALS" --argjson monthly "$MONTHLY" \
  --argjson by_model "$BY_MODEL" --argjson offset_state "$OFFSET_STATE" \
  --argjson offsets "$OFFSETS" '
  {
    generated_at: $ts,
    caveat: "No vendor publishes per-query energy: every figure is an order-of-magnitude estimate (±50%). Trends are meaningful; absolutes are indicative.",
    totals: ($totals[0] // {co2_g:0,energy_wh:0,water_ml:0,embodied_g:0,cost_usd:0,sessions:0}),
    monthly: $monthly,
    by_model: $by_model,
    offset_state: (($offset_state[0] // {removal_verified_kg:0,prevention_verified_kg:0,unverified_kg:0,offset_spent_usd:0})
      + {balance_kg: ((($totals[0].co2_g // 0) / 1000 - (($offset_state[0].removal_verified_kg) // 0)) * 100 | round / 100)}),
    offsets: $offsets
  }')"

mkdir -p "$OUT_DIR"
OUT="${OUT_DIR}/carbon-$(printf '%s' "$TS" | tr ':' '-').html"
{
  cat "$HEAD"
  printf 'const DATA = %s;\n' "$DATA"
  cat "$TAIL"
} >"$OUT"

echo "Dashboard written: ${OUT}"
if [ "$NO_OPEN" = "0" ] && command -v open >/dev/null 2>&1; then
  open "$OUT"
fi
