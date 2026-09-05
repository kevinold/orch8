---
name: orch8
description: Orchestrate a goal into independent units and fan them out as tiered Herdr panes, each running a ship command to its own PR. Use when running inside Herdr and you want parallel, cost-tiered autonomous builds across worktrees. Not for single-unit work (just run the ship command) or when Herdr is not present.
---

# orch8 — tiered Herdr fan-out

Decompose a goal into independent units, then launch one Herdr pane per unit — each in its own git worktree, on a driver model matched to the unit's difficulty, running the ship command end-to-end to its own PR. The orchestrator pane (this one) stays on a strong model; the workers run cheap.

**Goal:** N independent units → N tiered Herdr panes → N parallel PRs, coordinated from here.
**Done:** every unit either has an open PR or is reported as stalled/blocked with its transcript.
**Safe failure:** dry-run and confirm before launching; never close panes/worktrees you did not create.

## Preconditions

- Running inside Herdr: `$HERDR_PANE_ID` is set, and `herdr` + `jq` + `git` are on PATH.
- A worker pipeline is installed for the worker kind, providing a **decompose** command and a **ship** command. Defaults are compound-engineering on Claude: `/ce-plan` and `/lfg`. Override in `orch8.config` (see below). `herdr agent` lists installed kinds.
- You have a goal to build with more than one independent unit. One unit → just run the ship command, skip orch8.

## Configuration

`orch8.config` sits next to `orch8.sh`. Every key is optional; the values below are the built-in defaults, so orch8 works unchanged with no config file at all.

```yaml
decompose_cmd: /ce-plan       # command this pane runs to produce the units
ship_cmd: /lfg                # command each worker pane runs: plan -> work -> review -> PR
worker_kind: claude           # herdr agent --kind (claude|codex|omp|gemini|...)
herdr_split_direction: right  # herdr pane split --direction
tiers:                        # tier -> driver model
  hard: opus
  grind: sonnet
  trivial: haiku
```

Lookup order: `--config FILE`, then `$ORCH8_CONFIG`, then `./orch8.config`, then the `orch8.config` beside `orch8.sh`. A tier with no entry in the map is used verbatim as the model name, so `hard`/`grind`/`trivial` are conventions, not a closed set.

## Steps

1. **Decompose.** Run the configured `decompose_cmd` (default `/ce-plan`) on the goal. From its implementation units, pick the ones that are genuinely **independent** (each shippable without the others). Assign each a **tier** by difficulty/risk: `hard` (architectural), `grind` (well-specified), `trivial` (mechanical). Write them to a TSV — `<id>\t<tier>\t<prompt>` — one line per unit; the prompt is what that pane hands the ship command.

2. **Preview (dry-run).** Run the bundled script in dry-run and show the user the planned fan-out (worktrees, tiers, driver models, panes). This spawns autonomous agents that open PRs, so **get explicit confirmation before firing.** Set `SKILL_DIR` in the same command:

   ```bash
   SKILL_DIR="<absolute path of the directory containing this SKILL.md>";
   bash "$SKILL_DIR/orch8.sh" units.tsv
   ```

3. **Fire.** On confirmation, rerun with `--go`:

   ```bash
   SKILL_DIR="<absolute path of the directory containing this SKILL.md>";
   bash "$SKILL_DIR/orch8.sh" units.tsv --go
   ```

4. **Track.** `herdr agent list`; `herdr agent wait <name> --until done --timeout <ms>`; `herdr agent read <name> --source recent-unwrapped` for a transcript. Each pane's ship command opens its own PR.

5. **Gate.** Review each PR (CI + a code review pass). If a unit stalled or a grind pane produced weak code, escalate: relaunch that one on the `hard` tier (bump its line in the TSV) and re-run just that unit.

## The two per-pane levers (don't conflate them)

- **Driver model = a launch flag.** `orch8.sh` sets it from the tier via `herdr agent start … -- --model <model>`, using the `tiers` map in `orch8.config`. It is not a pipeline config key.
- **Elevation / worker-engine = per-worktree `config.local.yaml`.** `orch8.sh` copies `config.tiers/<tier>.local.yaml` into each worktree at `.compound-engineering/config.local.yaml`. Compound-engineering resolves config from `git rev-parse --show-toplevel`, which in a worktree is that worktree's root — so each pane reads its own tier. `config.local.yaml` is checkout-local, so it's written fresh per worktree.

## Safety

- Default is dry-run; `--go` is deliberate. Confirm the unit list and tiers with the user before `--go`.
- Use `--no-focus` (the script does) so the user's pane keeps focus.
- Parse all Herdr IDs from JSON (`.result.pane.pane_id`), never guess them.
- Do not close workspaces/tabs/panes/worktrees you did not create.

## Notes

- `orch8.sh` uses `git worktree add` + `herdr pane split --cwd`. Herdr also has `herdr worktree create` (native worktree workspaces) — a future integration option if you want Herdr to track the worktrees.
- Worker kind is configurable (`worker_kind`, or `--kind codex|omp|…`) — orch8 orchestrates any agent Herdr supports; `claude` is the default.
