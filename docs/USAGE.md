# Using orch8

orch8 fans a goal out into independent units and launches one [Herdr](https://herdr.dev) pane per unit — each in its own git worktree, on a driver model matched to that unit's tier, running a ship command (default `/lfg`) end-to-end to its own PR. It needs Herdr plus a worker pipeline: a decompose command that turns a goal into units, and a ship command each pane runs.

This is a step-by-step walkthrough of running it. For the architecture pitch, install steps, and full configuration reference, see [README.md](../README.md).

## Step 1: Write `units.tsv`

Decompose your goal (with your configured `decompose_cmd`, default `/ce-plan`) into implementation units, keep only the ones that are genuinely independent, and write one tab-separated line per unit:

```tsv
<id>	<tier>	<prompt>
```

Blank lines and lines starting with `#` are skipped. Example:

```tsv
# id           tier     prompt
auth-device-flow	hard	Add the OAuth device authorisation flow
rate-limiter	grind	Add a token-bucket limiter to the public API
footer-copy	trivial	Fix the footer copy and the trailing comma
```

**`id`** is sanitized into a valid Herdr agent name: lowercased, any character outside `[a-z0-9_-]` becomes `-`, a `u-` prefix is added if it doesn't start with a letter, and it's truncated to 32 characters. That sanitized name is reused as the branch suffix (`orch8/<name>`) and the worktree directory name — so pick ids that stay distinct after sanitizing (`Foo` and `foo` collide, and so can two long ids that agree on their first 32 characters). A collision means the two units would share one branch, worktree, and tracking handle.

**`tier`** selects the driver model via the `tiers` map in `orch8.config`:

| Tier | Driver model |
|------|--------------|
| `hard` | `opus` |
| `grind` | `sonnet` |
| `trivial` | `haiku` |

A tier with no entry in the map is passed to Herdr **verbatim as the model name** — `hard`/`grind`/`trivial` are a convention, not a closed set. The tier also picks a *second*, separate thing: `orch8.sh` copies `config.tiers/<tier>.local.yaml` into `<worktree>/.compound-engineering/config.local.yaml`, which tunes how hard the worker pipeline *plans* inside that pane (independent of which model *drives* it). If no file exists for a tier, orch8 prints a warning naming the full path it looked for and the pane just inherits the repo's own `config.yaml`:

```
! no tier config /work/app/skills/orch8/config.tiers/<tier>.local.yaml — pane will inherit repo config.yaml
```

**`prompt`** is appended verbatim to the ship command when the pane is launched: `herdr agent prompt <name> "<ship_cmd> <prompt>"`.

**Config file for `orch8.config` itself:** `--config FILE`, else `$ORCH8_CONFIG`, else `./orch8.config`, else the `orch8.config` shipped next to `orch8.sh`. A missing file or a missing key falls back to the built-in defaults shown above.

## Step 2: Dry-run

Dry-run is the default — nothing is created, nothing is launched:

```bash
bash skills/orch8/orch8.sh units.tsv
```

```
orch8: repo=/work/app base=main kind=claude worktrees=/work/orch8-worktrees mode=DRY-RUN
orch8: decompose=/ce-plan ship=/lfg

[auth-device-flow] tier=hard model=opus  ->  /work/orch8-worktrees/auth-device-flow  (orch8/auth-device-flow)
  git worktree add -b orch8/auth-device-flow /work/orch8-worktrees/auth-device-flow main
  cp /work/app/skills/orch8/config.tiers/hard.local.yaml /work/orch8-worktrees/auth-device-flow/.compound-engineering/config.local.yaml
  herdr pane split --current --direction right --cwd /work/orch8-worktrees/auth-device-flow --no-focus   # -> pane_id
  herdr agent start auth-device-flow --kind claude --pane <pane_id> -- --model opus
  herdr agent prompt auth-device-flow "/lfg Add the OAuth device authorisation flow"

[rate-limiter] tier=grind model=sonnet  ->  /work/orch8-worktrees/rate-limiter  (orch8/rate-limiter)
  ...

[footer-copy] tier=trivial model=haiku  ->  /work/orch8-worktrees/footer-copy  (orch8/footer-copy)
  ...

orch8: 3 unit(s) planned (dry-run — rerun with --go to launch).
```

Dry-run creates no worktrees, splits no panes, and starts no agents — it only prints what it would do. Before going further, check: the unit count, the sanitized names, the base branch, the worktree root, and the driver model chosen per unit.

Useful flags (all work in dry-run too): `--repo DIR` (default `$PWD`), `--base BRANCH` (default: current branch of the resolved repo), `--kind KIND` (default `worker_kind` from config, `claude`), `--worktrees DIR` (default `<parent-of-repo-root>/orch8-worktrees`), `--config FILE`. Run `orch8.sh -h` for the full usage line.

## Step 3: Fire with `--go`

Only `--go` mutates anything:

```bash
bash skills/orch8/orch8.sh units.tsv --go
```

`--go` additionally requires `herdr` and `jq` on PATH, and `$HERDR_PANE_ID` set — it refuses to run outside a Herdr pane. For each unit it then: creates the git worktree, copies that tier's config file into the worktree, splits a Herdr pane (`--no-focus`, so your pane keeps focus), starts the agent at the tier's driver model, and sends it the ship prompt. Pane IDs are parsed from Herdr's JSON, never guessed — a unit whose pane split returns no ID is skipped (`! pane split gave no pane_id; skipping <name>`) rather than launched blind.

```
orch8: 3 unit(s) launched.
track: herdr agent list ; herdr agent wait <name> --until done ; herdr agent read <name> --source recent-unwrapped
```

`--go` starts autonomous agents that open pull requests — read the dry-run output first. orch8 never closes a workspace, tab, pane, or worktree it did not create.

## Step 4: Track the panes

- `herdr agent list` — see every agent and pane orch8 started.
- `herdr agent wait <name> --until done --timeout <ms>` — block until one unit finishes. Always pass `--timeout`, so a hung pane doesn't block you forever; treat a timeout the same as a stalled unit and move it to Step 5.
- `herdr agent read <name> --source recent-unwrapped` — read a unit's transcript.

A unit's ship command is expected to open its own PR, so a unit is **done** once it has an open PR, or is reported stalled/blocked (read its transcript to see why). If `wait` returns with neither — no PR and no stalled/blocked report — that's ambiguous, not done: read the transcript before deciding what to do with it.

```bash
herdr agent wait rate-limiter --until done --timeout 1800000
herdr agent read rate-limiter --source recent-unwrapped
```

## Step 5: Gate and escalate

Review each PR — CI plus a code review pass. If a unit stalled, or a `grind` pane produced weak code, escalate it: bump that unit's tier to `hard` in `units.tsv` and re-run orch8 with just that one line (dry-run first, then `--go`).

`orch8.sh` always creates a fresh worktree and branch for a unit's sanitized name — it does not detect or reuse an existing one. If the original run already created `orch8/<name>` and its worktree, remove or rename that worktree/branch first, or give the retried line a new `id`, before re-running.
