#!/usr/bin/env bash
# orch8 — fan out independent units into tiered Herdr panes, each running the ship command to its own PR.
#
# Usage:
#   orch8.sh <units.tsv> [--go] [--repo DIR] [--base BRANCH] [--kind KIND] [--worktrees DIR] [--config FILE]
#
# units.tsv  tab-separated, one unit per line:  <id>\t<tier>\t<prompt>
#            blank lines and lines starting with # are ignored.
# tier -> driver model comes from orch8.config (defaults: hard=opus grind=sonnet trivial=haiku).
#            A tier with no mapping is used verbatim as the model name.
#
# Config: --config FILE, else $ORCH8_CONFIG, else ./orch8.config, else the orch8.config
#         next to this script. Every key is optional; built-in defaults apply when absent.
#
# DEFAULT IS DRY-RUN: prints the planned worktrees/panes/agents without touching anything.
# Pass --go to actually create worktrees, split panes, and launch agents.
#
# Requires: herdr, jq, git. Must run from inside a Herdr pane ($HERDR_PANE_ID set) when --go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIERS_DIR="$SCRIPT_DIR/config.tiers"

# --- defaults (used verbatim when orch8.config is absent or a key is missing) ---
DECOMPOSE_CMD="/ce-plan"
SHIP_CMD="/lfg"
WORKER_KIND="claude"
SPLIT_DIRECTION="right"
# shellcheck disable=SC2034  # read indirectly by model_for() as TIER_<tier>
{ TIER_hard="opus"; TIER_grind="sonnet"; TIER_trivial="haiku"; }

GO=0; REPO="$PWD"; BASE=""; KIND=""; WORKTREES=""; CONFIG=""
UNITS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --go) GO=1;;
    --repo) REPO="$2"; shift;;
    --base) BASE="$2"; shift;;
    --kind) KIND="$2"; shift;;
    --worktrees) WORKTREES="$2"; shift;;
    --config) CONFIG="$2"; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    -*) echo "unknown flag: $1" >&2; exit 2;;
    *) UNITS="$1";;
  esac
  shift
done

# --- config ---------------------------------------------------------------
if [ -z "$CONFIG" ]; then
  for c in "${ORCH8_CONFIG:-}" "$PWD/orch8.config" "$SCRIPT_DIR/orch8.config"; do
    if [ -n "$c" ] && [ -f "$c" ]; then CONFIG="$c"; break; fi
  done
fi
if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 2; }
  # Emits shell assignments for the keys we know; everything else is ignored.
  eval "$(awk '
    function clean(v) {
      sub(/[[:space:]]+#.*$/, "", v); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v); gsub(/'"'"'/, "", v)
      return v
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^tiers:[[:space:]]*(#.*)?$/ { in_tiers = 1; next }
    /^[^[:space:]]/ {
      in_tiers = 0
      i = index($0, ":"); if (i == 0) next
      k = substr($0, 1, i - 1); v = clean(substr($0, i + 1))
      if (v == "") next
      if (k == "decompose_cmd")          printf "DECOMPOSE_CMD='"'"'%s'"'"'\n", v
      else if (k == "ship_cmd")          printf "SHIP_CMD='"'"'%s'"'"'\n", v
      else if (k == "worker_kind")       printf "WORKER_KIND='"'"'%s'"'"'\n", v
      else if (k == "herdr_split_direction") printf "SPLIT_DIRECTION='"'"'%s'"'"'\n", v
      next
    }
    in_tiers && /^[[:space:]]+[A-Za-z0-9_-]+:/ {
      i = index($0, ":")
      k = clean(substr($0, 1, i - 1)); v = clean(substr($0, i + 1))
      if (k ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && v != "") printf "TIER_%s='"'"'%s'"'"'\n", k, v
    }
  ' "$CONFIG")"
fi
[ -n "$KIND" ] || KIND="$WORKER_KIND"

[ -n "$UNITS" ] && [ -f "$UNITS" ] || { echo "need a units.tsv file (see --help)" >&2; exit 2; }

REPO_ROOT="$(git -C "$REPO" rev-parse --show-toplevel)"
[ -z "$BASE" ] && BASE="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
[ -z "$WORKTREES" ] && WORKTREES="$(dirname "$REPO_ROOT")/orch8-worktrees"

model_for() {  # tier -> driver model (from config tiers map; unmapped tier is the model itself)
  local var
  if [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    var="TIER_$1"
    printf '%s' "${!var:-$1}"
  else
    printf '%s' "$1"
  fi
}
sanitize() {  # -> valid herdr agent name: [a-z][a-z0-9_-]{0,31}
  local n; n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  [ "${n:0:1}" = "-" ] || [ -z "$n" ] && n="u-$n"
  case "$n" in [a-z]*) :;; *) n="u-$n";; esac
  printf '%s' "${n:0:32}"
}

if [ "$GO" -eq 1 ]; then
  command -v herdr >/dev/null || { echo "herdr not on PATH" >&2; exit 1; }
  command -v jq    >/dev/null || { echo "jq not on PATH" >&2; exit 1; }
  [ -n "${HERDR_PANE_ID:-}" ] || { echo "not inside a Herdr pane (\$HERDR_PANE_ID unset)" >&2; exit 1; }
fi

echo "orch8: repo=$REPO_ROOT base=$BASE kind=$KIND worktrees=$WORKTREES mode=$([ "$GO" -eq 1 ] && echo GO || echo DRY-RUN)"
echo "orch8: decompose=$DECOMPOSE_CMD ship=$SHIP_CMD"
echo

count=0
while IFS=$'\t' read -r id tier prompt; do
  case "$id" in ''|\#*) continue;; esac
  count=$((count+1))
  name="$(sanitize "$id")"
  model="$(model_for "$tier")"
  branch="orch8/$name"
  wt="$WORKTREES/$name"
  tier_cfg="$TIERS_DIR/$tier.local.yaml"

  echo "[$name] tier=$tier model=$model  ->  $wt  ($branch)"
  if [ ! -f "$tier_cfg" ]; then
    echo "  ! no tier config $tier_cfg — pane will inherit repo config.yaml"
  fi

  if [ "$GO" -eq 0 ]; then
    echo "  git worktree add -b $branch $wt $BASE"
    [ -f "$tier_cfg" ] && echo "  cp $tier_cfg $wt/.compound-engineering/config.local.yaml"
    echo "  herdr pane split --current --direction $SPLIT_DIRECTION --cwd $wt --no-focus   # -> pane_id"
    echo "  herdr agent start $name --kind $KIND --pane <pane_id> -- --model $model"
    echo "  herdr agent prompt $name \"$SHIP_CMD $prompt\""
    echo
    continue
  fi

  git -C "$REPO_ROOT" worktree add -b "$branch" "$wt" "$BASE"
  if [ -f "$tier_cfg" ]; then
    mkdir -p "$wt/.compound-engineering"
    cp "$tier_cfg" "$wt/.compound-engineering/config.local.yaml"
  fi
  pane_id="$(herdr pane split --current --direction "$SPLIT_DIRECTION" --cwd "$wt" --no-focus | jq -r '.result.pane.pane_id')"
  [ -n "$pane_id" ] && [ "$pane_id" != null ] || { echo "  ! pane split gave no pane_id; skipping $name" >&2; continue; }
  herdr agent start "$name" --kind "$KIND" --pane "$pane_id" -- --model "$model"
  herdr agent prompt "$name" "$SHIP_CMD $prompt"
  echo "  started agent '$name' in pane $pane_id"
  echo
done < "$UNITS"

echo "orch8: $count unit(s) $([ "$GO" -eq 1 ] && echo 'launched' || echo 'planned (dry-run — rerun with --go to launch)')."
[ "$GO" -eq 1 ] && echo "track: herdr agent list ; herdr agent wait <name> --until done ; herdr agent read <name> --source recent-unwrapped"
exit 0
