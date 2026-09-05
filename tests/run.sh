#!/usr/bin/env bash
# orch8 test suite. Runs orch8.sh against stub `git` and `herdr` executables on
# PATH — it never touches a real repository and never talks to a real Herdr.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/orch8"
ORCH8="$SKILL_DIR/orch8.sh"
UNITS="$TESTS_DIR/fixtures/units.tsv"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="$TESTS_DIR/stubs:$PATH"
export ORCH8_TEST_REPO_ROOT="$WORK/fake-repo"
export ORCH8_TEST_BRANCH="main"
WT="$WORK/worktrees"

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"; printf '   expected: %s\n   actual:   %s\n' "$3" "$2"; fi; }

# Normalise machine-specific paths so the golden file is portable.
normalise() { sed -e "s|$SKILL_DIR|<SKILL>|g" -e "s|$WORK|<WORK>|g"; }

echo "== dry-run matches the golden output =="
export ORCH8_TEST_LOG="$WORK/dry.log"; : > "$ORCH8_TEST_LOG"
bash "$ORCH8" "$UNITS" --repo "$ORCH8_TEST_REPO_ROOT" --worktrees "$WT" \
  | normalise > "$WORK/dry.out"
if diff -u "$TESTS_DIR/golden/dry-run.txt" "$WORK/dry.out"; then
  ok "dry-run output"
else
  fail "dry-run output differs from tests/golden/dry-run.txt"
fi

echo "== dry-run is inert: no herdr calls, no worktrees =="
check "no herdr invoked" "$(grep -c '^herdr' "$ORCH8_TEST_LOG" || true)" "0"
check "no worktree created" "$( [ -d "$WT" ] && echo present || echo absent )" "absent"
check "no git worktree add" "$(grep -c 'worktree add' "$ORCH8_TEST_LOG" || true)" "0"

echo "== --go refuses to run outside a Herdr pane =="
export ORCH8_TEST_LOG="$WORK/nopane.log"; : > "$ORCH8_TEST_LOG"
set +e
out="$(env -u HERDR_PANE_ID bash "$ORCH8" "$UNITS" --repo "$ORCH8_TEST_REPO_ROOT" \
        --worktrees "$WT" --go 2>&1)"; rc=$?
set -e
check "exit code" "$rc" "1"
case "$out" in *"not inside a Herdr pane"*) ok "error message";; *) fail "error message: $out";; esac
check "no herdr invoked" "$(grep -c '^herdr' "$ORCH8_TEST_LOG" || true)" "0"

echo "== --go issues pane split -> agent start -> agent prompt per unit, in order =="
export ORCH8_TEST_LOG="$WORK/go.log"; : > "$ORCH8_TEST_LOG"
HERDR_PANE_ID="pane-orchestrator" bash "$ORCH8" "$UNITS" \
  --repo "$ORCH8_TEST_REPO_ROOT" --worktrees "$WT" --go > "$WORK/go.out"

herdr_seq="$(grep '^herdr' "$ORCH8_TEST_LOG" | awk '{print $2" "$3}')"
expected_seq="$(printf 'pane split\nagent start\nagent prompt\n%.0s' 1 2 3 4)"
check "herdr call sequence" "$herdr_seq" "$expected_seq"

check "one worktree per unit" \
  "$(grep -c 'worktree add' "$ORCH8_TEST_LOG" || true)" "4"
check "driver models" \
  "$(grep '^herdr agent start' "$ORCH8_TEST_LOG" | sed 's/.*--model //' | tr '\n' ' ')" \
  "opus sonnet haiku sonnet-1m "
check "pane ids come from the JSON, not guesses" \
  "$(grep '^herdr agent start' "$ORCH8_TEST_LOG" | sed 's/.*--pane \([^ ]*\).*/\1/' | tr '\n' ' ')" \
  "pane-1 pane-2 pane-3 pane-4 "
check "ship command is prefixed to each prompt" \
  "$(grep -c '^herdr agent prompt [^ ]* /lfg ' "$ORCH8_TEST_LOG" || true)" "4"
landed=0
for u in auth-unit rate-limiter copy-tweak; do
  [ -f "$WT/$u/.compound-engineering/config.local.yaml" ] && landed=$((landed+1))
done
check "tier config landed in each worktree" "$landed" "3"

echo "== orch8.config overrides the defaults =="
cat > "$WORK/custom.config" <<'CFG'
decompose_cmd: /plan-it
ship_cmd: /build-it      # trailing comments are stripped
worker_kind: codex
herdr_split_direction: down
tiers:
  hard: gpt-5-codex
  grind: gpt-5-mini
CFG
export ORCH8_TEST_LOG="$WORK/cfg.log"; : > "$ORCH8_TEST_LOG"
cfg_out="$(bash "$ORCH8" "$UNITS" --repo "$ORCH8_TEST_REPO_ROOT" --worktrees "$WT" \
            --config "$WORK/custom.config")"
for expect in "decompose=/plan-it ship=/build-it" "kind=codex" "model=gpt-5-codex" \
              "model=gpt-5-mini" "--direction down" "\"/build-it Fix the footer copy\""; do
  case "$cfg_out" in *"$expect"*) ok "config: $expect";; *) fail "config: $expect not in output";; esac
done
# a tier the custom map omits keeps its built-in default
case "$cfg_out" in *"tier=trivial model=haiku"*) ok "config: omitted tier keeps its default";;
  *) fail "config: omitted tier keeps its default";; esac
# a tier nobody maps is used verbatim as the model name
case "$cfg_out" in *"tier=sonnet-1m model=sonnet-1m"*) ok "config: unmapped tier is verbatim";;
  *) fail "config: unmapped tier is verbatim";; esac

echo "== no orch8.config anywhere: built-in defaults still apply =="
# Copy orch8.sh alone (no orch8.config beside it, no config.tiers) so nothing can
# be read from disk and only the hardcoded defaults are left.
mkdir -p "$WORK/bare" && cp "$ORCH8" "$WORK/bare/orch8.sh"
export ORCH8_TEST_LOG="$WORK/def.log"; : > "$ORCH8_TEST_LOG"
def_out="$(cd "$WORK/bare" && bash "$WORK/bare/orch8.sh" "$UNITS" \
  --repo "$ORCH8_TEST_REPO_ROOT" --worktrees "$WT" 2>&1)"
for expect in "decompose=/ce-plan ship=/lfg" "kind=claude" "tier=hard model=opus" \
              "tier=grind model=sonnet" "tier=trivial model=haiku"; do
  case "$def_out" in *"$expect"*) ok "default: $expect";; *) fail "default: $expect not in output";; esac
done

echo
if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
