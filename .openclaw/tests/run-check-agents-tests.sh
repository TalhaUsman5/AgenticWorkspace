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
  rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"
  git -C "$WORK/$1" init -q
  git -C "$WORK/$1" remote add origin "https://example.com/o/r.git"
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
write_state t2 done    0 true  true  true  true  "$WT"
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

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
