# Contributing to Ficus

Ficus is plain bash + jq + awk + sqlite3. No build step, no runtime
dependencies to install. It is also a fork with a pinned upstream, which
constrains how some files may be edited — read the layout and the fork rules
below before changing anything under `scripts/`.

## Layout

| Path                      | What it is                                                          |
| ------------------------- | ------------------------------------------------------------------- |
| `hooks/hooks.json`        | Stop + SessionStart hook declarations                               |
| `scripts/`                | Session capture, backfill, recompute, offsets, export, dashboard    |
| `scripts/lib/`            | Shared schema DDL, model-family mapping, factors.env, segment cache |
| `skills/`                 | The `/carbon` and `/carbon-offset` slash commands                   |
| `data/*.json`             | Every numeric constant, each with a `_source` and a date            |
| `templates/`              | Dashboard head/tail (inline CSS + vanilla JS, no external refs)     |
| `tests/`                  | One `run-*.sh` per concern; `run-tests.sh` discovers them all       |
| `statusline-snippet.sh`   | Reference statusline segment (what the benchmark measures)          |
| `METHODOLOGY.md`          | How every number is derived                                         |
| `MAINTENANCE.md`          | Upstream cherry-pick procedure and the consolidation tiers          |

## Test-driven, red first

Write the failing assertion before the code that satisfies it, and watch it
fail for the reason you expect. A test that has never been red has not been
shown to test anything. When you change behaviour an existing test covers,
change the test in the same commit and say why in the message.

Run the suite:

```bash
bash tests/run-tests.sh          # everything
bash tests/run-offset-tests.sh   # or one concern at a time
```

Every suite runs in its own sandbox: `CARBON_LEDGER_DB` points at a temp file
and the scripts derive receipts, exports, dashboards and the segment cache from
that path, so your real `~/.claude/carbon-ledger/` is never read or written. New
tests must do the same — `mktemp -d`, export `CARBON_LEDGER_DB`, and clean up
with a path-guarded `trap`. Nothing in the suite may touch the network.

Two invariants have their own gates and should not be weakened to make a change
pass:

- `tests/run-hygiene.sh` — zero network call sites in `scripts/`, `hooks/`,
  `skills/`. This is the point of the fork.
- `tests/run-dashboard-tests.sh` — the dashboard is deterministic under a
  pinned `CARBON_LEDGER_DASHBOARD_TS` and loads nothing over the network.

## Changing a factor or a price

Any edit to `data/factors.json`, `data/prices.json` or
`data/offset-constants.json` ships in the same commit as:

1. Updated expectations in `tests/methodology-vectors.json`.
2. A `_source` on the constant naming where the number came from and when it
   was recorded. No script may hardcode a constant.
3. An update to `METHODOLOGY.md` explaining the derivation. "It looks right" is
   not a derivation.
4. A green `scripts/check-crosscheck.sh` — the EcoLogits cross-check blocks a
   factor change that diverges more than 3x either way.

New constants also have to be added to the validation guard in `recompute.sh`
and the emit guard in `scripts/lib/factors-env.sh` in the same commit.

## Fork rules

The upstream remote is fetch-only. Files that exist in the `upstream-43fb883`
tag stay **byte-close to upstream** so cherry-picks apply cleanly — do not
reformat them, do not reindent them, do not clean them up in passing. The
`aggregate_jsonl` jq programs in `backfill.sh` and `persist-session.sh` are the
strictest case: they are the most likely recipients of an upstream
transcript-format fix, so leave them alone unless the change is the point of the
commit.

Fork-added files are normal code and are the only ones `shfmt` formats.
`MAINTENANCE.md` has the full tier table and the cherry-pick procedure.

## Lint

`tests/run-lint.sh` runs shellcheck over every `*.sh` and shfmt over fork-added
files only. It uses local binaries when present; otherwise it runs pinned images
through the Apple `container` CLI. `--platform linux/arm64` is not optional —
the CLI mis-detects the platform when left to negotiate:

```bash
container run --rm --platform linux/arm64 \
  --mount "type=bind,source=$PWD,target=/repo" \
  koalaman/shellcheck:stable --severity=warning /repo/scripts/your-file.sh

container run --rm --platform linux/arm64 \
  --mount "type=bind,source=$PWD,target=/repo" \
  mvdan/shfmt:latest -d -i 2 /repo/scripts/your-file.sh
```

Fix warnings rather than suppressing them. If a suppression is genuinely
required, put the justification on the line above it.

New shell scripts start with `set -euo pipefail`, and `export LC_ALL=C` when
they do any numeric formatting.

## Things that are never done

- **Never `rm -rf` a path you did not construct.** The cleanup traps in the test
  suite pattern-match the temp directory name before deleting and refuse
  anything else. Copy that shape.
- **Never move or delete a receipt.** `offset-record.sh` only ever copies. The
  receipt file, its SHA-256 and its stored bytes are the audit trail; a
  correction is a new row or an `--update`, not an edit to history.
- **Never add a network call.** Not for an update check, not for a font, not for
  a price lookup. The hygiene test will catch it, and it is there on purpose.
- **Never widen the render path.** The statusline may source `factors.env`, run
  one `awk`, and read the segment cache. No database, no jq against
  `factors.json`. New derived values are computed at write time and cached.

## Commits and pull requests

- Branch from `main`; open the PR against `main`.
- Imperative mood, one logical change per commit, subject line under 72
  characters. Describe what the code does now, not what you tried first.
- Plain language. A bug fix is a bug fix.
- Add a dated entry to `CHANGELOG.md` for user-visible changes.
- Install the hook: `git config core.hooksPath .githooks`. It runs
  `tests/run-lint.sh` and `tests/run-vectors.sh` before every commit, or defers
  to `prek run` when prek is installed.

## Security

Do not open a public issue for a security problem. See
[SECURITY.md](SECURITY.md).
