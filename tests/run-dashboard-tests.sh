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
  ('2026-08-01','remove-carbon-today','biochar',10.0,1.60,'removal','Signalblur Security',
   '/tmp/r1.pdf','abc123',1,'PURO-1','2026-08-01T00:00:00Z'),
  ('2026-08-02','tradewater','refrigerant-destruction',200.0,3.00,'prevention','Lies Above Media',
   '/tmp/r2.pdf','def456',1,'','2026-08-02T00:00:00Z');
  INSERT INTO receipt_blobs (offset_id, filename, sha256, content, stored_at) VALUES
  (1,'2026-08-01-remove-carbon-today-1.pdf','abc123',x'25504446','2026-08-01T00:00:00Z');
  INSERT INTO donations (donation_date, org, usd, payer, receipt_path, receipt_sha256, created_at) VALUES
  ('2026-08-03','naturaland-trust',12.00,'Lies Above Media','/tmp/d1.pdf','fed789','2026-08-03T00:00:00Z');"

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
# Two narrow, named exceptions, both click-only and neither ever fetched:
#   href="https://..."        donation, source and news anchors in the markup
#   "cite_url":"https://..."  the equivalence citations inside the DATA object,
#                             which the renderer only ever puts on an anchor's
#                             href — never in a src, a stylesheet or an import.
# Anything else the browser would LOAD over the network fails the page: it must
# still render fully with Wi-Fi off, which is also why typography comes from a
# system-font stack and never a webfont.
STRIP='s/href="https:\/\/[^"]*"//g; s/"cite_url":"https:\/\/[^"]*"//g'
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
want "per-payer attribution: Signalblur Security" 'Signalblur Security'
want "per-payer attribution: Lies Above Media" 'Lies Above Media'
want "receipt SHA-256 recorded" '"receipt_sha256":"abc123"'
want "donation recorded with payer" '"org":"naturaland-trust"'
want "tax-year CSV export named" 'offset-export.sh'
want "retirement id surfaced" 'PURO-1'

# Receipt blobs ride along as base64 so the dashboard alone can hand back the
# PDF (data: URI + download attribute); rows without a blob carry "".
want "receipt blob embedded as base64" '"receipt_b64":"JVBERg=="'
want "blobless purchase carries empty receipt_b64" '"receipt_b64":""'
want "receipt link is a self-contained data: URI download" 'data:application/pdf;base64'

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
# The ranking research is blunt about reefs; the copy must not launder it.
want "honest carbon verdict on reef restoration" 'not a carbon'

# --- methodology -------------------------------------------------------------
want "methodology section" 'id="h-method"'
want "CIF identity stated" 'co2_g / 0.287'
want "water formula stated" '0.18/1.14'
want "embodied factor stated" '44.1'
want "removal-only balance rule restated" 'verified removal'

# --- dashboard idiom ---------------------------------------------------------
# The page is a console, not a statement of account. These lock the shape so a
# later content edit cannot quietly reintroduce the bill: a zoned page header, a
# card grid, and every panel a labelled section.
want "zoned page header" 'class="topbar"'
want "card grid" 'class="grid"'
want "hero panel carries the headline reading" 'class="card card--hero"'
want "charts are first-class panels, not table annexes" 'id="by-month"'
want "model breakdown is its own panel" 'id="by-model"'
# SIGNATURE: the settlement meter is a gauge with a real tick scale, which is
# what makes it a reading rather than a progress bar. Both marks are drawn at
# load time from the embedded script, so they exist in the page as the source
# that builds them, not as static attributes — assert that source.
want "settlement meter has a tick scale" 'tick--major'
want "settlement meter marks the settled boundary" 'class: "bound"'
want "settlement meter reports the settled percentage" '% settled'
# Ledger vocabulary must stay gone.
for dead in "Statement of account" "Detach for your records" 'class="sheet"' 'class="mast"' 'class="perf"'; do
  if grep -qF "$dead" "$OUT"; then
    echo "FAIL dashboard: ledger vocabulary returned: $dead" >&2
    fail=1
  fi
done
echo "PASS dashboard: ledger/bill vocabulary retired"

# --- quality floor: the page's own accessibility scaffolding ------------------
want "reduced motion honoured" 'prefers-reduced-motion'
want "print stylesheet present" '@media print'
want "visible keyboard focus" ':focus-visible'
# Charts measure two quantities, so the palette is two colours, both pinned at
# the values the dataviz validator cleared on all pairs (CVD dE 22.4 deutan,
# normal-vision dE 25.5, both >= 3:1 on white).
want "chart palette: emitted slot pinned" '\--viz-emitted: #414a8c'
want "chart palette: settled slot pinned" '\--viz-settled: #0f9563'
# No oranges or reds in the charts, and no quietly-reintroduced rainbow: the
# only chart tokens permitted are those two.
if grep -oE '\--viz-[a-z0-9-]+:' "$OUT" | sort -u |
  grep -qvE '^--viz-(emitted|settled):$'; then
  echo "FAIL dashboard: unexpected chart palette token(s):" >&2
  grep -oE '\--viz-[a-z0-9-]+:' "$OUT" | sort -u |
    grep -vE '^--viz-(emitted|settled):$' >&2
  fail=1
else
  echo "PASS dashboard: exactly two chart colours (emitted, settled)"
fi
# The working mint is the one colour on this page under a WCAG obligation: it
# draws the meaning-bearing rules (column rules, table-head underlines, callout
# bars), which SC 1.4.11 Non-text Contrast requires to reach 3:1 against the
# adjacent colour. #0f9563 measures 3.81:1 on the #ffffff sheet. Pin it, so a
# later palette pass cannot lighten it back under the threshold unnoticed.
want "meaning-bearing mint pinned at its measured value" '\--mint:      #0f9563'
want "decorative mint kept separate from the working mint" '\--mint-soft: #9cd8c2'
# One mode, and it is light. A statement of account that changes colour with the
# reader's OS setting is one you cannot check against the copy you filed, so
# there is no dark variant and no theme toggle — and the page says so twice, in
# CSS and in a meta element, so the browser does not auto-darken its own
# furniture before the stylesheet has loaded.
want "page declares itself light in CSS" 'color-scheme: light'
want "page declares itself light before CSS loads" '<meta name="color-scheme" content="light">'
if grep -q 'prefers-color-scheme' "$OUT"; then
  echo "FAIL dashboard: dark mode reintroduced — the statement renders light for everyone" >&2
  fail=1
else
  echo "PASS dashboard: no dark variant (single light palette for every reader)"
fi

# Mint is the ruling, not the paper. No surface on this page may be filled with
# it: every background resolves to the white sheet or the neutral plane.
if grep -qE 'background(-color)?:[^;]*var\(--mint' "$OUT"; then
  echo "FAIL dashboard: mint used as a surface fill — it is line-work only" >&2
  grep -nE 'background(-color)?:[^;]*var\(--mint' "$OUT" | head -3 >&2
  fail=1
else
  echo "PASS dashboard: mint is line-work only, never a surface fill"
fi
want "single main landmark" '<main'
want "skip link to the statement" 'class="skip"'

exit "$fail"
