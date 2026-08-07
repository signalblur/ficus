#!/usr/bin/env bash
# run-statusline-bench.sh — the statusline segment must be cheap and correct:
#   1. p95 added render cost < 50 ms over 20 runs
#   2. snippet math matches the golden vectors (cache-free mixes)
#   3. the render path never touches the DB (no sqlite3/DB reads in the snippet)
#
# The snippet is measured standalone (its own jq call). In production its jq
# fields merge into the user's existing single call, so this is an upper bound.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SNIPPET="${REPO_DIR}/statusline-snippet.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/carbon-ledger-slbench.XXXXXX")"
cleanup() {
  case "$TMPROOT" in
  */carbon-ledger-slbench.*) rm -rf "$TMPROOT" ;;
  *) echo "refusing to clean unexpected path: $TMPROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail=0

[ -f "$SNIPPET" ] || {
  echo "FAIL: missing $SNIPPET" >&2
  exit 1
}

# --- 3 first (cheap): no DB access in the render path ------------------------
if grep -qE 'sqlite3|carbon\.db' "$SNIPPET"; then
  echo "FAIL statusline: snippet touches the DB in the render path" >&2
  fail=1
else
  echo "PASS statusline: no DB access in render path"
fi

# --- sandbox state: factors.env from the shipped factors + a segment cache ---
STATE="${TMPROOT}/state"
mkdir -p "$STATE"
# shellcheck source=../scripts/lib/factors-env.sh
source "${REPO_DIR}/scripts/lib/factors-env.sh"
emit_factors_env "${REPO_DIR}/data/factors.json" "$STATE" || {
  echo "FAIL statusline: emit_factors_env failed" >&2
  exit 1
}
printf '∑ ⚡ 2173.2kWh 💧 11448L 💨 0.62t ▲ 623.7kg\n99.79' >"${STATE}/segment-cache"
REMOVAL_RATE="$(jq -er '.removal_usd_per_tonne' "${REPO_DIR}/data/offset-constants.json")"
SEP_LINE="────────────────────────────────"

run_snippet() {
  printf '{"model":{"id":"%s"},"context_window":{"total_input_tokens":%s,"total_output_tokens":%s}}' \
    "$1" "$2" "$3" | CARBON_LEDGER_STATE="$STATE" bash "$SNIPPET"
}

# --- 2. math matches the vectors (cache-free mixes) --------------------------
# opus-no-cache and family-precedence-fable-over-opus have zero cache tokens, so
# the statusline's in/out-only model must reproduce their expected co2/energy.
check_vector() {
  local vid="$1" model="$2"
  local in out exp_co2 exp_e got
  in="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .input_tokens' "${SCRIPT_DIR}/methodology-vectors.json")"
  out="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .output_tokens' "${SCRIPT_DIR}/methodology-vectors.json")"
  exp_co2="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .expected_co2_grams' "${SCRIPT_DIR}/methodology-vectors.json")"
  exp_e="$(jq -r --arg v "$vid" '.vectors[] | select(.id == $v) | .expected_energy_wh' "${SCRIPT_DIR}/methodology-vectors.json")"
  got="$(run_snippet "$model" "$in" "$out")"
  exp_fmt="$(echo "$exp_e $exp_co2" | LC_ALL=C awk '{printf "⚡ %.2fWh 💧 %.1fmL 💨 %.2fg", $1, $1 * 5.2678947368, $2}')"
  exp_cost="$(echo "$exp_co2 $REMOVAL_RATE" | LC_ALL=C awk '{printf "%.2f", $1 * $2 / 1000000}')"
  want="$(printf '%s ∑ ⚡ 2173.2kWh 💧 11448L 💨 0.62t ▲ 623.7kg\n%s\n🌱 $%s session · $99.79 total' \
    "$exp_fmt" "$SEP_LINE" "$exp_cost")"
  if [ "$got" = "$want" ]; then
    echo "PASS statusline math: ${vid}"
  else
    echo "FAIL statusline math ${vid}: got '${got}', want '${want}'" >&2
    fail=1
  fi
}
check_vector "opus-no-cache" "claude-opus-5"
check_vector "family-precedence-fable-over-opus" "claude-fable-opus-hybrid-test"

# non-Claude model renders zeros, never a made-up estimate
GOT_EXCL="$(run_snippet "qwen-local-7b" 100000 100000)"
case "$GOT_EXCL" in
"⚡ 0.00Wh"*) echo "PASS statusline: non-Claude model shows zero estimate" ;;
*)
  echo "FAIL statusline: non-Claude model rendered '${GOT_EXCL}'" >&2
  fail=1
  ;;
esac

# --- 1. p95 < 50 ms over 20 runs --------------------------------------------
JSON='{"model":{"id":"claude-opus-5"},"context_window":{"total_input_tokens":50000,"total_output_tokens":8000}}'
TIMES="${TMPROOT}/times"
: >"$TIMES"
i=0
while [ "$i" -lt 20 ]; do
  T0="$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')"
  printf '%s' "$JSON" | CARBON_LEDGER_STATE="$STATE" bash "$SNIPPET" >/dev/null
  T1="$(perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000')"
  echo "$((T1 - T0))" >>"$TIMES"
  i=$((i + 1))
done
P95="$(sort -n "$TIMES" | sed -n '19p')"
if [ "$P95" -lt 50 ] 2>/dev/null; then
  echo "PASS statusline bench: p95 ${P95} ms (< 50 ms over 20 runs)"
else
  echo "FAIL statusline bench: p95 ${P95} ms exceeds 50 ms" >&2
  fail=1
fi

exit "$fail"
