---
title: Add --list-tiers flag to orch8 - Plan
type: feat
date: 2026-09-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

## Goal Capsule

**Objective.** An operator can run `orch8.sh --list-tiers` and see which driver model each built-in tier (`hard`, `grind`, `trivial`) resolves to, with no units file, no `--repo`, no git, and no Herdr pane. The printed mapping reflects whatever `orch8.config` (or `--config`) is in effect.

**Means.** One new flag in `skills/orch8/orch8.sh`, placed per KTD1: parsed in the existing flag loop, acted on after config loading and before the units-file guard. One new assertion block in `tests/run.sh`.

**Stop conditions.** Stop when `bash skills/orch8/orch8.sh --list-tiers` prints exactly three `tier->model` lines and exits 0, and `bash tests/run.sh` reports `all tests passed`. Do not touch README, the header comment block, or the `-h|--help` handler.

## Product Contract

**Summary.** Add a `--list-tiers` flag to `orch8.sh` that prints each built-in tier and its driver model, one per line, then exits 0.

**Problem Frame.** Today the only way to learn the tier-to-model mapping is to read `orch8.config` or run a dry-run with a real units file and a git repo. Operators need a zero-setup way to check it.

### Requirements

- **R1.** `orch8.sh --list-tiers` prints `hard->opus`, `grind->sonnet`, `trivial->haiku` (one per line, in that order) and exits 0 when no config overrides apply. It must not require a `units.tsv` argument, `--repo`, git, `herdr`, `jq`, or `$HERDR_PANE_ID`.
- **R2.** When a config file (auto-discovered or via `--config`) remaps any of the three built-in tiers, `--list-tiers` prints the remapped model for that tier.
- **R3.** `tests/run.sh` gains one assertion block that runs `bash "$ORCH8" --list-tiers`, checks exit code 0, and checks stdout equals exactly the three default lines.

## Planning Contract

### Key Technical Decisions

- **KTD1 — Placement of the short-circuit.** The print-and-exit block goes after the config block (after line 84, `[ -n "$KIND" ] || KIND="$WORKER_KIND"`) and before the units-file guard (line 86, `if [ -z "$UNITS" ] || [ ! -f "$UNITS" ]`). Rationale: config parsing has already rewritten `TIER_*` by then, so overrides are honored for free, and nothing downstream (units check, `REPO_ROOT` via git, `--go` preconditions) is ever reached.
- **KTD2 — Output format.** Each line is `<tier>-><model>` with no spaces, emitted via a single `printf '%s->%s\n'`. Rationale: matches the request wording literally and is trivially greppable.
- **KTD3 — Three built-in tiers only.** The loop iterates the literal list `hard grind trivial` and reads `TIER_hard`/`TIER_grind`/`TIER_trivial` by indirect expansion (`${!var}`), the same idiom `model_for()` uses. Rationale: no need to enumerate arbitrary `TIER_*` variables from `compgen`; the request names exactly these three, and the defaults on line 30 guarantee they are always set under `set -u`.

## Implementation Units

### U1. Add --list-tiers flag to orch8.sh

**Goal.** `orch8.sh --list-tiers` prints the three tier mappings and exits 0 before any repo or units preconditions run.

**Requirements.** R1, R2.

**Dependencies.** None.

**Files.** `skills/orch8/orch8.sh`

**Approach.**
1. On line 32 (`GO=0; REPO="$PWD"; ...`), add `LIST_TIERS=0` to the same defaults line.
2. In the `case "$1"` inside the flag-parsing `while` loop (lines 35-45), add a new arm `--list-tiers) LIST_TIERS=1;;` directly after the `--go) GO=1;;` arm. It takes no value, so no extra `shift`.
3. Immediately after line 84 (`[ -n "$KIND" ] || KIND="$WORKER_KIND"`) and before the `if [ -z "$UNITS" ] ...` guard, insert an `if [ "$LIST_TIERS" -eq 1 ]` block.
4. Inside that block: `for t in hard grind trivial`, set `var="TIER_$t"`, then `printf '%s->%s\n' "$t" "${!var}"`. After the loop, `exit 0`.
5. Leave the header comment, the `-h|--help` sed range, `model_for()`, and everything below the units guard unchanged.

**Test scenarios.**
- Run with `--list-tiers` and no other arguments from a directory with no `orch8.config`, using a copy of the script with no sibling config: stdout is exactly `hard->opus`, `grind->sonnet`, `trivial->haiku`; exit 0. (R1)
- Run with `--list-tiers` and no `$HERDR_PANE_ID`, no `herdr`/`jq` on PATH, and no git repo: still exits 0 with the three lines. (R1)
- Run with `--list-tiers --config FILE` where FILE maps `hard: gpt-5-codex` and omits the others: prints `hard->gpt-5-codex`, `grind->sonnet`, `trivial->haiku`. (R2)
- Run with `--list-tiers --config FILE` where FILE defines an extra tier `custom: foo`: output has exactly three lines; `custom` is not printed. (KTD3)
- Run with `--list-tiers --config /nonexistent`: exits 2 with `config not found` (pre-existing behavior, unchanged).
- Run with `--list-tiers` plus a units file positional: still prints the three lines and exits 0; the units file is never read.

**Verification.** `bash skills/orch8/orch8.sh --list-tiers; echo rc=$?` prints the three lines then `rc=0`.

### U2. Add --list-tiers assertion to tests/run.sh

**Goal.** The suite fails if `--list-tiers` stops exiting 0 or its stdout drifts from the three default lines.

**Requirements.** R3.

**Dependencies.** U1.

**Files.** `tests/run.sh`

**Approach.**
1. Insert a new section after line 112 (the closing `done` of the "no orch8.config anywhere" loop) and before the blank `echo` on line 114 that precedes the pass/fail summary.
2. Start it with the file's section-banner idiom: `echo "== --list-tiers prints tier->model and exits 0 =="`.
3. Capture output and exit code using the existing `set +e` / `... ; rc=$?` / `set -e` idiom from the "--go refuses" section: `tiers_out="$(bash "$ORCH8" --list-tiers)"; rc=$?`. No `--repo`, no units file, no `HERDR_PANE_ID`.
4. Assert with `check "exit code" "$rc" "0"`.
5. Assert with `check "tier list" "$tiers_out" "$(printf 'hard->opus\ngrind->sonnet\ntrivial->haiku')"` — `$(...)` strips the trailing newline on both sides, so the comparison is exact.
6. The sibling `skills/orch8/orch8.config` maps the three tiers to their defaults, so `$ORCH8` (not the `$WORK/bare` copy) yields the default lines; this matches how the `--go` section already asserts `opus sonnet haiku`.

**Test scenarios.**
- Suite passes with U1 applied: both new `ok` lines print. (R3)
- Revert U1's `exit 0` mentally: the script would fall through to the units guard and exit 2 — the `exit code` check fails.
- Change the arrow to ` -> ` with spaces: the `tier list` check fails and prints expected/actual.
- Reorder the loop to `trivial grind hard`: the `tier list` check fails.

**Verification.** `bash tests/run.sh` ends with `all tests passed` and includes `ok   exit code` and `ok   tier list` under the new banner.

## Verification Contract

- Run `bash tests/run.sh` from any directory. Expected last line: `all tests passed`, exit 0.
- Run `bash skills/orch8/orch8.sh --list-tiers` outside any git repo and with `HERDR_PANE_ID` unset. Expected: three lines `hard->opus`, `grind->sonnet`, `trivial->haiku`, exit 0.
- Confirm `git diff --stat` touches only `skills/orch8/orch8.sh` and `tests/run.sh`.

## Definition of Done

- `--list-tiers` is parsed in the existing flag loop and short-circuits after config load, before the units-file guard.
- Output is exactly three `tier->model` lines for `hard`, `grind`, `trivial`, honoring config overrides, exit 0.
- `tests/run.sh` has one new section asserting exit code 0 and exact stdout.
- `bash tests/run.sh` passes.
- No changes to README, the header comment block, or the `-h|--help` handler.

## Assumptions

- **A1.** The output format is `<tier>-><model>` with no whitespace around the arrow, one mapping per line, no header or trailer line.
- **A2.** Only the three built-in tiers are printed, in the fixed order `hard`, `grind`, `trivial`, even when a config file defines additional keys under `tiers:`.
