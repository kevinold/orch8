# Changelog

All notable changes to orch8 are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-05

Initial release.

### Added

- `skills/orch8/` — the canonical skill: `SKILL.md`, `orch8.sh`, and the per-tier
  `config.tiers/{hard,grind,trivial}.local.yaml` worktree configs.
- `orch8.config` — decouples orch8 from any one pipeline or coding agent.
  `decompose_cmd`, `ship_cmd`, `worker_kind`, `herdr_split_direction`, and a
  `tiers` map, every key optional. Defaults are compound-engineering on Claude
  (`/ce-plan`, `/lfg`, `claude`, `right`, `hard=opus grind=sonnet trivial=haiku`),
  so orch8 runs unconfigured.
- `--config FILE` flag; config lookup order `--config` → `$ORCH8_CONFIG` →
  `./orch8.config` → the `orch8.config` beside `orch8.sh`.
- `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` — installable
  as a Claude Code plugin, the default target.
- `docs/architecture.html` — standalone architecture diagram, linked from the README.
- CI: shellcheck, a stubbed-`herdr`/stubbed-`git` test suite (golden dry-run output,
  dry-run inertness, `--go` call ordering, config overrides and defaults), and a
  manifest/frontmatter lint.

### Safety

- Dry-run remains the default. `--go` is required to create worktrees, split panes,
  or start agents, and additionally requires `herdr`, `jq`, and `$HERDR_PANE_ID`.

[0.1.0]: https://github.com/kevinold/orch8/releases/tag/v0.1.0
