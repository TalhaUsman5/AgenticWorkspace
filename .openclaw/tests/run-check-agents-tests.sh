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

# task_id status attempts prCreated ciPassed reviewPassed shotsIncluded worktree
write_state() {
  cat > "$STATE/$1.json" <<EOF
{"status":"$2","session":"aw-$1","project":"p","worktree":"$8","attempts":$3,
 "checks":{"prCreated":$4,"ciPassed":$5,"claudeReviewPassed":$6,"uiScreenshotsIncluded":$7}}
EOF
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

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
