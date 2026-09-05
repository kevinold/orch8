# orch8

**Tiered fan-out for parallel autonomous builds.** One goal → N independent units → N Herdr panes, each in its own git worktree, on a driver model matched to that unit's difficulty, each running your ship command end-to-end to its own PR.

> [!IMPORTANT]
> **orch8 has a hard dependency on [Herdr](https://herdr.dev).** orch8 does not spawn agents itself — it orchestrates *through* Herdr's CLI (`herdr pane split`, `herdr agent start`, `herdr agent prompt`). Without Herdr installed and running, orch8 is inert.
>
> It also needs a **worker pipeline** — a decompose command and a ship command your worker agents understand. The defaults target [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin) on Claude Code (`/ce-plan` and `/lfg`), and both are configurable.

## Architecture

See **[docs/architecture.html](docs/architecture.html)** for the full diagram — orchestrator pane, decompose step, worktree fan-out, and the two per-pane levers. Open it in a browser; it is a standalone page with no build step.

## Install

**Claude Code (default target)**

```
/plugin marketplace add kevinold/orch8
/plugin install orch8
```

**Any other host**: clone the repo and point your agent at `skills/orch8/`. The skill is a single `SKILL.md` plus one bash script — nothing host-specific outside the frontmatter.

## Quickstart

From a pane inside Herdr, in the repo you want to build in:

1. **Decompose.** Run your decompose command (default `/ce-plan`) on the goal. Take the units that are genuinely independent — each shippable without the others — and write one tab-separated line per unit:

   ```tsv
   auth-device-flow	hard	Add the OAuth device authorisation flow
   rate-limiter	grind	Add a token-bucket limiter to the public API
   footer-copy	trivial	Fix the footer copy and the trailing comma
   ```

   Columns are `<id>`, `<tier>`, `<prompt>`. Blank lines and `#` comments are skipped.

2. **Preview.** Dry-run is the default — nothing is created, nothing is launched:

   ```bash
   bash skills/orch8/orch8.sh units.tsv
   ```

   ```
   orch8: repo=/work/app base=main kind=claude worktrees=/work/orch8-worktrees mode=DRY-RUN
   orch8: decompose=/ce-plan ship=/lfg

   [auth-device-flow] tier=hard model=opus  ->  /work/orch8-worktrees/auth-device-flow  (orch8/auth-device-flow)
     git worktree add -b orch8/auth-device-flow /work/orch8-worktrees/auth-device-flow main
     cp .../config.tiers/hard.local.yaml .../.compound-engineering/config.local.yaml
     herdr pane split --current --direction right --cwd ... --no-focus   # -> pane_id
     herdr agent start auth-device-flow --kind claude --pane <pane_id> -- --model opus
     herdr agent prompt auth-device-flow "/lfg Add the OAuth device authorisation flow"
   ```

3. **Fire.** Only `--go` mutates anything:

   ```bash
   bash skills/orch8/orch8.sh units.tsv --go
   ```

4. **Track.** `herdr agent list` · `herdr agent wait <name> --until done` · `herdr agent read <name> --source recent-unwrapped`. Each pane opens its own PR.

## The two per-pane levers

These are different things and conflating them is the most common orch8 mistake.

| | Driver model | Planning elevation |
|---|---|---|
| **What it is** | Which model *drives* the worker pane | How hard the pipeline *plans* inside that pane |
| **How it's set** | A launch flag: `herdr agent start … -- --model X` | A file: `config.tiers/<tier>.local.yaml` copied to `<worktree>/.compound-engineering/config.local.yaml` |
| **Where it comes from** | The `tiers` map in `orch8.config` | `skills/orch8/config.tiers/` |
| **Why per-worktree works** | — | The pipeline resolves config from `git rev-parse --show-toplevel`, which inside a worktree is that worktree's root, so each pane reads its own tier |

Tier → driver model defaults: `hard` → `opus`, `grind` → `sonnet`, `trivial` → `haiku`. A tier with no entry in the map is used **verbatim as the model name**, so the tier names are a convention, not a closed set.

## Safety

**Dry-run is the default and `--go` is the only way to mutate anything.** In dry-run orch8 creates no worktrees, splits no panes, and starts no agents — it prints exactly what it would do.

- `--go` additionally requires `herdr`, `jq`, and `$HERDR_PANE_ID` — it refuses to run outside a Herdr pane.
- Panes are split with `--no-focus`, so your pane keeps focus.
- Pane IDs are parsed out of Herdr's JSON (`.result.pane.pane_id`), never guessed; a unit whose split returns no ID is skipped rather than launched blind.
- orch8 never closes a workspace, tab, pane, or worktree it did not create.

`--go` starts autonomous agents that open pull requests. Read the dry-run first.

## Configuration

`skills/orch8/orch8.config` — every key optional, defaults shown:

```yaml
decompose_cmd: /ce-plan       # command the orchestrator runs to produce the units
ship_cmd: /lfg                # command each worker pane runs: plan -> work -> review -> PR
worker_kind: claude           # herdr agent --kind (claude|codex|omp|gemini|...)
herdr_split_direction: right  # herdr pane split --direction
tiers:
  hard: opus
  grind: sonnet
  trivial: haiku
```

Lookup order: `--config FILE` → `$ORCH8_CONFIG` → `./orch8.config` → the `orch8.config` beside `orch8.sh`. Missing file or missing key falls back to the built-in default, so orch8 runs unconfigured. Because the pipeline commands and the worker kind are all config, orch8 is not tied to any one coding agent — point it at Codex, omp, or your own pipeline without touching the script.

### Flags

```
orch8.sh <units.tsv> [--go] [--repo DIR] [--base BRANCH] [--kind KIND]
                     [--worktrees DIR] [--config FILE]
```

## Development

```bash
bash tests/run.sh          # fan-out tests against stub herdr + stub git
shellcheck skills/orch8/orch8.sh tests/run.sh tests/stubs/*
```

The suite puts stub `herdr` and `git` executables on PATH, so it never touches a real repository and never talks to a real Herdr. It golden-tests the dry-run output, asserts dry-run is inert, asserts `--go` issues `pane split` → `agent start` → `agent prompt` per unit in that order, and asserts the config overrides and the built-in defaults.

## License

MIT © 2026 Kevin Old
