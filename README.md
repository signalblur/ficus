# carbon-ledger

Local, hardened fork of [claude-carbon](https://github.com/gwittebolle/claude-carbon)
(MIT, copyright Gaëtan Wittebolle — see [LICENSE](LICENSE)), pinned at the
security-audited upstream commit `43fb883` (tag `upstream-43fb883`).

Tracks the energy, water, and CO2e footprint of Claude Code usage from session
transcripts into a local SQLite ledger, and (in this fork) records receipt-backed
carbon-offset purchases against it. Everything runs locally: **no network calls,
no installers, no auto-updates, no telemetry.**

## Fork provenance and hardening

Forked 2026-08-06 from upstream `43fb883ac1989d962c8699afb0be37fbe69c4476` after a
line-by-line security audit (verdict: safe with caveats). The caveats were removed
by deletion in this fork's first commits:

- `scripts/statusline.sh` — read the Claude Code OAuth token and called
  api.anthropic.com for quota; deleted (this fork ships a snippet for the user's
  own statusline instead)
- `install.sh`, `bin/claude-carbon.js` — pipe-to-shell / npx installers; deleted
  (install is a hand-wired local clone)
- `scripts/check-update.sh`, `scripts/update.sh`, the update-check dispatch in
  `safety-rescan.sh`, and the `/carbon-update` skill — auto-update surface;
  deleted (upstream changes are reviewed and cherry-picked manually)
- `templates/` (webfont loads), `/carbon-card` (`python3 -m http.server` render
  path), release/CI/traffic tooling — deleted

`tests/run-hygiene.sh` proves the invariant: zero network call sites in
`scripts/`, `hooks/`, `skills/`.

## What is kept from upstream

- Stop-hook transcript parser (per-model token extraction, dedup by
  `(message.id, requestId)`, subagent inclusion) and the 24h-throttled
  SessionStart backfill
- SQLite ledger of raw token counts (factors revisable; `recompute.sh` re-derives
  history)
- Jegham et al. 2025-derived CO2e factors and `data/prices.json` cost tracking
- The golden-vector test suite (`tests/`), extended by this fork

## Maintenance

Upstream remote is fetch-only (push disabled). On upstream releases:
`git fetch upstream`, diff-review, cherry-pick only reviewed commits.
See MAINTENANCE.md (added in a later phase) for the full procedure.

## Tests

```bash
bash tests/run-tests.sh   # runs every tests/run-*.sh suite
```

shellcheck/shfmt run via Apple containers when not installed locally
(`tests/run-lint.sh`).
