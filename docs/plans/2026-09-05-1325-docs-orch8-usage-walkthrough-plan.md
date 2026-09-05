---
title: orch8 Usage Walkthrough (docs/USAGE.md) - Plan
type: docs
date: 2026-09-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

## Goal Capsule

**Objective.** Someone who wants to run orch8 can follow `docs/USAGE.md` alone to write a `units.tsv`, dry-run it, fire it with `--go`, and track the spawned Herdr panes through to PRs, without reading `README.md` or `skills/orch8/orch8.sh`.

**Means.** Create one new file, `docs/USAGE.md`. Scope is fixed by KTD1: no other file changes.

**Authority / stop conditions.** Docs-only. No script, config, or test behavior changes. Stop if writing the walkthrough would require editing any existing file; that is out of scope, not a follow-up.

**Execution profile.** Durable, Lightweight. Single unit, single new file, headless pipeline run.

---

## Product Contract

**Summary.** Add `docs/USAGE.md`, a task-ordered walkthrough of running orch8 end to end. It covers the `units.tsv` format, dry-run vs `--go`, tier-to-driver-model mapping, and tracking the spawned panes.

**Problem Frame.** `README.md` is a reference and overview doc: architecture, install, levers, safety, config. A first-time operator has to assemble the run sequence from several sections plus the script header. There is no single "do this, then this" page.

### Requirements

Content:

R1. `docs/USAGE.md` opens with a one-paragraph orientation: what orch8 does and its hard dependency on Herdr plus a worker pipeline. It does not repeat the README architecture pitch.

R2. The doc walks the full sequence in order: write `units.tsv` -> dry-run -> read the printed plan -> `--go` -> track panes -> gate/escalate.

R3. The doc explains `units.tsv` in detail: tab-separated `<id>\t<tier>\t<prompt>`, blank lines and `#` lines skipped, id sanitization into a Herdr agent name (lowercased, non `[a-z0-9_-]` -> `-`, `u-` prefix if not starting with a letter, 32-char cap, reused as branch suffix `orch8/<name>` and worktree dir), and a worked example TSV.

R4. The doc explains dry-run as the default and `--go` as the only mutating flag: exact invocation for each, what dry-run prints (header, per-unit commands, footer), what it guarantees (no worktrees, panes, or agents), the `--go` preconditions (`herdr` and `jq` on PATH, `$HERDR_PANE_ID` set), and the pane-split-failure skip behavior.

R5. The doc explains tier-to-driver-model mapping: the `tiers` map in `skills/orch8/orch8.config`, the shipped defaults (`hard`->opus, `grind`->sonnet, `trivial`->haiku), that an unmapped tier is passed verbatim as the model name, and that this launch flag is distinct from the per-worktree planning-elevation file (`skills/orch8/config.tiers/<tier>.local.yaml` -> `<worktree>/.compound-engineering/config.local.yaml`). The distinction is noted briefly, not re-derived from the README table.

R6. The doc explains tracking: `herdr agent list`, `herdr agent wait <name> --until done`, `herdr agent read <name> --source recent-unwrapped`; that "done" means each pane opened its own PR (or is reported stalled with its transcript); and the gate/escalate step (review each PR, bump a stalled or weak unit's tier in the TSV, re-run just that line).

R7. Every command and behavior stated in the doc is grounded in `skills/orch8/orch8.sh`, `skills/orch8/orch8.config`, `skills/orch8/SKILL.md`, or `README.md`. No invented flags or behavior.

Scope:

R8. The change creates `docs/USAGE.md` only. `README.md` and every other existing file remain unchanged.

### Scope Boundaries

- `README.md` is not edited and not restructured. This is a settled exclusion, not deferred work. `docs/USAGE.md` may link to `README.md` for the fuller reference (architecture, install, config) it deliberately does not repeat — that is a pointer, not an edit to `README.md` itself.
- `skills/orch8/SKILL.md`, `skills/orch8/orch8.sh`, `skills/orch8/orch8.config`, `docs/architecture.html`, and `tests/run.sh` are untouched.
- No new config keys, flags, or tier files.

---

## Planning Contract

KTD1. Ship the walkthrough as a new standalone file, `docs/USAGE.md`, rather than expanding `README.md`. (session-settled: user-directed — chosen over folding this content into README.md: user explicitly scoped the task to a new, standalone file only)

KTD2. Order sections by the operator's run sequence (write TSV -> dry-run -> `--go` -> track -> gate), not by topic. The four required topics land inside the step that uses them: TSV format under "write units.tsv", tier mapping inside that same step (it is what the `tier` column means), dry-run and `--go` as consecutive steps, tracking and gate last. This keeps the doc a walkthrough instead of a second reference page.

---

## Implementation Units

### U1. Write docs/USAGE.md

**Goal.** Produce the walkthrough described by R1-R7 in a single new file.

**Requirements.** R1, R2, R3, R4, R5, R6, R7, R8; KTD1, KTD2.

**Dependencies.** None.

**Files.**
- `docs/USAGE.md` (new)

**Approach.** Write the file with these sections, in this order:

1. **Orientation (R1).** One paragraph: orch8 reads `units.tsv`, gives each unit its own git worktree and a pane in Herdr (the pane/agent runner orch8 orchestrates through), starts a driver agent in that pane at the tier's model, and sends it a ship command (default `/lfg`) that is expected to end in a PR. Requires Herdr plus a worker pipeline — a decompose command that turns a goal into units and a ship command each pane runs. Link nothing; do not restate architecture.

2. **Step 1: Write `units.tsv` (R3, R5).**
   - Format: one unit per line, `<id>\t<tier>\t<prompt>`, tab-separated. Blank lines and lines starting with `#` are skipped.
   - Worked example (use the README's three lines verbatim, with a leading `#` comment line to show comment skipping):
     ```
     # id	tier	prompt
     auth-device-flow	hard	Add the OAuth device authorisation flow
     rate-limiter	grind	Add a token-bucket limiter to the public API
     footer-copy	trivial	Fix the footer copy and the trailing comma
     ```
   - `id`: sanitized into the Herdr agent name (lowercase; any char outside `[a-z0-9_-]` becomes `-`; prefixed `u-` if it does not start with a letter; truncated to 32 chars). The sanitized name is also the branch suffix (`orch8/<name>`) and the worktree directory name. Warn that two different ids can sanitize to the same name (e.g. `Foo` and `foo`, or two ids that collide after the 32-char cap) — pick ids that stay distinct after sanitizing, since a collision means the two units share one branch, worktree, and tracking handle.
   - `tier`: selects the driver model via the `tiers` map in `skills/orch8/orch8.config`. Small table: `hard` -> `opus`, `grind` -> `sonnet`, `trivial` -> `haiku`. State that a tier absent from the map is passed to Herdr verbatim as the model name, so tiers are a convention, not a closed set. Show the resulting launch line: `herdr agent start <name> --kind <kind> --pane <pane_id> -- --model <model>`.
   - One short note distinguishing the two levers: the driver model is a launch flag from `orch8.config`; planning elevation is a file copied per worktree (`skills/orch8/config.tiers/<tier>.local.yaml` -> `<worktree>/.compound-engineering/config.local.yaml`) that tunes how the pipeline plans inside that pane. If no tier file exists, orch8 prints `! no tier config <path-to-config.tiers>/<tier>.local.yaml — pane will inherit repo config.yaml` (the full resolved path, not just the filename) and the pane inherits the repo's own config. Do not reproduce the README lever table.
   - `prompt`: appended verbatim to the ship command: `herdr agent prompt <name> "<ship_cmd> <prompt>"`.
   - Config resolution order for `orch8.config` itself (supporting R5): `--config FILE`, then `$ORCH8_CONFIG`, then `./orch8.config`, then the `orch8.config` next to `orch8.sh`. Missing file or missing key falls back to the built-in defaults named above.

3. **Step 2: Dry-run (R4).**
   - Command: `bash skills/orch8/orch8.sh units.tsv`.
   - State the guarantee: default mode, creates no worktrees, splits no panes, starts no agents.
   - Show what it prints: the header (`orch8: repo=<repo> base=<base> kind=<kind> worktrees=<dir> mode=DRY-RUN` and `orch8: decompose=<cmd> ship=<cmd>`), then per unit the exact commands it would run (`git worktree add -b <branch> <worktree-path> <base>`, the `cp` of the tier config when the file exists, `herdr pane split --current --direction <dir> --cwd <worktree> --no-focus`, `herdr agent start ...`, `herdr agent prompt ...`), then the footer `orch8: N unit(s) planned (dry-run — rerun with --go to launch).`
   - Tell the reader what to check before proceeding: unit count, sanitized names, base branch, worktree root, and the model per unit.
   - List the composable flags with defaults in one line each: `--repo DIR` (`$PWD`), `--base BRANCH` (current branch of the resolved repo), `--kind KIND` (`worker_kind`, default `claude`), `--worktrees DIR` (`<parent-of-repo-root>/orch8-worktrees`), `--config FILE`. Mention `-h`/`--help`.

4. **Step 3: Launch with `--go` (R4).**
   - Command: `bash skills/orch8/orch8.sh units.tsv --go`.
   - Preconditions, checked only when `--go` is passed: `herdr` on PATH, `jq` on PATH, `$HERDR_PANE_ID` set (run it from inside a Herdr pane). Script exits 1 with a message if any is missing.
   - What happens per unit: worktree created, tier config copied, pane split (`--no-focus`, so the orchestrating pane keeps focus), agent started at the tier's model, ship prompt sent.
   - Failure behavior: if the pane split returns no pane ID, that unit is skipped with `! pane split gave no pane_id; skipping <name>`; it is never launched blind.
   - Success footer: `orch8: N unit(s) launched.` followed by the `track:` line.
   - Safety callout: `--go` starts autonomous agents that open PRs. Read the dry-run output first. orch8 never closes a workspace, tab, pane, or worktree it did not create.

5. **Step 4: Track the panes (R6).**
   - `herdr agent list` — see every agent and pane.
   - `herdr agent wait <name> --until done` — block until one unit finishes. Use `--timeout <ms>` so a hung pane doesn't block the walkthrough forever; treat a timeout the same as a stalled unit and send it to Step 5.
   - `herdr agent read <name> --source recent-unwrapped` — read a unit's transcript.
   - Define done: each pane's ship command is expected to open its own PR. A unit is done when it has an open PR or is reported stalled/blocked with its transcript. If `wait` returns with neither — no PR and no stalled/blocked report — treat that as ambiguous, not done: read the transcript with `herdr agent read` before deciding whether to gate/escalate it.
   - Worked example using the names from the Step 1 TSV (e.g. `herdr agent wait rate-limiter --until done`).

6. **Step 5: Gate and escalate (R6).**
   - Review each PR (CI plus code review).
   - If a unit stalled, or a `grind` pane produced weak code: bump that unit's tier to `hard` in `units.tsv`, and re-run orch8 with just that line (dry-run first, then `--go`). Note that `orch8.sh` always creates a fresh worktree and branch for a unit's sanitized name — if the original run already created `orch8/<name>` and its worktree, remove or rename that worktree/branch (or give the retried line a new `id`) before re-running, since the script does not detect or reuse an existing one.

**Patterns to follow.** Mirror the concrete, example-driven style of the Quickstart section in `README.md`: fenced command blocks, a real TSV, actual printed output, short imperative sentences. Task-ordered, not topic-ordered (KTD2). Every path repo-relative. Capture the dry-run and `--go` output shown in the doc by actually running `bash skills/orch8/orch8.sh` against the worked-example `units.tsv` (dry-run only — never `--go`) and copying the literal output, rather than hand-transcribing it from `orch8.sh`'s source; a transcribed guess risks missing a shell interpolation (this plan's own review caught one: the tier-config warning interpolates a full path, not a bare filename). When `orch8.sh`, `orch8.config`, `SKILL.md`, and `README.md` disagree on a behavior, `orch8.sh`'s actual behavior (confirmed by running it) is authoritative — the other three are descriptive, not the source of truth.

**Test Scenarios.** Test expectation: none -- pure documentation addition, no executable behavior change.

**Verification.** `docs/USAGE.md` exists and covers all four required topics accurately against `skills/orch8/orch8.sh`, `skills/orch8/orch8.config`, `skills/orch8/SKILL.md`, and `README.md`. `README.md` and every other existing file remain byte-for-byte unchanged.

---

## Verification Contract

- `git status --porcelain` shows `docs/USAGE.md` added, alongside this plan document under `docs/plans/`; no other, pre-existing file is modified or deleted. (`git diff --stat` alone does not prove this — an untracked file does not appear in a plain diff.)
- Read-through cross-check of every command, flag, default, printed string, and behavior claim in `docs/USAGE.md` against `skills/orch8/orch8.sh` (header comment, `sanitize()`, `model_for()`, dry-run and `--go` branches, footers) and `skills/orch8/orch8.config` (`tiers` map, key defaults) — the two sources of truth. Also confirm nothing in `docs/USAGE.md` traces only to `skills/orch8/SKILL.md` or `README.md` without matching `orch8.sh`'s actual behavior; those two are convenience sources, not authoritative.
- Confirm the dry-run and `--go` output shown in the doc was captured by actually running the worked-example TSV through `bash skills/orch8/orch8.sh` in dry-run mode, not hand-transcribed.
- Confirm the four required topics are each present and correct: TSV format with worked example (R3), dry-run vs `--go` with preconditions and skip behavior (R4), tier-to-model table plus the lever distinction (R5), tracking commands plus gate/escalate (R6).
- Confirm the doc is a walkthrough, not a README restatement: sections follow the run sequence (KTD2) and the architecture pitch is limited to one orientation paragraph (R1).
- The repo test suite (`tests/run.sh`) exercises the script's fan-out behavior against stub `herdr` and `git`. A docs-only change does not affect it; no test run is required for this change.

---

## Definition of Done

- `docs/USAGE.md` exists and accurately documents the `units.tsv` format, dry-run vs `--go`, tier-to-driver-model mapping, and Herdr pane tracking with gate/escalate.
- No other file in the repo was created, modified, or deleted.
- The walkthrough is example-driven and concrete: a worked TSV, exact commands, actual printed output, ordered by the operator's run sequence, and not a restatement of `README.md`.
