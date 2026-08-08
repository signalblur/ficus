#!/usr/bin/env bash
# run-dashboard-tests.sh — the dashboard must be deterministic (same fixture DB
# + pinned timestamp -> byte-identical HTML) and fully self-contained (zero
# external references: no http(s)://, no <link>, no external src=), so it
# renders with Wi-Fi off.
#
# It also locks the structure of the redesigned statement: the meter-reading
# band and its evidence-grounded equivalences, the carbon balance, the pure
# dollar ledger (unclamped, so the carbon-negative state is a first-class
# outcome), the tax audit trail with per-payer attribution and SHA-256, the
# giving shortlist with a sources + news link per org, and the methodology
# block. Standing invariants come first; new structure after.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-dash.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-dash.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail=0

want() { # want DESCRIPTION PATTERN
  if grep -q "$2" "$OUT"; then
    echo "PASS dashboard: $1"
  else
    echo "FAIL dashboard: $1 (missing: $2)" >&2
    fail=1
  fi
}

# --- fixture DB: sessions + offsets + donations ------------------------------
DB="${TMPROOT}/carbon.db"
export CARBON_LEDGER_DB="$DB"
# shellcheck source=../scripts/lib/schema.sh
source "${REPO_DIR}/scripts/lib/schema.sh"
ensure_schema "$DB"
sqlite3 "$DB" "INSERT INTO sessions (session_id, project, model, input_tokens, output_tokens,
    cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at, ended_at,
    source, methodology_version, excluded) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','p1','claude-fable-5',1,1,42.0,12500.0,43554.0,229421.0,1920.7,
   '2026-06-01T00:00:00Z','2026-06-01T01:00:00Z','backfill',2,0),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','p2','claude-opus-5',1,1,7.0,2000.0,6968.6,36706.0,307.3,
   '2026-07-15T00:00:00Z','2026-07-15T01:00:00Z','backfill',2,0),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','p3','qwen-local',1,1,0,0,0,0,0,
   '2026-07-20T00:00:00Z','2026-07-20T01:00:00Z','backfill',2,1);
  INSERT INTO offsets (purchase_date, vendor, pathway, kg_co2e, usd, category, payer,
    receipt_path, receipt_sha256, verified, retirement_id, created_at) VALUES
  ('2026-08-01','remove-carbon-today','biochar',10.0,1.60,'removal','Acme Research LLC',
   '/tmp/r1.pdf','abc123',1,'PURO-1','2026-08-01T00:00:00Z'),
  ('2026-08-02','tradewater','refrigerant-destruction',200.0,3.00,'prevention','Example Media Co',
   '/tmp/r2.pdf','def456',1,'','2026-08-02T00:00:00Z');
  INSERT INTO receipt_blobs (offset_id, filename, sha256, content, stored_at) VALUES
  (1,'2026-08-01-remove-carbon-today-1.pdf','abc123',x'25504446','2026-08-01T00:00:00Z');
  INSERT INTO donations (donation_date, org, usd, payer, receipt_path, receipt_sha256, created_at) VALUES
  ('2026-08-03','naturaland-trust',12.00,'Example Media Co','/tmp/d1.pdf','fed789','2026-08-03T00:00:00Z');"

export CARBON_LEDGER_DASHBOARD_DIR="${TMPROOT}/dash"
export CARBON_LEDGER_DASHBOARD_TS="2026-08-06T12:00:00Z"

# --- determinism: two runs, byte-identical -----------------------------------
bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1 || {
  echo "FAIL dashboard: generate run 1 failed" >&2
  exit 1
}
OUT="${CARBON_LEDGER_DASHBOARD_DIR}/carbon-2026-08-06T12-00-00Z.html"
[ -f "$OUT" ] || {
  echo "FAIL dashboard: expected output at $OUT" >&2
  exit 1
}
cp "$OUT" "${TMPROOT}/run1.html"
bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
if cmp -s "${TMPROOT}/run1.html" "$OUT"; then
  echo "PASS dashboard: deterministic under pinned timestamp"
else
  echo "FAIL dashboard: two runs differ on the same fixture DB" >&2
  fail=1
fi

# --- zero external references ------------------------------------------------
# Three narrow, named exceptions, all click-only and none ever fetched:
#   href="https://..."        anchors the renderer built, already in the markup
#   "cite_url":"https://..."  the equivalence citations inside the DATA object
#   "url":"https://..."       the giving shortlist's donate, evidence and news
#                             links, which ride in as data rather than template
#                             prose (data/giving-shortlist.json)
# The last two are values the renderer only ever hands to setAttribute("href") —
# never to a src, a stylesheet, an import or an SVG reference.
# Anything else the browser would LOAD over the network fails the page: it must
# still render fully with Wi-Fi off, which is also why typography comes from a
# system-font stack and never a webfont.
STRIP='s/href="https:\/\/[^"]*"//g; s/"cite_url":"https:\/\/[^"]*"//g; s/"url":"https:\/\/[^"]*"//g'
if sed "$STRIP" "$OUT" |
  grep -qE 'https?://|<link|src="http|src='"'"'http|@import|url\(http'; then
  echo "FAIL dashboard: external LOADED references found:" >&2
  sed "$STRIP" "$OUT" |
    grep -nE 'https?://|<link|src="http|@import|url\(http' | head -5 >&2
  fail=1
else
  echo "PASS dashboard: zero loaded external references (offline-safe)"
fi
grep -q '@font-face' "$OUT" && {
  echo "FAIL dashboard: @font-face present — typography must be system fonts only" >&2
  fail=1
} || echo "PASS dashboard: no @font-face (system-font stack only)"

# --- content invariants ------------------------------------------------------
want "DATA embedded" 'const DATA = '
want "caveat present" '±50%'
want "complete HTML document" '</html>'
# The fixture's two non-excluded sessions emit 12500 + 2000 = 14500 g = 14.5 kg;
# the excluded qwen-local row contributes nothing. 14.5 − 10.0 verified removal
# = 4.5. Folding in the 200 kg prevention purchase would give −195.5, and
# counting it as "offset progress" would give 0 — both are wrong.
want "balance = emitted − verified removal only (4.5 kg)" '"balance_kg":4.5'

# --- real-world equivalences, computed from the DB at generation time --------
# energy 50522.6 Wh = 50.5226 kWh; at EIA 10,791 kWh/home/yr that is
#   50.5226 * 365 / 10791 = 1.71 days of an average U.S. home's electricity.
# water 266127 mL = 266.127 L; at EPA WaterSense 63.6 L/shower = 4.18 showers.
# co2 14.5 kg; at EPA 0.393 kg CO2e/mile = 36.9 miles driven.
want "equivalence: home-electricity days" '"home_days":1.71'
want "equivalence: showers" '"showers":4.18'
want "equivalence: car miles" '"car_miles":36.9'
want "equivalence factors carry their source" '"cite"'
want "equivalence cites EIA" 'eia.gov'
want "equivalence cites EPA" 'epa.gov'

# --- the dollar ledger: pure dollars, unclamped ------------------------------
# overall = 14.5 kg = 0.0145 t x $160/t = $2.32.
# contributed = every dollar given: offsets 1.60 + 3.00, donations 12.00 = $16.60.
# owed = 2.32 − 16.60 = −$14.28. Clamping at zero would erase the achievement.
want "dollar ledger overall" '"overall_usd":2.32'
want "dollar ledger contributed" '"contributed_usd":16.6'
want "dollar ledger owed is unclamped and negative" '"owed_usd":-14.28'
want "carbon-negative state is named" 'carbon-negative'

# --- tax audit trail ---------------------------------------------------------
want "audit trail section" 'id="h-audit"'
want "per-payer attribution: first payer" 'Acme Research LLC'
want "per-payer attribution: second payer" 'Example Media Co'
want "receipt SHA-256 recorded" '"receipt_sha256":"abc123"'
want "donation recorded with payer" '"org":"naturaland-trust"'
want "tax-year CSV export named" 'offset-export.sh'
want "retirement id surfaced" 'PURO-1'

# Receipt blobs ride along as base64 so the dashboard alone can hand back the
# PDF (data: URI + download attribute); rows without a blob carry "".
want "receipt blob embedded as base64" '"receipt_b64":"JVBERg=="'
want "blobless purchase carries empty receipt_b64" '"receipt_b64":""'
want "receipt link is a self-contained data: URI download" 'data:application/pdf;base64'

# --- monthly series: one row per month carrying every metric -----------------
# The three headline metrics each get their own lane in the time-series panel,
# so the monthly aggregate has to carry all three — not carbon alone. The
# fixture emits in 2026-06 and 2026-07 only (the 2026-07 qwen row is excluded).
want "monthly series carries carbon" '"month":"2026-06","co2_g":12500'
want "monthly series carries energy" '"energy_wh":43554'
want "monthly series carries water" '"water_ml":229421'

# --- trend: the third badge in each trio -------------------------------------
# Latest month against the one before it, computed in the generator. 2026-07 is
# 2000 g against 2026-06's 12500 g: (2000-12500)/12500 = -84%.
want "trend names the latest month" '"month":"2026-07"'
want "trend names the month it compares against" '"prev_month":"2026-06"'
want "trend carries the latest carbon figure" '"latest_g":2000'
want "trend carries a signed percentage change" '"pct":-84'
want "trend covers energy too" '"latest_wh":6968.6'
want "trend covers water too" '"latest_ml":36706'

# --- giving shortlist rides in as DATA, not template prose -------------------
want "giving shortlist embedded as data" '"giving":{'
want "giving shortlist is tiered" '"id":"settles"'
want "prevention tier is named separately" '"id":"prevents"'
want "conservation tier is named separately" '"id":"fund-separately"'
want "each org states what it does" '"does":"'
want "each org carries a price signal" '"price":"'
want "each org carries the honest carbon verdict" '"verdict":"'
want "each org carries supporting research or an update" '"update":"'
org_missing=0
for org in "Remove Carbon Today" "Tradewater" "Naturaland Trust" "American Rivers" \
  "Congaree Land Trust" "Billion Oyster Project" "Coral Restoration Foundation"; do
  grep -qF "\"name\":\"$org\"" "$OUT" || {
    echo "FAIL dashboard: giving shortlist missing org: $org" >&2
    org_missing=1
    fail=1
  }
done
[ "$org_missing" = "0" ] && echo "PASS dashboard: all seven orgs ride in as data"

# --- giving shortlist: donate + sources + news per org -----------------------
give_missing=0
for link in \
  removecarbontoday.com/collections \
  removecarbontoday.com/pages/proof-of-removal \
  puro.earth/insights \
  tradewater.co/buy-credits \
  tradewater.co/wp-content/uploads/2024/12 \
  tradewater.co/press \
  americanrivers.org/donate \
  arb.ca.gov/sites/default/files/2026-04 \
  americanrivers.org/media-center \
  coralrestoration.org/donate \
  pmc.ncbi.nlm.nih.gov/articles/PMC11555216 \
  coralrestoration.org/blog \
  billionoysterproject.org/donate \
  pubmed.ncbi.nlm.nih.gov/28747477 \
  billionoysterproject.org/blog \
  naturalandtrust.org/donate-now \
  greenvillejournal.com/outdoors-recreation/naturaland-trust-leads-conservation \
  naturalandtrust.org/enewsletter \
  congareelt.org/donate \
  frontiersin.org/journals/forests-and-global-change \
  congareelt.org/news; do
  grep -q "$link" "$OUT" || {
    echo "FAIL dashboard: giving-shortlist link missing: $link" >&2
    give_missing=1
    fail=1
  }
done
if [ "$give_missing" = "0" ]; then
  echo "PASS dashboard: giving shortlist carries donate + sources + news for all seven orgs"
fi
want "giving section heading" 'id="h-give"'

# --- privacy: payer names come from the ledger, never from the template -------
# The templates ship in a public repository. A payer name baked into template
# prose is the maintainer's own business identity published to everyone who
# clones it, and it is wrong for every other user besides. The page still names
# payers — it reads them out of the DB at generation time.
for tpl in "${REPO_DIR}/templates/dashboard-head.html" "${REPO_DIR}/templates/dashboard-tail.html"; do
  if grep -qE 'Signalblur|Lies Above' "$tpl"; then
    echo "FAIL dashboard: a real payer name is hardcoded in $(basename "$tpl")" >&2
    fail=1
  fi
done
echo "PASS dashboard: no payer name hardcoded in the templates"
want "payers are derived from the ledger at generation time" 'id="payer-names"'

# --- receipts: findable even with nothing on file ----------------------------
# The section a user goes looking for when they want to file a receipt must
# announce itself when it is empty, not render as a blank space between two
# headings. Assert the standing scaffolding here; the empty-ledger run below
# asserts what actually appears when there is nothing to show.
want "receipts section is named for what a user is looking for" 'id="h-audit"'
want "receipt downloads are a labelled action, not bare text" 'class: "dl"'
want "receipts are summarised above the register" 'id="receipt-roll"'

# --- methodology -------------------------------------------------------------
want "methodology section" 'id="h-method"'
want "CIF identity stated" 'co2_g / 0.287'
want "water formula stated" '0.18/1.14'
want "embodied factor stated" '44.1'
want "removal-only balance rule restated" 'verified removal'

# --- station-record idiom ----------------------------------------------------
# The page is a station record: three streams, each with the same trio of
# readings, then one shared time axis carrying all three traces. These lock that
# shape so a later content edit cannot quietly collapse it back into a bill or a
# generic admin console.
want "station header" 'class="bar"'
want "streams block" 'id="h-streams"'
want "one card per stream, keyed to its lane" 'stream stream--'
want "carbon stream present" 'stream--carbon'
want "electricity stream present" 'stream--energy'
want "water stream present" 'stream--water'
# The trio is the system: the SAME three readings, in the same order, for every
# stream. Assert all three labels, and that the third is a real month-on-month
# comparison rather than a repeat of the lifetime figure.
want "trio badge 1: lifetime total" 'Lifetime total'
want "trio badge 2: familiar-scale equivalence" 'In familiar terms'
want "trio badge 3: latest month" 'Latest month'
want "trend badge compares against the prior month" '% vs '
# SIGNATURE: the trace. Three lanes on one monthly axis, drawn at load time by
# the embedded script, so it exists in the page as the source that builds it.
want "trace panel" 'id="h-trace"'
want "trace draws one lane per stream" 'function drawTrace'
want "trace lanes are labelled in words, not colour alone" 'class: "lane__n"'
want "trace shares one time axis across the lanes" 'one time axis'
want "trace states the lanes are congruent by construction" 'congruent by construction'
want "model breakdown kept its own panel" 'id="by-model"'
# The measure: settled span solid, unsettled span OPEN. Filled-versus-open is
# the channel that survives greyscale, CVD and forced colours, which is exactly
# what the 45-degree hatch it replaced did not do reliably at small sizes.
want "measure marks the settled boundary" 'class: "bound"'
want "measure reports the settled percentage" '% settled'
want "unsettled span is an open track, not a hatch" 'class: "m-open"'
want "open track is a stroke with no fill" '\.m-open { fill: none;'
if grep -q 'patternTransform\|repeating-linear-gradient' "$OUT"; then
  echo "FAIL dashboard: the hatch fill returned — unsettled is an open track" >&2
  fail=1
else
  echo "PASS dashboard: unsettled is drawn as an open track (no hatch pattern)"
fi
# An empty station and an unsettled one must never look the same.
want "no-data track is dashed, distinct from the open track" 'track-none'
# Ledger and console vocabulary must stay gone.
for dead in "Statement of account" "Detach for your records" 'class="sheet"' 'class="mast"' 'class="perf"' 'class="topbar"'; do
  if grep -qF "$dead" "$OUT"; then
    echo "FAIL dashboard: retired vocabulary returned: $dead" >&2
    fail=1
  fi
done
echo "PASS dashboard: ledger/bill/console vocabulary retired"

# --- giving briefing: tiered, and clear about what each org does -------------
want "giving briefing groups orgs by what a gift does" 'class: "tier"'
want "each org card states its carbon verdict under a heading" 'Carbon verdict'
want "each org card surfaces the supporting research" 'Supporting research'
want "the price signal is its own object, not a sentence" 'org__price'
# The ranking research is blunt about reefs; the copy must not launder it.
want "honest carbon verdict on reef restoration" 'Not a carbon investment'

# --- quality floor: the page's own accessibility scaffolding ------------------
want "reduced motion honoured" 'prefers-reduced-motion'
want "print stylesheet present" '@media print'
want "visible keyboard focus" ':focus-visible'
# FOUR chart slots, because the page draws four things: the three streams and
# the settled span. Every value is pinned at what the dataviz validator cleared
# on ALL PAIRS (worst CVD dE 8.3 protan, worst normal-vision dE 16.6, all four
# >= 3:1 on the white sheet and on the neutral plane).
want "chart palette: carbon slot pinned" '\--viz-carbon:  #4a44a8'
want "chart palette: electricity slot pinned" '\--viz-energy:  #a03d80'
want "chart palette: water slot pinned" '\--viz-water:   #1b83c4'
want "chart palette: settled slot pinned" '\--viz-settled: #0f9563'
# No oranges or reds in the charts, and no quietly-reintroduced rainbow: the
# only chart tokens permitted are those four. Every one of them was searched
# inside the cool half of the wheel only, because emitting carbon is the normal
# state of doing the work and must never be dressed as an error.
if grep -oE '\--viz-[a-z0-9-]+:' "$OUT" | sort -u |
  grep -qvE '^--viz-(carbon|energy|water|settled):$'; then
  echo "FAIL dashboard: unexpected chart palette token(s):" >&2
  grep -oE '\--viz-[a-z0-9-]+:' "$OUT" | sort -u |
    grep -vE '^--viz-(carbon|energy|water|settled):$' >&2
  fail=1
else
  echo "PASS dashboard: exactly four chart colours (carbon, electricity, water, settled)"
fi
# The working mint is the one colour on this page under a WCAG obligation: it
# draws the meaning-bearing rules (the header rule, the section-head rules, the
# settled span, callout bars), which SC 1.4.11 Non-text Contrast requires to
# reach 3:1 against the adjacent colour. #0f9563 measures 3.82:1 on the #ffffff
# sheet and 3.43:1 on the #f1f3f2 plane. Pin it, so a later palette pass cannot
# lighten it back under the threshold unnoticed.
want "meaning-bearing mint pinned at its measured value" '\--mint:      #0f9563'
want "decorative mint kept separate from the working mint" '\--mint-soft: #9cd8c2'
# One mode, and it is light. A record that changes colour with the reader's OS
# setting is one you cannot check against the copy you filed, so there is no
# dark variant and no theme toggle — and the page says so twice, in CSS and in a
# meta element, so the browser does not auto-darken its own furniture before the
# stylesheet has loaded.
want "page declares itself light in CSS" 'color-scheme: light'
want "page declares itself light before CSS loads" '<meta name="color-scheme" content="light">'
if grep -q 'prefers-color-scheme' "$OUT"; then
  echo "FAIL dashboard: dark mode reintroduced — the record renders light for everyone" >&2
  fail=1
else
  echo "PASS dashboard: no dark variant (single light palette for every reader)"
fi

# Mint is the ruling, not the paper. No surface on this page may be filled with
# it, and no chart colour may become a background either: chart marks are drawn
# as SVG, including the legend swatches, so every background on the page
# resolves to the white sheet or the neutral plane.
if grep -qE 'background(-color)?:[^;]*var\(--(mint|viz-)' "$OUT"; then
  echo "FAIL dashboard: mint or a chart colour used as a surface fill — both are marks, not fields" >&2
  grep -nE 'background(-color)?:[^;]*var\(--(mint|viz-)' "$OUT" | head -3 >&2
  fail=1
else
  echo "PASS dashboard: mint and the chart palette are marks only, never a surface fill"
fi
# --- the empty ledger: an empty screen is an invitation to act ---------------
# A fresh install has no offsets and no donations, which is exactly the state a
# user is in when they go looking for "where do I put my receipts". Rendering a
# blank space between two headings is how that user concludes the feature does
# not exist. Regenerate against a books-empty DB and assert the section tells
# them what will appear here and the exact command that puts it there.
EMPTY_DB="${TMPROOT}/empty.db"
CARBON_LEDGER_DB="$EMPTY_DB" ensure_schema "$EMPTY_DB"
sqlite3 "$EMPTY_DB" "INSERT INTO sessions (session_id, project, model, input_tokens,
    output_tokens, cost_usd, co2_grams, energy_wh, water_ml, embodied_gco2e, started_at,
    ended_at, source, methodology_version, excluded) VALUES
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','p1','claude-opus-5',1,1,3.0,900.0,3136.0,16515.0,138.3,
   '2026-08-01T00:00:00Z','2026-08-01T01:00:00Z','backfill',2,0);"
EMPTY_OUT="${CARBON_LEDGER_DASHBOARD_DIR}/empty/carbon-2026-08-06T12-00-00Z.html"
CARBON_LEDGER_DB="$EMPTY_DB" \
  CARBON_LEDGER_DASHBOARD_DIR="${CARBON_LEDGER_DASHBOARD_DIR}/empty" \
  bash "${REPO_DIR}/scripts/generate-dashboard.sh" --no-open >/dev/null 2>&1
[ -f "$EMPTY_OUT" ] || {
  echo "FAIL dashboard: empty-ledger render produced no file" >&2
  fail=1
}
ewant() { # ewant DESCRIPTION PATTERN — assert against the empty-ledger render
  # -e, so a pattern that begins with a dash is a pattern and not an option.
  if grep -q -e "$2" "$EMPTY_OUT"; then
    echo "PASS dashboard (empty ledger): $1"
  else
    echo "FAIL dashboard (empty ledger): $1 (missing: $2)" >&2
    fail=1
  fi
}
ewant "the empty books announce themselves" 'class: "start"'
ewant "names what will appear here once a purchase is filed" 'this section will show'
ewant "names the retirement ID that will appear here" 'registry retirement ID'
ewant "gives the skill that records a purchase" '/carbon-offset'
ewant "gives the exact recording command" 'offset-record.sh'
ewant "gives the purchase flags" '--kg 25 --usd'
ewant "gives the receipt flag by name" '--receipt'
ewant "says why a static page cannot take an upload" 'cannot accept an upload'
ewant "gives the donation command too" 'donation-record.sh'
# The page is built by script, so grepping the source cannot tell a rendered
# register from the code that would render one. Assert the thing that IS
# state-specific — the embedded DATA — so the assertions above are known to be
# about the empty state and not about a register that happened to have rows.
ewant "the render really had empty books" '"offsets":\[\]'
ewant "and no donations either" '"donations":\[\]'

want "single main landmark" '<main'
want "skip link to the record" 'class="skip"'

exit "$fail"
