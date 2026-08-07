# Ficus

A carbon ledger for your Claude Code usage — energy, water, CO2e, and the
offsets that settle them.

A banyan fig is one tree that grows into a whole ecosystem, and keystone figs
feed the forest around them. This tool works the same way on your sessions: one
local ledger that accounts for what your Claude Code usage costs the world, and
for whatever you put back.

**[Live demo dashboard →](https://signalblur.github.io/ficus/)** (fabricated
data — fake sessions, fake purchases, fake receipt)

Everything runs locally. No network calls, no installer, no auto-update, no
telemetry.

## What it does

**Session accounting.** A `Stop` hook parses the session transcript when it
ends and writes one row per session to SQLite: raw token counts per direction
(input, output, cache read, cache write), the dominant model, the theoretical
API list cost, and CO2e. A throttled `SessionStart` hook re-runs a backfill once
a day to catch sessions the `Stop` hook missed. Claude Code purges transcripts
after about 30 days, so the DB is the durable record.

Each row also carries derived `energy_wh`, `water_ml` and `embodied_gco2e`.
Raw tokens are stored, never just the derived figures, so revising a factor is
`recompute.sh` rather than a lost history.

**Statusline segment.** A right-hand column beside your existing statusline
rows: all-time energy / water / CO2e, the tonnes paid off against tonnes
emitted, and the dollar cost of clearing the rest. The render path does no
database work at all — it sources a pre-written `factors.env`, runs one `awk`,
and reads three pre-formatted lines out of a cache file that the write-side
scripts maintain. Benchmarked at p95 under 50 ms.

**Offset and donation recording.** `offset-record.sh` takes a purchase with a
mandatory receipt file. The receipt is copied (never moved, never deleted) into
`receipts/YYYY/`, its SHA-256 recorded, and its bytes stored in a
`receipt_blobs` table so the database alone is a complete record. Receipt text
is best-effort parsed into the same table so purchases are searchable. Registry
retirement IDs usually arrive days after payment, so they land through a
separate `--update` path. `--no-receipt` exists, stores the row `verified=0`,
and says so everywhere the row appears. Donations to conservation orgs are
recorded separately by `donation-record.sh`.

**Tax-year export.** `offset-export.sh --tax-year YYYY` writes one CSV per
payer, with the receipt hash and the retirement ID on every row. It records; it
does not give tax advice, and the header says to classify donation-vs-expense
with a CPA.

**Dashboard.** `generate-dashboard.sh` builds a single self-contained HTML file
— inline CSS, vanilla-JS SVG charts, receipts embedded as `data:` URIs — and
opens it over `file://`. It renders with the network off. A test proves it:
zero references the browser would load, and byte-identical output from the same
data under a pinned timestamp.

**Equivalences.** Totals are also expressed against real-world reference
figures (car-km, train-km, a median Gemini prompt) so a number in grams means
something. Those factors are lifecycle values while this tool's CO2 is
usage-only, so they are illustrative, not scope-matched.

## Methodology, honestly

Anthropic publishes no per-query energy data. Every figure here is an
order-of-magnitude estimate carrying roughly **±50%** uncertainty. Trends and
relative comparisons are meaningful; absolute values are indicative. Do not use
them for regulatory reporting.

The CO2e factors derive from Jegham et al. 2025 (arXiv:2505.09598), an arXiv
preprint whose method has been publicly criticized, cross-checked against
EcoLogits and Simon Couch's independent price-ratio estimate. Only Sonnet-class
models are covered directly; Opus, Haiku and Fable are extrapolations, and
Fable is a double extrapolation (2x Opus, itself 2x Sonnet). The `cache_read`
energy factor is an engineering estimate, not a measurement, and it is the
widest single lever in the tool — cache reads are 90%+ of tokens in Claude Code.

Four consequences worth stating plainly:

- **Energy is not a second model.** `energy_wh = co2_grams / 0.287` is the CIF
  identity: the CO2 factors are facility energy times the grid carbon intensity,
  so dividing recovers the energy exactly. Water and embodied carbon derive from
  that same energy. There is one estimate in the ledger, not four.
- **The headline balance counts verified removal only.** Prevention purchases
  (refrigerant or methane destruction) and unverified rows appear on their own
  lines and never fold into the balance. Destroying a tonne of refrigerant is
  worth doing and is not a tonne removed from the air.
- **The cost pair is a pure dollar ledger.** Every dollar recorded — offset or
  donation — subtracts 1:1 from the owed side, and owed goes negative past
  carbon-neutral rather than clamping at zero. It does not translate dollars
  into tonnes; only verified removal settles tonnes.
- **The cost column is list price, not what you paid.** `cost_usd` is what the
  usage would have cost on pay-as-you-go API pricing, not the subscription
  price.

Full derivations, every constant with its source and date, and the uncertainty
bands are in [METHODOLOGY.md](METHODOLOGY.md). No script hardcodes a constant;
they all live in `data/*.json` next to a `_source`.

## Install

Requires `bash`, `jq` and `sqlite3`. There is no installer and nothing to add
to a package manager — clone the repo and wire it by hand.

```bash
git clone https://github.com/signalblur/ficus.git
cd ficus
bash scripts/setup.sh
```

`setup.sh` checks dependencies, creates `~/.claude/carbon-ledger/carbon.db`,
writes `factors.env`, backfills whatever transcripts still exist, and prints the
hook block to paste into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<repo>/scripts/persist-session.sh" }] }],
    "SessionStart": [{ "matcher": "", "hooks": [{ "type": "command", "command": "<repo>/scripts/safety-rescan.sh" }] }]
  }
}
```

For the statusline, merge the segment into your existing
`~/.claude/statusline.sh` — [docs/statusline-segment.md](docs/statusline-segment.md)
walks through the single-jq-call pattern, and `statusline-snippet.sh` at the
repo root is the reference implementation.

For the `/carbon` and `/carbon-offset` commands, symlink the skills:

```bash
ln -s "$PWD/skills/carbon/SKILL.md" ~/.claude/commands/carbon.md
ln -s "$PWD/skills/carbon-offset/SKILL.md" ~/.claude/commands/carbon-offset.md
```

Both skills resolve the repo through `$CARBON_LEDGER_DIR`; set it if you cloned
somewhere other than the default path in those files.

State (database, receipts, exports, dashboards) lives in
`~/.claude/carbon-ledger/`. Override the database path with `CARBON_LEDGER_DB`;
everything else is derived from it, which is how the whole test suite runs
against throwaway sandboxes.

## Fork provenance

Ficus is a hardened fork of
[claude-carbon](https://github.com/gwittebolle/claude-carbon) by Gaëtan
Wittebolle (MIT), pinned at commit `43fb883ac1989d962c8699afb0be37fbe69c4476`
(tag `upstream-43fb883`) after a line-by-line security audit. The audit's
verdict was safe-with-caveats; the caveats were removed by deletion:

- `scripts/statusline.sh` read the Claude Code OAuth token and called
  `api.anthropic.com` for quota — deleted; this fork ships a snippet for your
  own statusline instead
- `install.sh` and `bin/claude-carbon.js` were pipe-to-shell and `npx`
  installers — deleted
- `scripts/check-update.sh`, `scripts/update.sh`, the update-check dispatch in
  `safety-rescan.sh`, and the `/carbon-update` skill were the auto-update
  surface — deleted; upstream changes are reviewed and cherry-picked by hand
- the report templates (webfont loads), the `/carbon-card` skill (which rendered
  through `python3 -m http.server`), and the release/CI/traffic tooling —
  deleted

`tests/run-hygiene.sh` locks the invariant: zero network call sites anywhere in
`scripts/`, `hooks/` or `skills/`.

Kept from upstream: the transcript parser (per-model token extraction,
deduplication by `(message.id, requestId)`, subagent inclusion), the throttled
backfill, the SQLite ledger of raw tokens, the Jegham-derived factors and price
tracking, and the golden-vector test suite. Added by the fork: the derived
physics columns, the offsets/donations ledger with receipt storage, the tax-year
export, the dashboard, the statusline segment, the EcoLogits cross-check gate,
and most of the tests.

The upstream remote is fetch-only with push disabled. The review-and-cherry-pick
procedure, the consolidation-tier policy (which files may drift from upstream
and which must stay byte-close for cherry-picks), and the constants provenance
table are in [MAINTENANCE.md](MAINTENANCE.md).

## Tests

```bash
bash tests/run-tests.sh   # auto-discovers every tests/run-*.sh
```

Golden methodology vectors, parser reconciliation against the pinned upstream
tag, the three physics write paths, the offsets ledger, the EcoLogits
cross-check plus its mutation test, a statusline latency benchmark, dashboard
determinism and offline-safety, the network-hygiene invariant, and
shellcheck/shfmt. Everything runs against sandbox databases; your real
`~/.claude` is never touched and nothing hits the network.

## Rebuilding the demo

```bash
bash scripts/build-demo.sh
```

Writes `docs/index.html` from fabricated data in a throwaway temp directory.
Deterministic — same bytes on every run.

## License

MIT. Upstream copyright Gaëtan Wittebolle; fork modifications copyright David.
See [LICENSE](LICENSE).
