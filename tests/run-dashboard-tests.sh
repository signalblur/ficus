#!/usr/bin/env bash
# run-dashboard-tests.sh — the dashboard must be deterministic (same fixture DB
# + pinned timestamp -> byte-identical HTML) and fully self-contained (zero
# external references: no http(s)://, no <link>, no external src=), so it
# renders with Wi-Fi off.

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

# --- fixture DB: sessions + offsets ------------------------------------------
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
  (1,'2026-08-01-remove-carbon-today-1.pdf','abc123',x'25504446','2026-08-01T00:00:00Z');"

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
# Click-only donation anchors (href="https://...") are allowed; anything the
# browser would LOAD over the network (stylesheets, scripts, images, imports)
# is not — the page must still render fully with Wi-Fi off.
if sed 's/href="https:\/\/[^"]*"//g' "$OUT" |
  grep -qE 'https?://|<link|src="http|src='"'"'http|@import|url\(http'; then
  echo "FAIL dashboard: external LOADED references found:" >&2
  sed 's/href="https:\/\/[^"]*"//g' "$OUT" |
    grep -nE 'https?://|<link|src="http|@import|url\(http' | head -5 >&2
  fail=1
else
  echo "PASS dashboard: zero loaded external references (offline-safe)"
fi

# --- content invariants --------------------------------------------------------
grep -q 'const DATA = ' "$OUT" && echo "PASS dashboard: DATA embedded" || {
  echo "FAIL dashboard: DATA object missing" >&2
  fail=1
}
grep -q '±50%' "$OUT" && echo "PASS dashboard: caveat present" || {
  echo "FAIL dashboard: ±50% caveat missing" >&2
  fail=1
}
# The fixture's two non-excluded sessions emit 12500 + 2000 = 14500 g = 14.5 kg;
# the excluded qwen-local row contributes nothing. 14.5 − 10.0 verified removal
# = 4.5. Folding in the 200 kg prevention purchase would give −195.5, and
# counting it as "offset progress" would give 0 — both are wrong.
grep -q '"balance_kg":4.5' "$OUT" &&
  echo "PASS dashboard: balance = emitted − verified removal only (4.5 kg)" || {
  echo "FAIL dashboard: balance_kg wrong (want 4.5: 14.5 emitted − 10 removal; prevention must not fold in)" >&2
  fail=1
}
grep -q '</html>' "$OUT" && echo "PASS dashboard: complete HTML document" || {
  echo "FAIL dashboard: truncated HTML" >&2
  fail=1
}
# --- giving shortlist ----------------------------------------------------------
# Seven curated donation links, one per ecosystem; click-only anchors.
give_missing=0
for link in removecarbontoday.com tradewater.co/buy-credits \
  americanrivers.org/donate coralrestoration.org/donate \
  billionoysterproject.org/donate \
  naturalandtrust.org/donate-now congareelt.org/donate; do
  grep -q "$link" "$OUT" || {
    echo "FAIL dashboard: donation link missing: $link" >&2
    give_missing=1
    fail=1
  }
done
if [ "$give_missing" = "0" ] && grep -q 'id="h-give"' "$OUT"; then
  echo "PASS dashboard: giving shortlist present with all seven links"
elif [ "$give_missing" = "0" ]; then
  echo "FAIL dashboard: giving section heading (h-give) missing" >&2
  fail=1
fi

# Receipt blobs ride along as base64 so the dashboard alone can hand back the
# PDF (data: URI + download attribute); rows without a blob carry "".
grep -q '"receipt_b64":"JVBERg=="' "$OUT" &&
  echo "PASS dashboard: receipt blob embedded as base64" || {
  echo "FAIL dashboard: receipt blob base64 missing from DATA" >&2
  fail=1
}
grep -q '"receipt_b64":""' "$OUT" &&
  echo "PASS dashboard: blobless purchase carries empty receipt_b64" || {
  echo "FAIL dashboard: blobless purchase should carry empty receipt_b64" >&2
  fail=1
}
grep -q 'data:application/pdf;base64' "$OUT" &&
  echo "PASS dashboard: receipt link is a self-contained data: URI download" || {
  echo "FAIL dashboard: data: URI receipt download missing" >&2
  fail=1
}

exit "$fail"
