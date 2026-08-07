# Statusline segment integration

The carbon segment renders as a right-hand column beside the existing
statusline rows — a `Totals:` label on its own row above the column, cached
all-time totals beside the header (underlined), offset totals beside the
context line, session-live figures on their own row at the bottom (directly
above Claude Code's mode line):

```
                                    Totals:
[Fable 5] 📁 repo │ 🌿 main          │ ∑ ⚡ 2173.2kWh 💧 11448L 💨 0.62t
████ 10% │ $8.08 │ ⏱ 2h 17m  ↻99%   │ 💨 0.00t/0.62t · ▲ $0.03 session · $99.82/99.82 total
⚡ 0.42Wh 💧 2.2mL 💨 0.12g
```

(The label row must open with an ANSI escape — Claude Code's renderer trims
leading whitespace, and the escape stops the trim so the padding survives.)

The totals row carries the 💨 paid-off/emitted pair (verified removal purchased
vs total emitted, tonnes) and the estimated cost to offset — the current
session (▲) and an owed/overall dollar pair — at the removal rate from
`data/offset-constants.json` ($160/t biochar CORCs). In `$99.82/99.82 total`
the left number is what is still owed to clear the balance and the right is the
overall cost of everything emitted; the gap between them is what has been
contributed over time. The segment cache is three lines: the ∑ readings, the
pre-computed owed/overall pair, and the paid-off/emitted pair; the session cost
comes out of the same awk that prices the live readings.

(The reference snippet below is the minimal single-column form of the same
segment — same inputs, no column padding. The live two-column render pads each
left cell to the widest visible width, counting emoji as two cells.)

Design rule: **no fork code executes in the render path.** The statusline reads
two pre-written files and does one awk. All DB work happens at write time:

| File (in `~/.claude/carbon-ledger/`) | Written by | Read by statusline |
| --- | --- | --- |
| `factors.env` | `setup.sh`, `recompute.sh` | `source` (shell vars, numeric-guarded) |
| `segment-cache` | `persist-session.sh` (Stop hook), `backfill.sh`, `offset-record.sh`, `recompute.sh` | `sed -n Np` (three pre-formatted lines: `∑ ⚡ 2173.2kWh 💧 11448L 💨 0.62t` all-time readings / `99.82/99.82` owed-vs-overall USD / `💨 0.00t/0.62t` paid-off vs emitted) |

`statusline-snippet.sh` at the repo root is the reference implementation and is
what `tests/run-statusline-bench.sh` benchmarks (p95 < 50 ms) and checks against
the golden vectors.

## Merging into an existing statusline (single-jq-call pattern)

Phase 9 applies this to `~/.claude/statusline.sh`. Three steps:

**1. Extend the existing jq array** with three fields (keeps the single call):

```jq
.model.id // "",
(.context_window.total_input_tokens // 0),
(.context_window.total_output_tokens // 0)
```

and the matching names on the `read -r` line (e.g. `model_id in_tok out_tok`).

**2. Resolve factors and compute the live segment** (after the read):

```bash
CL_STATE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/carbon-ledger"
carbon_seg=""
if [ -f "$CL_STATE/factors.env" ]; then
  . "$CL_STATE/factors.env"
  case "$model_id" in
    *fable*|*mythos*) cl_fin=$CL_F_FAB_IN;  cl_fout=$CL_F_FAB_OUT ;;
    *opus*)           cl_fin=$CL_F_OPUS_IN; cl_fout=$CL_F_OPUS_OUT ;;
    *haiku*)          cl_fin=$CL_F_HAI_IN;  cl_fout=$CL_F_HAI_OUT ;;
    *claude*)         cl_fin=$CL_F_SON_IN;  cl_fout=$CL_F_SON_OUT ;;
    *)                cl_fin=0;             cl_fout=0 ;;
  esac
  carbon_seg="$(echo "$in_tok $out_tok $cl_fin $cl_fout $CL_CIF $CL_WATER_PER_WH" |
    LC_ALL=C awk '{co2=($1*$3+$2*$4)/1000000; e=(co2>0)?co2/$5:0;
      printf "⚡ %.2fWh 💧 %.1fmL 💨 %.2fg", e, e*$6, co2}')"
  [ -f "$CL_STATE/segment-cache" ] && carbon_seg="$carbon_seg $(cat "$CL_STATE/segment-cache")"
fi
```

**3. Render the carbon column** — capture the three cache lines with
`sed -n Np` (`carbon_all`, `carbon_total_cost`, `carbon_bal`), pad each
existing row to the widest visible width (strip ANSI, count emoji as two
cells), and print the three rows with a dim `│` rule between the columns. The
live implementation is `~/.claude/statusline.sh`; the minimal single-column
form is `statusline-snippet.sh` at the repo root.

## Accuracy notes

- The live segment prices `total_input_tokens` at the full input factor — the
  statusline JSON does not split cache reads out, so the live number slightly
  overestimates cache-heavy sessions. The DB (and everything derived from it)
  uses the exact per-kind accounting; the statusline is a live approximation.
- The `💨` paid-off/emitted pair refreshes on session end, backfill, recompute,
  and offset recording — not on every render, by design (render path stays
  file-only).
- Non-Claude model ids (local models behind `ANTHROPIC_BASE_URL`) render zeros,
  matching the ledger's exclusion rule.
