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
#                   payer, verified, retirement_id, receipt_sha256, receipt_path,
#                   receipt_filename, receipt_b64}] desc by date — receipt_b64 is
#                   the stored blob, "" when none
#   donations      [{id, donation_date, org, usd, payer, receipt_sha256}] desc
#   cost           {rate_usd_per_tonne, overall_usd, contributed_usd, owed_usd}
#                  PURE dollar ledger, UNCLAMPED: owed goes negative once
#                  contributions pass the cost of everything emitted
#   equivalences   {home_days, showers, car_miles} plus the factor, unit, noun
#                  and citation each came from (data/equivalence-constants.json)
#   constants      the physics constants the methodology block prints, read from
#                  data/factors.json so the page can never drift from the ledger
#
# No raw URL ever reaches DATA as free text: citation URLs travel in dedicated
# cite_url fields and are rendered as click-only anchors, which is what keeps
# the offline invariant testable (tests strip href="https://…" and then forbid
# every remaining occurrence of http).

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DB_PATH="${CARBON_LEDGER_DB:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/carbon-ledger/carbon.db}"
OUT_DIR="${CARBON_LEDGER_DASHBOARD_DIR:-$(dirname "$DB_PATH")/dashboard}"
TS="${CARBON_LEDGER_DASHBOARD_TS:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
HEAD="${REPO_DIR}/templates/dashboard-head.html"
TAIL="${REPO_DIR}/templates/dashboard-tail.html"
EQUIV="${REPO_DIR}/data/equivalence-constants.json"
FACTORS="${REPO_DIR}/data/factors.json"
OFFSET_CONSTANTS="${REPO_DIR}/data/offset-constants.json"

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
for f in "$EQUIV" "$FACTORS" "$OFFSET_CONSTANTS"; do
  [ -f "$f" ] || {
    echo "Missing constants file: ${f}" >&2
    exit 1
  }
done

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

# receipt_b64 rides the DB blob into the page so the dashboard alone can hand
# the PDF back (data: URI download); base64() needs sqlite3 >= 3.41.
# payer and receipt_sha256 ride along too: they are the audit trail a tax-year
# export is reconciled against (scripts/offset-export.sh).
OFFSETS="$(Q "SELECT o.id, o.purchase_date, o.vendor, o.pathway, o.kg_co2e, o.usd,
    o.category, o.payer, o.verified, COALESCE(o.retirement_id,'') AS retirement_id,
    COALESCE(o.receipt_sha256,'') AS receipt_sha256,
    COALESCE(o.receipt_path,'') AS receipt_path,
    COALESCE(rb.filename,'') AS receipt_filename,
    CASE WHEN rb.content IS NULL THEN ''
      ELSE replace(base64(rb.content), char(10), '') END AS receipt_b64
  FROM offsets o LEFT JOIN receipt_blobs rb ON rb.offset_id = o.id
  ORDER BY o.purchase_date DESC, o.id DESC;" | or_empty)"

DONATIONS="$(Q "SELECT id, donation_date, org, usd, payer,
    COALESCE(receipt_sha256,'') AS receipt_sha256
  FROM donations ORDER BY donation_date DESC, id DESC;" | or_empty)"

# The cost pair is a PURE dollar ledger and stays unclamped: overall prices
# everything emitted at the removal rate; owed subtracts every dollar
# contributed (offsets + donations, 1:1, no kg translation). Once contributions
# pass the overall cost, owed goes negative — that is the carbon-negative state,
# not an error, and the page renders it as an achievement.
CONTRIB="$(Q "SELECT ROUND((SELECT COALESCE(SUM(usd),0) FROM offsets)
    + (SELECT COALESCE(SUM(usd),0) FROM donations), 2) AS contributed_usd;" | or_empty)"

DATA="$(jq -cn --arg ts "$TS" \
  --argjson totals "$TOTALS" --argjson monthly "$MONTHLY" \
  --argjson by_model "$BY_MODEL" --argjson offset_state "$OFFSET_STATE" \
  --argjson offsets "$OFFSETS" --argjson donations "$DONATIONS" \
  --argjson contrib "$CONTRIB" \
  --slurpfile equiv "$EQUIV" --slurpfile factors "$FACTORS" \
  --slurpfile oc "$OFFSET_CONSTANTS" '
  def r2: . * 100 | round / 100;
  ($totals[0] // {co2_g:0,energy_wh:0,water_ml:0,embodied_g:0,cost_usd:0,sessions:0}) as $T
  | ($equiv[0]) as $E | ($factors[0].physics) as $P
  | (($oc[0].removal_usd_per_tonne // 160)) as $rate
  | (($T.co2_g // 0) / 1000) as $kg
  | (($T.energy_wh // 0) / 1000) as $kwh
  | (($T.water_ml // 0) / 1000) as $liters
  | (($kg / 1000) * $rate | r2) as $overall
  | (($contrib[0].contributed_usd // 0) | r2) as $given
  | {
    generated_at: $ts,
    caveat: "No vendor publishes per-query energy: every figure is an order-of-magnitude estimate (±50%). Trends are meaningful; absolutes are indicative.",
    totals: $T,
    monthly: $monthly,
    by_model: $by_model,
    offset_state: (($offset_state[0] // {removal_verified_kg:0,prevention_verified_kg:0,unverified_kg:0,offset_spent_usd:0})
      + {balance_kg: (($kg - (($offset_state[0].removal_verified_kg) // 0)) | r2),
         offset_spent_usd: ((($offset_state[0].offset_spent_usd) // 0) | r2)}),
    offsets: $offsets,
    donations: $donations,
    cost: {
      rate_usd_per_tonne: $rate,
      overall_usd: $overall,
      contributed_usd: $given,
      owed_usd: (($overall - $given) | r2)
    },
    equivalences: {
      home_days:  (($kwh * 365 / $E.energy.value) | r2),
      showers:    (($liters / $E.water.value) | r2),
      car_miles:  (($kg / $E.co2.value) | r2),
      energy: ($E.energy | {value, unit, noun, cite, cite_url}),
      water:  ($E.water  | {value, unit, noun, cite, cite_url}),
      co2:    ($E.co2    | {value, unit, noun, cite, cite_url})
    },
    constants: {
      grid_cif_g_per_wh: $P.grid_cif_g_per_wh.value,
      pue: $P.pue.value,
      wue_onsite_l_per_kwh: $P.wue_onsite_l_per_kwh.value,
      wue_offsite_l_per_kwh: $P.wue_offsite_l_per_kwh.value,
      embodied_gco2e_per_kwh: $P.embodied_gco2e_per_kwh.value,
      cache_read_factor: ($factors[0].cache_read_factor // 0.08)
    },
    # Formulas are composed here, from the same constants the ledger computes
    # with, so the methodology block can never quote a factor the ledger no
    # longer uses. The template prints these verbatim.
    formulas: {
      co2: "co2_g = ((input + cache_write) × f_in + cache_read × f_in × \(($factors[0].cache_read_factor // 0.08)) + output × f_out) / 1e6",
      energy: "energy_wh = co2_g / \($P.grid_cif_g_per_wh.value)",
      water: "water_ml = energy_wh × (\($P.wue_onsite_l_per_kwh.value)/\($P.pue.value) + \($P.wue_offsite_l_per_kwh.value))",
      embodied: "embodied_g = energy_wh × \($P.embodied_gco2e_per_kwh.value) / 1000",
      balance: "balance_kg = emitted_kg − verified_removal_kg",
      owed: "owed = emitted_t × \($rate) − (offset_$ + donation_$)"
    }
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
