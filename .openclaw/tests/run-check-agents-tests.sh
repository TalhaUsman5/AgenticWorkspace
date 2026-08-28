#!/usr/bin/env bash
# Regression tests for .openclaw/check-agents.sh.
#
# The monitor is the one piece of this workspace that runs unattended with no
# human reading its output, so its control flow is worth pinning down. jq, gh
# and tmux are stubbed (see stubbin/) so the tests run anywhere Node and bash
# exist, including a Windows git-bash checkout.
#
# Usage: bash .openclaw/tests/run-check-agents-tests.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-$TESTS_DIR/../check-agents.sh}"

if [ ! -f "$SCRIPT" ]; then
  echo "cannot find check-agents.sh at $SCRIPT" >&2
  exit 1
fi

chmod +x "$TESTS_DIR"/stubbin/* 2>/dev/null
# Captured before stubbin is prepended, so the "openclaw not installed" test
# can build a PATH with the other stubs but a real gap where openclaw would be.
SYSTEM_PATH="$PATH"
export PATH="$TESTS_DIR/stubbin:$PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
STATE="$HOME/.openclaw/state"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; echo "         expected: $2"; echo "         actual:   $3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

reset_state() { rm -rf "$HOME"; mkdir -p "$STATE"; }

make_worktree() {
  rm -rf "${WORK:?}/$1"; mkdir -p "${WORK:?}/$1"
  git -C "$WORK/$1" init -q
  git -C "$WORK/$1" remote add origin "https://example.com/o/r.git"
  # a branch needs at least one commit before rev-parse --abbrev-ref works
  git -C "$WORK/$1" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  if [ -n "${2:-}" ]; then
    git -C "$WORK/$1" checkout -q -b "$2"
  fi
}

# task_id status attempts prCreated ciPassed reviewPassed shotsIncluded worktree [startedAt]
write_state() {
  local started="${9:-}"
  cat > "$STATE/$1.json" <<EOF
{"status":"$2","session":"aw-$1","project":"p","worktree":"$8","attempts":$3,
 "checks":{"prCreated":$4,"ciPassed":$5,"claudeReviewPassed":$6,"uiScreenshotsIncluded":$7}${started:+,\"startedAt\":\"$started\"}}
EOF
}

HISTORY="$HOME/.openclaw/run-history.jsonl"

# Reads field $2 out of history line number $1 (1-indexed). Goes through
# Node rather than the jq stub - the stub only understands the handful of
# filters check-agents.sh itself uses, not arbitrary field lookups a test
# might want.
history_field() {
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
    const row = JSON.parse(lines[Number(process.argv[2]) - 1]);
    const v = row[process.argv[3]];
    console.log(v === undefined ? "" : JSON.stringify(v));
  ' "$HISTORY" "$1" "$2"
}

history_line_count() {
  [ -f "$HISTORY" ] || { echo 0; return; }
  grep -c . "$HISTORY" 2>/dev/null || echo 0
}

# Read one top-level field back out. Goes through the jq stub rather than a
# `node -e` one-liner: git-bash rewrites POSIX paths in standalone argv into
# Windows paths, but not paths embedded inside a quoted script string.
field() { jq -r ".$2" "$1"; }

make_worktree wt
WT="$WORK/wt"

echo "check-agents.sh regression tests"

# --- a non-terminal task must not stop the sweep --------------------------
echo
echo "a task still running does not end the sweep"
reset_state
write_state t1 running 0 false false false false "$WT"
write_state t2 "done"  0 true  true  true  true  "$WT"
write_state t3 running 0 false false false false "$WT"
TMUX_ALIVE=1 bash "$SCRIPT" >/dev/null 2>&1
is "exits clean" "$?" "0"
is "later task was still visited" "$(field "$STATE/t3.json" status)" "running"

# --- all four checks true -> done ------------------------------------------
echo
echo "all four checks true marks the run done"
reset_state
write_state t1 running 0 false false true true "$WT"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true bash "$SCRIPT" >/dev/null 2>&1
is "exits clean" "$?" "0"
is "status is done" "$(field "$STATE/t1.json" status)" "done"

# --- a PR with red CI must not go done --------------------------------------
echo
echo "a PR whose CI is red is not marked done"
reset_state
write_state t1 running 0 false false true true "$WT"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=false bash "$SCRIPT" >/dev/null 2>&1
is "status still running" "$(field "$STATE/t1.json" status)" "running"

# --- /ship's two checks are never inferred ----------------------------------
echo
echo "green CI alone does not mark a run done"
reset_state
write_state t1 running 0 false false false false "$WT"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true bash "$SCRIPT" >/dev/null 2>&1
is "status still running without /ship's flags" "$(field "$STATE/t1.json" status)" "running"

# --- dead session under the cap -> restart -----------------------------------
echo
echo "a dead session under the attempt cap is restarted"
reset_state
write_state t1 running 1 false false false false "$WT"
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "exits clean" "$?" "0"
is "attempts incremented" "$(field "$STATE/t1.json" attempts)" "2"
is "status still running" "$(field "$STATE/t1.json" status)" "running"

# --- dead session at the cap -> failed ----------------------------------------
echo
echo "a dead session at the attempt cap fails instead of retrying"
reset_state
write_state t1 running 3 false false false false "$WT"
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "status is failed" "$(field "$STATE/t1.json" status)" "failed"
is "attempts not incremented past the cap" "$(field "$STATE/t1.json" attempts)" "3"

# --- a live session whose agent process has exited is treated as dead -------------
# The bug this suite is guarding against: `has-session` alone reports a
# session as healthy even after `claude` inside it has crashed and dropped
# back to a shell prompt. `pane_current_command` must be what breaks the tie.
echo
echo "a session whose agent process exited is restarted, not left running forever"
reset_state
write_state t1 running 0 false false false false "$WT"
TMUX_ALIVE=1 TMUX_PANE_COMMAND=bash bash "$SCRIPT" >/dev/null 2>&1
is "exits clean" "$?" "0"
is "attempts incremented" "$(field "$STATE/t1.json" attempts)" "1"
is "status still running (not yet at the cap)" "$(field "$STATE/t1.json" status)" "running"

# --- a live session whose agent is genuinely still working is left alone ----------
# The important half per the issue: false positives here would kill in-flight
# work, so a pane still running "claude" must never be restarted.
echo
echo "a session whose agent is genuinely still working is not touched"
reset_state
write_state t1 running 0 false false false false "$WT"
TMUX_ALIVE=1 TMUX_PANE_COMMAND=claude bash "$SCRIPT" >/dev/null 2>&1
is "attempts untouched" "$(field "$STATE/t1.json" attempts)" "0"
is "status still running" "$(field "$STATE/t1.json" status)" "running"

# --- an inconclusive liveness check fails safe toward "presume alive" ------------
# A wedged tmux server answering `list-panes` slowly or not at all is not the
# same thing as a dead agent. Killing and restarting on that inconclusive a
# read would risk the exact outcome the issue calls out as the dangerous
# half: destroying a session whose agent is genuinely still working. The
# check must time out (LIVENESS_TIMEOUT, kept short here so the test doesn't
# wait on the real 5s default) without treating the timeout itself as proof
# of death.
echo
echo "a hung liveness check does not get treated as a dead agent"
reset_state
write_state t1 running 0 false false false false "$WT"
START=$(date +%s)
TMUX_ALIVE=1 TMUX_LIST_PANES_HANG=1 LIVENESS_TIMEOUT=2 bash "$SCRIPT" >/dev/null 2>&1
ELAPSED=$(( $(date +%s) - START ))
is "attempts untouched - not treated as dead" "$(field "$STATE/t1.json" attempts)" "0"
is "status still running" "$(field "$STATE/t1.json" status)" "running"
if [ "$ELAPSED" -lt 30 ]; then ok "hung liveness check was cut off well under its 300s sleep (${ELAPSED}s)"; \
else bad "hung liveness check was cut off well under its 300s sleep" "<30s" "${ELAPSED}s"; fi

# --- a failed (not hung) liveness check also fails safe ---------------------------
echo
echo "a liveness check that errors outright also presumes the agent alive"
reset_state
write_state t1 running 0 false false false false "$WT"
TMUX_ALIVE=1 TMUX_LIST_PANES_FAIL=1 bash "$SCRIPT" >/dev/null 2>&1
is "attempts untouched - not treated as dead" "$(field "$STATE/t1.json" attempts)" "0"
is "status still running" "$(field "$STATE/t1.json" status)" "running"

# --- a dead agent at the attempt cap fails instead of retrying, even with the ------
# --- session still alive -----------------------------------------------------------
echo
echo "a dead agent at the attempt cap fails even though the session is still up"
reset_state
write_state t1 running 3 false false false false "$WT"
NOTIFYLOG="$WORK/openclaw.log"; : > "$NOTIFYLOG"
TMUX_CMD_LOG="$WORK/tmux-cap.log"; : > "$TMUX_CMD_LOG"
TMUX_ALIVE=1 TMUX_PANE_COMMAND=bash OPENCLAW_LOG="$NOTIFYLOG" TMUX_CMD_LOG="$TMUX_CMD_LOG" bash "$SCRIPT" >/dev/null 2>&1
is "status is failed" "$(field "$STATE/t1.json" status)" "failed"
is "attempts not incremented past the cap" "$(field "$STATE/t1.json" attempts)" "3"
is "gateway was notified once" "$(grep -c -- '---' "$NOTIFYLOG" || true)" "1"
# A stale session left running here - agent gone, shell prompt still up -
# would never get swept again once status is terminal (terminal states are
# skipped on every future tick), so this must clean it up now, not just on
# the restart path.
is "stale session is killed rather than left as a zombie" \
   "$(grep -c '^kill-session' "$TMUX_CMD_LOG")" "1"

# --- restarting over a stale-but-present session kills it first ------------------
# A session sitting at a shell prompt still holds its name, so `new-session`
# would otherwise fail with "duplicate session" and the restart would be lost.
echo
echo "restarting a dead-agent-but-alive session kills the stale session first"
reset_state
write_state t1 running 0 false false false false "$WT"
TMUX_CMD_LOG="$WORK/tmux.log"; : > "$TMUX_CMD_LOG"
TMUX_ALIVE=1 TMUX_PANE_COMMAND=bash TMUX_CMD_LOG="$TMUX_CMD_LOG" bash "$SCRIPT" >/dev/null 2>&1
is "kill-session ran before new-session" \
   "$(awk '/^kill-session/{k=NR} /^new-session/{n=NR} END{print (k && n && k<n) ? "yes" : "no"}' "$TMUX_CMD_LOG")" \
   "yes"

# --- terminal states are left alone --------------------------------------------
echo
echo "terminal states are not touched"
reset_state
write_state t1 failed 3 false false false false "$WT"
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "attempts untouched" "$(field "$STATE/t1.json" attempts)" "3"

# --- a vanished worktree fails loudly -------------------------------------------
echo
echo "a vanished worktree fails rather than restarting into nothing"
reset_state
write_state t1 running 0 false false false false "$WORK/gone"
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "status is failed" "$(field "$STATE/t1.json" status)" "failed"
is "no restart attempted" "$(field "$STATE/t1.json" attempts)" "0"

# --- the PR is found by the worktree's real branch --------------------------------
# /next cuts its own feat/issue-<n>-<slug> branch inside the worktree, so the
# monitor must query that, not the agent/<task-id> name patrol-loop started on.
echo
echo "the PR is looked up by the worktree's actual branch"
reset_state
make_worktree wt2 "feat/issue-2-openclaw-doctor"
HEADLOG="$WORK/heads.log"; : > "$HEADLOG"
write_state t1 running 0 false false true true "$WORK/wt2"
TMUX_ALIVE=1 GH_PR_NUMBER=4 GH_CI_STATE=true \
  GH_EXPECT_HEAD="feat/issue-2-openclaw-doctor" GH_HEAD_LOG="$HEADLOG" \
  bash "$SCRIPT" >/dev/null 2>&1
is "queried the worktree branch" "$(tail -1 "$HEADLOG")" "feat/issue-2-openclaw-doctor"
is "did not query agent/<task-id>" "$(grep -c '^agent/t1$' "$HEADLOG" || true)" "0"
is "run reached done" "$(field "$STATE/t1.json" status)" "done"

# --- restart passes OPENCLAW_TASK_ID on the command line --------------------------
# tmux setenv only reaches panes created afterwards, so /ship would never find
# its state file if the id were not on the command line itself.
echo
echo "a restart puts OPENCLAW_TASK_ID on the command line"
reset_state
write_state t1 running 0 false false false false "$WT"
TMUX_LOG="$WORK/tmux.log"; : > "$TMUX_LOG"
TMUX_ALIVE=0 TMUX_CMD_LOG="$TMUX_LOG" bash "$SCRIPT" >/dev/null 2>&1
is "send-keys carries the task id" \
   "$(grep -c 'OPENCLAW_TASK_ID=t1 claude' "$TMUX_LOG" || true)" "1"

# --- foreign json in the shared state dir is left alone ---------------------------
# OpenClaw keeps its own state (openclaw.sqlite and friends) in this same
# directory, so the monitor must not touch anything that is not one of its runs.
echo
echo "a foreign json file in the state dir is not mistaken for a run"
reset_state
write_state t1 running 0 false false true true "$WT"
cat > "$STATE/openclaw-internal.json" <<'EOF'
{"someOpenClawKey":"value","nested":{"a":1}}
EOF
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true bash "$SCRIPT" >/dev/null 2>&1
is "exits clean" "$?" "0"
is "foreign file untouched" \
   "$(node -e "const f=require('fs').readFileSync(process.argv[1],'utf8');console.log(JSON.parse(f).someOpenClawKey||'GONE')" "$STATE/openclaw-internal.json")" \
   "value"
is "foreign file gained no status field" \
   "$(node -e "const f=require('fs').readFileSync(process.argv[1],'utf8');console.log(JSON.parse(f).status===undefined?'none':'CLOBBERED')" "$STATE/openclaw-internal.json")" \
   "none"
is "the real run still processed" "$(field "$STATE/t1.json" status)" "done"

# --- no state directory at all ---------------------------------------------------
echo
echo "no state directory is not an error"
rm -rf "$HOME"; mkdir -p "$HOME"
bash "$SCRIPT" >/dev/null 2>&1
is "exits clean" "$?" "0"

# --- a run reaching done notifies the gateway once, with the PR number ------------
echo
echo "a run reaching done notifies the gateway with the task id and PR number"
reset_state
write_state t1 running 0 false false true true "$WT"
NOTIFYLOG="$WORK/openclaw.log"; : > "$NOTIFYLOG"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true OPENCLAW_LOG="$NOTIFYLOG" \
  bash "$SCRIPT" >/dev/null 2>&1
is "status is done" "$(field "$STATE/t1.json" status)" "done"
is "gateway was notified once" "$(grep -c -- '---' "$NOTIFYLOG" || true)" "1"
is "notification names the task id" "$(grep -c 't1' "$NOTIFYLOG" || true)" "1"
is "notification names the PR number" "$(grep -c '#42' "$NOTIFYLOG" || true)" "1"

# --- a run failing at the attempt cap notifies with attempts and pane output ------
echo
echo "a run that fails at the attempt cap notifies with attempts and pane output"
reset_state
write_state t1 running 3 false false false false "$WT"
NOTIFYLOG="$WORK/openclaw.log"; : > "$NOTIFYLOG"
# First tick: session still alive, so the monitor caches the pane tail it will
# need later - the second tick's dead session has nothing left to capture.
TMUX_ALIVE=1 TMUX_PANE_OUTPUT="agent trace: something went wrong" \
  OPENCLAW_LOG="$NOTIFYLOG" bash "$SCRIPT" >/dev/null 2>&1
is "attempts untouched while still alive" "$(field "$STATE/t1.json" attempts)" "3"
is "no notification yet" "$(grep -c -- '---' "$NOTIFYLOG" || true)" "0"
# Second tick: session is dead and attempts are already at the cap.
TMUX_ALIVE=0 OPENCLAW_LOG="$NOTIFYLOG" bash "$SCRIPT" >/dev/null 2>&1
is "status is failed" "$(field "$STATE/t1.json" status)" "failed"
is "gateway was notified once" "$(grep -c -- '---' "$NOTIFYLOG" || true)" "1"
is "notification carries the attempt count" "$(grep -c '3 attempt' "$NOTIFYLOG" || true)" "1"
is "notification carries the cached pane output" \
   "$(grep -c 'agent trace: something went wrong' "$NOTIFYLOG" || true)" "1"

# --- a stale cached pane does not survive into a later restart attempt -----------
# lastPane is a snapshot of whichever session was alive when it was captured.
# Once that session dies and a fresh one is spun up in its place, the old
# snapshot describes a session that no longer exists and must not be handed
# to a later attempt's failure notification as if it were current.
echo
echo "a stale cached pane is cleared on restart, not carried into a later failure"
reset_state
write_state t1 running 1 false false false false "$WT"
NOTIFYLOG="$WORK/openclaw.log"; : > "$NOTIFYLOG"
# Tick 1: session alive, caches attempt 1's pane output.
TMUX_ALIVE=1 TMUX_PANE_OUTPUT="attempt one output" OPENCLAW_LOG="$NOTIFYLOG" \
  bash "$SCRIPT" >/dev/null 2>&1
is "lastPane cached from the alive tick" "$(field "$STATE/t1.json" lastPane)" "attempt one output"
# Tick 2: session dead, under the cap - restarts and must clear the stale snapshot.
TMUX_ALIVE=0 OPENCLAW_LOG="$NOTIFYLOG" bash "$SCRIPT" >/dev/null 2>&1
is "attempts incremented" "$(field "$STATE/t1.json" attempts)" "2"
is "lastPane cleared on restart" "$(field "$STATE/t1.json" lastPane)" "null"
# Tick 3: the new session also dies immediately, before ever being observed
# alive, so nothing new gets cached, and attempts now reach the cap.
TMUX_ALIVE=0 OPENCLAW_LOG="$NOTIFYLOG" bash "$SCRIPT" >/dev/null 2>&1
is "attempts reached the cap" "$(field "$STATE/t1.json" attempts)" "3"
# Tick 4: attempts are at the cap - this is the failure tick.
TMUX_ALIVE=0 OPENCLAW_LOG="$NOTIFYLOG" bash "$SCRIPT" >/dev/null 2>&1
is "status is failed" "$(field "$STATE/t1.json" status)" "failed"
is "failure notification does not carry the stale attempt-1 output" \
   "$(grep -c 'attempt one output' "$NOTIFYLOG" || true)" "0"

# --- a vanished worktree also notifies with attempts and a reason -----------------
echo
echo "a vanished worktree notifies the gateway with the failure reason"
reset_state
write_state t1 running 1 false false false false "$WORK/gone"
NOTIFYLOG="$WORK/openclaw.log"; : > "$NOTIFYLOG"
TMUX_ALIVE=0 OPENCLAW_LOG="$NOTIFYLOG" bash "$SCRIPT" >/dev/null 2>&1
is "status is failed" "$(field "$STATE/t1.json" status)" "failed"
is "gateway was notified once" "$(grep -c -- '---' "$NOTIFYLOG" || true)" "1"
is "notification names the missing worktree" "$(grep -c 'is gone' "$NOTIFYLOG" || true)" "1"

# --- a terminal run is never re-notified on a later sweep -------------------------
echo
echo "a run already marked done is not re-notified on the next sweep"
reset_state
write_state t1 "done" 0 true true true true "$WT"
NOTIFYLOG="$WORK/openclaw.log"; : > "$NOTIFYLOG"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true OPENCLAW_LOG="$NOTIFYLOG" \
  bash "$SCRIPT" >/dev/null 2>&1
is "no notification sent for an already-terminal run" \
   "$(grep -c -- '---' "$NOTIFYLOG" || true)" "0"

# --- a failed notification does not break the sweep --------------------------------
echo
echo "a gateway that rejects the notification does not stop the sweep"
reset_state
write_state t1 running 3 false false false false "$WT"
write_state t2 running 0 false false false false "$WT"
TMUX_ALIVE=0 OPENCLAW_FAIL=1 bash "$SCRIPT" >/dev/null 2>&1
is "exits clean despite the notify failure" "$?" "0"
is "t1 still recorded failed" "$(field "$STATE/t1.json" status)" "failed"
is "t2 was still processed after t1's notify failed" "$(field "$STATE/t2.json" attempts)" "1"

# --- the sweep survives openclaw not being installed at all -----------------------
echo
echo "the sweep completes even when openclaw is not on PATH"
reset_state
write_state t1 running 0 false false true true "$WT"
LIMITED_BIN="$WORK/limited-bin"; mkdir -p "$LIMITED_BIN"
ln -sf "$TESTS_DIR/stubbin/jq" "$LIMITED_BIN/jq"
ln -sf "$TESTS_DIR/stubbin/gh" "$LIMITED_BIN/gh"
ln -sf "$TESTS_DIR/stubbin/tmux" "$LIMITED_BIN/tmux"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true \
  PATH="$LIMITED_BIN:$SYSTEM_PATH" bash "$SCRIPT" >/dev/null 2>&1
is "exits clean without openclaw installed" "$?" "0"
is "status still reaches done" "$(field "$STATE/t1.json" status)" "done"

# --- a hanging notifier does not block the sweep past its timeout -----------------
echo
echo "a hanging openclaw call is killed rather than blocking the sweep"
reset_state
write_state t1 running 0 false false true true "$WT"
START=$(date +%s)
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true OPENCLAW_HANG=1 NOTIFY_TIMEOUT=2 \
  bash "$SCRIPT" >/dev/null 2>&1
ELAPSED=$(( $(date +%s) - START ))
is "status still reaches done past a hung notifier" "$(field "$STATE/t1.json" status)" "done"
if [ "$ELAPSED" -lt 30 ]; then ok "hung notifier was cut off well under its 300s sleep (${ELAPSED}s)"; \
else bad "hung notifier was cut off well under its 300s sleep" "<30s" "${ELAPSED}s"; fi

# --- a run reaching done records a run-history row ---------------------------------
echo
echo "a run reaching done appends a run-history row"
reset_state
write_state t1 running 0 false false true true "$WT" "2026-01-01T00:00:00Z"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true GH_PR_STATE=OPEN bash "$SCRIPT" >/dev/null 2>&1
is "one row written" "$(history_line_count)" "1"
is "row records the task id" "$(history_field 1 taskId)" '"t1"'
is "row records the terminal status" "$(history_field 1 status)" '"done"'
is "row records the attempt count" "$(history_field 1 attempts)" "0"
is "row records the PR number" "$(history_field 1 prNumber)" "42"
is "row records merged=false for an open PR" "$(history_field 1 merged)" "false"
is "row records the four DoD checks" "$(history_field 1 checks)" \
   '{"prCreated":true,"ciPassed":true,"claudeReviewPassed":true,"uiScreenshotsIncluded":true}'
is "row records a non-negative duration from startedAt" \
   "$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8').trim().split('\n')[0]).durationSeconds >= 0)" "$HISTORY")" \
   "true"

# --- a run failing at the attempt cap records a run-history row ---------------------
echo
echo "a run failing at the attempt cap appends a run-history row"
reset_state
write_state t1 running 3 false false false false "$WT"
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "one row written" "$(history_line_count)" "1"
is "row records the failed status" "$(history_field 1 status)" '"failed"'
is "row records a null duration when startedAt was never set" \
   "$(history_field 1 durationSeconds)" "null"
is "row records no PR when none exists" "$(history_field 1 prNumber)" "null"

# --- a vanished worktree still records a run-history row -----------------------------
echo
echo "a vanished worktree appends a run-history row too"
reset_state
write_state t1 running 0 false false false false "$WORK/gone"
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "one row written" "$(history_line_count)" "1"
is "row records the failed status" "$(history_field 1 status)" '"failed"'
is "row records no branch for a worktree that never resolved one" \
   "$(history_field 1 branch)" '""'

# --- a non-terminal tick never writes to run-history ----------------------------------
echo
echo "a run still in progress does not appear in run-history"
reset_state
write_state t1 running 1 false false false false "$WT"
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "status still running" "$(field "$STATE/t1.json" status)" "running"
is "no row written for a non-terminal tick" "$(history_line_count)" "0"

# --- a run already terminal is never re-recorded on a later sweep ---------------------
echo
echo "a run already marked done is not re-recorded on the next sweep"
reset_state
write_state t1 "done" 0 true true true true "$WT"
TMUX_ALIVE=1 GH_PR_NUMBER=42 GH_CI_STATE=true bash "$SCRIPT" >/dev/null 2>&1
is "no row written for an already-terminal run" "$(history_line_count)" "0"

# --- two runs finishing in the same sweep both land intact, atomic rows --------------
# Guards the acceptance criterion that appending is atomic: two runs reaching a
# terminal state inside one sweep must not interleave into a corrupted line.
echo
echo "two runs finishing in the same sweep both get their own intact row"
reset_state
write_state t1 running 0 false false true true "$WT"
write_state t2 running 0 false false true true "$WT"
TMUX_ALIVE=1 GH_PR_NUMBER=7 GH_CI_STATE=true bash "$SCRIPT" >/dev/null 2>&1
is "both rows written" "$(history_line_count)" "2"
is "every row is valid JSON" \
   "$(node -e "
     const lines = require('fs').readFileSync(process.argv[1],'utf8').trim().split('\n');
     console.log(lines.every(l => { try { JSON.parse(l); return true; } catch { return false; } }));
   " "$HISTORY")" \
   "true"
is "task ids are distinct across the two rows" \
   "$(history_field 1 taskId)$(history_field 2 taskId)" \
   '"t1""t2"'

# --- run-history never carries pane output or PR bodies -------------------------------
echo
echo "run-history carries no pane output, only ids/timings/booleans"
reset_state
write_state t1 running 3 false false false false "$WT"
TMUX_ALIVE=1 TMUX_PANE_OUTPUT="agent trace: secret-looking output" bash "$SCRIPT" >/dev/null 2>&1
TMUX_ALIVE=0 bash "$SCRIPT" >/dev/null 2>&1
is "no pane output leaked into run-history" \
   "$(grep -c 'secret-looking output' "$HISTORY" 2>/dev/null || true)" "0"

# --- run-history lives outside both the state dir and the worktree -------------------
# The whole point of a durable record is surviving `git worktree remove` and the
# state file being deleted - so its path must not sit inside either.
echo
echo "run-history is stored outside the state dir and the worktree"
reset_state
write_state t1 running 0 false false true true "$WT"
TMUX_ALIVE=1 GH_PR_NUMBER=1 GH_CI_STATE=true bash "$SCRIPT" >/dev/null 2>&1
case "$HISTORY" in
  "$STATE"/*) bad "history file is outside the state dir" "not under $STATE" "$HISTORY" ;;
  *) ok "history file is outside the state dir" ;;
esac
case "$HISTORY" in
  "$WT"/*) bad "history file is outside the worktree" "not under $WT" "$HISTORY" ;;
  *) ok "history file is outside the worktree" ;;
esac

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
