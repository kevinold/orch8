---
title: Reliable Trust-Prompt Handling in orch8 --go Launch - Plan
type: fix
date: 2026-09-05
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Reliable Trust-Prompt Handling in orch8 --go Launch - Plan

## Goal Capsule

- Objective: unattended `orch8.sh --go` fan-outs no longer die on Claude Code's first-run trust dialog. Every unit reaches the existing `herdr agent prompt` call alive.
- Means: guard `herdr agent start`, poll the new pane with `herdr pane read` for the trust text, answer with `down` + `enter` only when seen, confirm `working` with `herdr agent wait`, resend once if not, then fall through to `agent prompt` unchanged.
- Authority: the three session-settled decisions (Scope Boundaries; KTD2; KTD3) are fixed input. Stop conditions: any change outside `skills/orch8/orch8.sh`, any README edit, any new file, flag, or config key.
- Execution profile: Lightweight. One implementation unit. Manual shell verification only; no test harness exists for this script.

## Product Contract

### Summary

`skills/orch8/orch8.sh --go` launches Claude Code in a freshly created git worktree per unit. Claude Code shows a one-time trust dialog in that directory, and today the script does nothing about it. This change adds a bounded poll-answer-confirm step between `herdr agent start` and `herdr agent prompt`, and makes `agent start` non-fatal so that step always gets to run.

### Problem Frame

The trust dialog's cursor defaults to "No, exit". Herdr reports a dialog-blocked agent as `agent_not_ready` from `agent start`, and `agent prompt` rejects a blocked agent with `agent_blocked`. Under `set -euo pipefail` either result aborts the whole fan-out; a blind `enter` kills the agent instead. The script must see the dialog, answer it correctly, and verify the answer took.

### Requirements

- R1. `herdr agent start` must not abort the script when it exits non-zero. Its outcome is echoed and the unit continues into trust handling.
- R2. Before any key is sent, the script polls the unit's pane with `herdr pane read` for the trust-dialog text. The poll is bounded by a short timeout with a short sleep between reads.
- R3. `down` then `enter` are sent with `herdr agent send-keys` only after the trust text is seen. A poll that times out without a match sends nothing.
- R4. After answering, the script confirms the agent left the blocked dialog state — reaching `working` or `idle`, both of which mean the dialog is answered — with `herdr agent wait --until working --until idle` under a short timeout.
- R5. If that confirmation times out, the script resends `down` + `enter` exactly once and confirms once more. It never loops further.
- R6. Every path (dialog seen or not, confirmation passed or not) falls through to the existing `herdr agent prompt "$name" "$SHIP_CMD $prompt"` call, unchanged.
- R7. Dry-run (`GO=0`) keeps echoing only. It prints one additional preview line for the trust step and still never invokes herdr.
- R8. No new herdr call is fatal under `set -e`. The existing `agent prompt` call stays the single fatal checkpoint per unit, so a genuinely dead agent still surfaces there as it does today.
- R9. Only `skills/orch8/orch8.sh` changes.

### Scope Boundaries

Single file. No README edits, no tests, no config keys, no flags, no new files (session-settled: user-directed — chosen over also updating the README: the user explicitly scoped this task to one file and said not to edit the README).

## Planning Contract

### Key Technical Decisions

- KTD1. Guard the `agent start` exit status. `agent start` returns `agent_not_ready` (JSON error, exit 1) when Herdr's startup-readiness check finds the agent blocked, which is exactly the trust-dialog case. Left unguarded under `set -euo pipefail`, that exit aborts the entire multi-unit fan-out before any trust handling runs. Wrap the call in `if ! herdr agent start ...; then echo "..." >&2; fi` so the status is visible but non-fatal. Herdr keeps the agent name addressable for `pane read`, `send-keys`, and `agent wait` regardless of how `agent start` reported. Apply the same rule to every new herdr call (`|| true` or an `if` guard). Genuine launch failures (bad pane, bad kind) still surface at the unchanged, fatal `agent prompt`.
- KTD2. Detect the dialog with a bounded `herdr pane read` loop, not `herdr pane wait-output` (session-settled: user-directed — chosen over blind-firing down+enter immediately after launch: blind-firing hits the default "No, exit" before the dialog renders, killing the agent). Shape: up to `TRUST_POLL_SECS` iterations of `herdr pane read "$pane_id" --source recent-unwrapped --lines 40` with `sleep 1` between them. Use `recent-unwrapped` so soft-wrapped dialog lines are joined and the phrase cannot straddle a line break. Capture the read into a variable with `|| true` (a failed read is simply "no match") and test it with a here-string (`grep -q ... <<<"$out"`) rather than a `cmd | grep -q` pipeline, because `grep -q` can close the pipe early and `pipefail` then reports a real match as failure. `pane wait-output` is a built-in equivalent; this plan keeps `pane read` because the task named it explicitly. An already-trusted worktree pays the full poll window once per unit, which is bounded and acceptable.
- KTD3. Confirm the transition with `herdr agent wait "$name" --until working --until idle --timeout "$TRUST_CONFIRM_MS"`, and resend once on timeout (session-settled: user-directed — chosen over fire-and-forget with no confirmation: a single blind attempt can be swallowed or mistimed). `agent wait` is the herdr primitive that expresses "block until a lifecycle state"; no hand-rolled `agent get` + `jq` loop. Herdr's `--until` flag repeats to accept multiple target states. Wait for both `working` and `idle`, not `working` alone: herdr's own agent-guide documents that a startup-blocked agent should be waited on until `idle` ("ready for input") once answered, and a freshly-answered trust dialog commonly lands there rather than `working`. Waiting on `working` alone would fire the resend branch on the common case, defeating the point of this confirmation. Discard both waits' JSON stdout, keep stderr. Both wait calls are non-fatal.
- KTD4. Match the trust text case-insensitively with the extended regex `trust.*this folder`. The user-named phrase is `trust this folder`; the dialog wording known from research is "Do you trust the files in this folder?", which does not contain that literal substring. The regex matches both wordings on one unwrapped line.
- KTD5. Send exactly `down` then `enter` in one call: `herdr agent send-keys "$name" down enter`. Both are valid key names; `down` was empirically verified. The target is the agent name, not the pane id.
- KTD6. Timing lives in two plain script constants beside the existing top-of-script settings: `TRUST_POLL_SECS=10` and `TRUST_CONFIRM_MS=10000`. They are not env-overridable and not config keys. Ten seconds is enough because `agent start` has already waited up to 30s for readiness, so any dialog that is going to appear has rendered by the time polling starts.

### Flagged Risks

- Dialog default. Research states the cursor defaults to "No, exit", so `down` + `enter` selects "Yes, proceed". Smoke scenario (a) must confirm the pane shows Claude Code's normal prompt after the answer, not an exited process.
- Loop stdin. The per-unit `while read` loop's stdin is the units TSV. The existing herdr calls in the loop do not consume it; keep the new calls (`pane read`, `send-keys`, `agent wait`, `sleep`) equally stdin-neutral, adding `</dev/null` only if the dry or smoke run shows a unit being skipped.
- Sequencing is unchanged from today's script. `agent start` already blocks synchronously per unit (Herdr's own startup-readiness wait, up to 30s) before this plan's changes; the poll-answer-confirm sequence adds bounded time on top of that same per-unit synchronous step for units that need it, it does not turn a previously concurrent launch loop into a sequential one.

## Implementation Units

### U1. Guard agent start, poll-answer-confirm the trust dialog, update the dry-run preview

**Goal:** in the `[ "$GO" -eq 1 ]` branch, make `agent start` non-fatal and insert the poll, answer, confirm, resend-once sequence before the unchanged `agent prompt`; in the `[ "$GO" -eq 0 ]` branch, echo one extra line describing that sequence.

**Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9.

**Dependencies:** none.

**Files:** `skills/orch8/orch8.sh` (the only file in scope).

**Approach:**
1. Add `TRUST_POLL_SECS=10` and `TRUST_CONFIRM_MS=10000` beside the existing script-level constants (KTD6).
2. In the real-run branch (currently lines ~145-157), wrap `herdr agent start ...` in `if ! ...; then echo "  $name: agent start not ready; checking for trust prompt" >&2; fi` (KTD1).
3. Poll: loop up to `TRUST_POLL_SECS` times. Each iteration captures `herdr pane read "$pane_id" --source recent-unwrapped --lines 40 2>/dev/null || true` into a variable, tests it with `grep -qiE 'trust.*this folder' <<<"$out"`, breaks with `seen=1` on match, otherwise `sleep 1` (KTD2, KTD4).
4. If `seen=1`: `herdr agent send-keys "$name" down enter || true` (KTD5).
5. Confirm: `if ! herdr agent wait "$name" --until working --until idle --timeout "$TRUST_CONFIRM_MS" >/dev/null; then` resend `down enter` once and run one more non-fatal `agent wait`; `fi` (KTD3).
6. Fall through to the existing `herdr agent prompt "$name" "$SHIP_CMD $prompt"` line, untouched (R6).
7. In the dry-run branch (currently lines ~135-143), add one `echo "  ..."` line between the `agent start` and `agent prompt` previews, for example `herdr pane read <pane> (poll ${TRUST_POLL_SECS}s for trust prompt) -> herdr agent send-keys $name down enter -> herdr agent wait $name --until working --until idle` (R7).

Directional shape of steps 2-6 (guidance for the implementer, not the literal diff):

```bash
if ! herdr agent start "$name" --kind "$KIND" --pane "$pane_id" -- --model "$model"; then
  echo "  $name: agent start not ready; checking for trust prompt" >&2
fi

seen=0; i=0
while [ "$i" -lt "$TRUST_POLL_SECS" ]; do
  out="$(herdr pane read "$pane_id" --source recent-unwrapped --lines 40 2>/dev/null || true)"
  if grep -qiE 'trust.*this folder' <<<"$out"; then seen=1; break; fi
  sleep 1; i=$((i + 1))
done

if [ "$seen" -eq 1 ]; then
  herdr agent send-keys "$name" down enter || true
  if ! herdr agent wait "$name" --until working --until idle --timeout "$TRUST_CONFIRM_MS" >/dev/null; then
    herdr agent send-keys "$name" down enter || true
    herdr agent wait "$name" --until working --until idle --timeout "$TRUST_CONFIRM_MS" >/dev/null || true
  fi
fi

herdr agent prompt "$name" "$SHIP_CMD $prompt"   # existing line, unchanged
```

**Patterns to follow:** leave `set -euo pipefail` untouched and make every new command safe under it. Small `while` loop with `[ ]` tests; the here-string is the one bash-ism and bash is already implied by `pipefail`. One inline comment only where the why is non-obvious (the here-string versus `| grep -q` reason). Dry-run uses the existing two-space `echo "  ..."` convention. Diagnostics go to stderr like the guard message.

**Test scenarios:** No automated test harness exists for this script; each scenario below is verified manually (`bash -n`, `shellcheck`, dry-run, and an optional live `--go` smoke run).
- (a) Fresh worktree, dialog appears: poll matches, `down` + `enter` selects "Yes, proceed", `agent wait` returns, `agent prompt` is accepted, the agent runs the ship command.
- (b) Already-trusted worktree, no dialog: poll runs the full window, sends nothing, script proceeds to `agent prompt` exactly as before.
- (c) First `down` + `enter` does not register: first `agent wait` times out, resend fires, second wait returns, `agent prompt` is accepted.
- (d) `agent start` returns `agent_not_ready` because the dialog is already up: script logs it, does not abort, and the poll matches on the first read.
- (e) Dry-run with a two-unit sample TSV: each unit prints the extra preview line, nothing else changes, herdr is never called.

**Verification:** `bash -n skills/orch8/orch8.sh`; `shellcheck skills/orch8/orch8.sh` if installed with no new findings; dry-run against a sample TSV; `git diff --stat` lists only `skills/orch8/orch8.sh`.

## Verification Contract

- Syntax: `bash -n skills/orch8/orch8.sh` exits 0.
- Lint: `shellcheck skills/orch8/orch8.sh` if available; no new findings versus the pre-change baseline.
- Dry-run: write a two-line sample units.tsv in the scratch directory, run `./skills/orch8/orch8.sh <sample.tsv>` without `--go`, and confirm each unit's preview shows the new poll/send-keys/wait line between `agent start` and `agent prompt`. The dry-run branch needs no herdr on PATH; confirm nothing was launched.
- Scope: `git diff --stat` lists exactly one file.
- Optional live smoke (user's choice, inside a Herdr session): one unit with `--go` against a fresh worktree covers scenarios (a) and (d); rerunning against the now-trusted worktree covers (b). Record the `agent_status` Herdr reports after the answer to confirm it lands in `working` or `idle` as KTD3 expects. Scenario (c) is hard to force and is covered by reading the resend branch.

## Definition of Done

- `skills/orch8/orch8.sh` is the only changed file; README, tests, config, and flags are untouched.
- `agent start` is guarded; no new herdr call can abort the script; `agent prompt` remains unchanged and fatal.
- The poll, answer, confirm, resend-once sequence is present, bounded by `TRUST_POLL_SECS` and `TRUST_CONFIRM_MS`, and sends keys only after a match.
- Dry-run previews the new step and never touches herdr.
- `bash -n` passes, `shellcheck` shows no new findings, dry-run output reviewed.
- Flagged risks (dialog-default direction, loop stdin neutrality) are confirmed benign by the smoke run.
