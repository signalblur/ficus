#!/usr/bin/env bash
# statusline-snippet.sh — REFERENCE implementation of the carbon statusline
# segment: session-live ⚡ energy / 💧 water / 💨 co2 plus the cached ▲ unoffset
# balance. See docs/statusline-segment.md for merging this into an existing
# statusline (fold the jq fields into your existing single jq call).
#
# Render-path budget rules: NO DB access, NO jq against factors.json — only
# `source factors.env`, one awk, and `cat` of the pre-formatted segment cache.
# Both files are written by the fork's scripts (setup/recompute for factors.env;
# persist-session/offset-record for segment-cache).

STATE_DIR="${CARBON_LEDGER_STATE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/carbon-ledger}"

INPUT="$(cat)"
IFS="$(printf '\t')" read -r MODEL_ID IN_TOK OUT_TOK <<EOF
$(echo "$INPUT" | jq -r '[.model.id // "", (.context_window.total_input_tokens // 0), (.context_window.total_output_tokens // 0)] | @tsv' 2>/dev/null)
EOF

[ -f "${STATE_DIR}/factors.env" ] || exit 0
# shellcheck source=/dev/null
. "${STATE_DIR}/factors.env"

# First-match family precedence, mirroring scripts/lib/model-family.sh
# (model ids from Claude Code are lowercase). Non-Claude models get no estimate.
case "$MODEL_ID" in
*fable* | *mythos*) FIN="$CL_F_FAB_IN" FOUT="$CL_F_FAB_OUT" ;;
*opus*) FIN="$CL_F_OPUS_IN" FOUT="$CL_F_OPUS_OUT" ;;
*haiku*) FIN="$CL_F_HAI_IN" FOUT="$CL_F_HAI_OUT" ;;
*claude*) FIN="$CL_F_SON_IN" FOUT="$CL_F_SON_OUT" ;;
*) FIN=0 FOUT=0 ;;
esac

SEG="$(echo "$IN_TOK $OUT_TOK $FIN $FOUT $CL_CIF $CL_WATER_PER_WH" | LC_ALL=C awk \
  '{co2 = ($1 * $3 + $2 * $4) / 1000000
    e = (co2 > 0) ? co2 / $5 : 0
    printf "⚡ %.2fWh 💧 %.1fmL 💨 %.2fg", e, e * $6, co2}')"

BAL=""
[ -f "${STATE_DIR}/segment-cache" ] && BAL=" $(cat "${STATE_DIR}/segment-cache")"
printf '%s%s' "$SEG" "$BAL"
