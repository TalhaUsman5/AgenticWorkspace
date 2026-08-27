#!/usr/bin/env bash
# Deterministic supervisor for OpenClaw-spawned Claude Code sessions.
# Run on a systemd timer (see docs/openclaw-migration.md) - not by an LLM,
# to keep polling cheap and predictable.
set -euo pipefail

STATE_DIR="$HOME/.openclaw/state"
MAX_ATTEMPTS=3
NOTIFY_TIMEOUT="${NOTIFY_TIMEOUT:-15}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh is required" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "tmux is required" >&2; exit 1; }

[ -d "$STATE_DIR" ] || exit 0

# Runs "$@" but never lets it block the sweep past $1 seconds, even if the
# command ignores its own timeout flags or the binary hangs outright. Written
# by hand rather than calling out to GNU coreutils `timeout`, which git-bash
# on Windows does not ship - see run-check-agents-tests.sh's own portability
# note.
with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs" 2>/dev/null; kill "$pid" 2>/dev/null ) &
  local watchdog=$!
  local status=0
  wait "$pid" 2>/dev/null || status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null || true
  return "$status"
}

# Best-effort notification to the OpenClaw gateway. openclaw not being
# installed, the gateway being unreachable, or the call hanging must never
# take the sweep down with it - the caller always guards this with `|| true`.
notify_gateway() {
  local message="$1"
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "openclaw CLI not found - skipping gateway notification" >&2
    return 1
  fi
  with_timeout "$NOTIFY_TIMEOUT" \
    openclaw agent --agent main --message "$message" --deliver >/dev/null 2>&1
}

# Composes and sends a failure notification, folding in whatever tmux pane
# output was last cached for this run (see the session_alive branch below -
# by the time attempts hit the cap, or a worktree vanishes, tmux itself may
# already be a dead end, so this reads a snapshot taken on an earlier tick
# rather than trying to capture-pane a session that is already gone).
notify_failed() {
  local task_id="$1" attempts="$2" state_file="$3" reason="$4"
  local last_pane body
  last_pane=$(jq -r '.lastPane // empty' "$state_file" 2>/dev/null || echo "")
  body="OpenClaw run $task_id failed after $attempts attempt(s)${reason:+ ($reason)}."
  if [ -n "$last_pane" ]; then
    body="$body

Last tmux output:
$last_pane"
  fi
  notify_gateway "$body" || true
}

for state_file in "$STATE_DIR"/*.json; do
  [ -e "$state_file" ] || continue

  task_id=$(basename "$state_file" .json)
  session=$(jq -r '.session // empty' "$state_file" 2>/dev/null || echo "")
  worktree=$(jq -r '.worktree // empty' "$state_file" 2>/dev/null || echo "")
  status=$(jq -r '.status // empty' "$state_file" 2>/dev/null || echo "")
  attempts=$(jq -r '.attempts // 0' "$state_file" 2>/dev/null || echo 0)

  # This directory is shared with OpenClaw's own state (openclaw.sqlite lives
  # here too). Anything without a session and a worktree is not one of our run
  # files, so leave it alone - without this guard the worktree check below
  # would overwrite a foreign file with {"status":"failed"}.
  if [ -z "$session" ] || [ -z "$worktree" ]; then
    continue
  fi

  # Terminal states are left alone. Spelled as an if rather than
  # `[ a ] || [ b ] && continue`: that form works, but only because the
  # failing test is not the last command in the and-or list, so `set -e`
  # does not fire on it. Too subtle to leave in a supervisor. Notification
  # for a terminal state happens exactly once, in the same tick that writes
  # the terminal status below - once status is done/failed this file is
  # skipped forever after, so there is nothing left to (re-)notify here.
  if [ "$status" = "done" ] || [ "$status" = "failed" ]; then
    continue
  fi

  session_alive=false
  if tmux has-session -t "$session" 2>/dev/null; then
    session_alive=true
  fi

  # Cache the pane's tail while the session is still alive. Once tmux tears
  # a session down (the normal way a run "dies" here), capture-pane has
  # nothing left to read - so the only way a failure notification can carry
  # real output is to have squirreled it away on an earlier, still-alive
  # tick. That means the snapshot is only ever as fresh as the last poll
  # (up to one timer interval old, never the exact instant of failure) -
  # an accepted trade-off against setting `remain-on-exit on` on the spawned
  # session, which would keep a dead pane's content readable right up to
  # failure time but would also stop tmux from ever auto-destroying a
  # finished session, breaking the has-session-based liveness check this
  # script's restart logic already depends on. Best effort either way: a
  # capture that fails just leaves the previous snapshot in place.
  if [ "$session_alive" = "true" ]; then
    pane_snippet=$(tmux capture-pane -p -t "$session" 2>/dev/null | tail -n 20 || true)
    if [ -n "$pane_snippet" ]; then
      tmp=$(mktemp)
      jq --arg pane "$pane_snippet" '.lastPane = $pane' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    fi
  fi

  # patrol-loop.md writes an absolute worktree path; a run whose worktree has
  # been deleted out from under it can never go green, so fail it loudly
  # rather than restarting into a missing directory three times.
  if [ ! -d "$worktree" ]; then
    notify_failed "$task_id" "$attempts" "$state_file" "worktree $worktree is gone"
    tmp=$(mktemp)
    jq '.status = "failed"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    echo "[$task_id] worktree $worktree is gone - needs a human"
    continue
  fi

  repo_url=$(git -C "$worktree" remote get-url origin 2>/dev/null || echo "")

  # Ask the worktree which branch it is on rather than assuming
  # "agent/<task-id>". patrol-loop.md creates the worktree on that name, but
  # /next then cuts its own `<type>/issue-<n>-<slug>` branch and works there,
  # so the assumed name matches no PR and every run would stay un-done.
  head_branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  # Check for an associated PR and its CI status via gh CLI.
  pr_number=""
  if [ -n "$repo_url" ] && [ -n "$head_branch" ]; then
    pr_number=$(gh pr list --repo "$repo_url" \
      --head "$head_branch" --json number --jq '.[0].number' 2>/dev/null || echo "")
  fi

  pr_created=false
  ci_passed=false
  if [ -n "$pr_number" ]; then
    pr_created=true
    checks=$(gh pr checks "$pr_number" --repo "$repo_url" \
      --json state --jq '[.[].state] | all(. == "SUCCESS")' 2>/dev/null || echo "false")
    if [ "$checks" = "true" ]; then
      ci_passed=true
    fi
  fi

  tmp=$(mktemp)
  jq --argjson pr "$pr_created" --argjson ci "$ci_passed" \
     '.checks.prCreated = $pr | .checks.ciPassed = $ci' \
     "$state_file" > "$tmp" && mv "$tmp" "$state_file"

  # claudeReviewPassed and uiScreenshotsIncluded are written by /ship, not
  # here - see claude/skills/ship/SKILL.md.
  all_pass=$(jq '[.checks[]] | all' "$state_file")

  if [ "$all_pass" = "true" ]; then
    notify_gateway "OpenClaw run $task_id is done. PR #$pr_number is ready for review." || true
    tmp=$(mktemp)
    jq '.status = "done"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    echo "[$task_id] all checks green - PR #$pr_number ready for review"
    continue
  fi

  if [ "$session_alive" = "false" ]; then
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
      notify_failed "$task_id" "$attempts" "$state_file" ""
      tmp=$(mktemp)
      jq '.status = "failed" | .reported = true' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
      echo "[$task_id] failed after $MAX_ATTEMPTS attempts - needs a human"
    else
      echo "[$task_id] session died, restarting (attempt $((attempts + 1)))"
      tmux new-session -d -s "$session" -c "$worktree"
      # OPENCLAW_TASK_ID goes on the command line, not through `tmux setenv`:
      # setenv only reaches panes created afterwards, so a shell that already
      # exists never sees it and /ship cannot find its state file.
      tmux send-keys -t "$session" \
        "OPENCLAW_TASK_ID=$task_id claude --dangerously-skip-permissions -p '/next'" Enter
      tmp=$(mktemp)
      jq '.attempts += 1' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
      # The cached pane belongs to the session that just died. Drop it so a
      # final failure notification (if the next attempt also dies before a
      # tick ever observes it alive) doesn't misattribute this attempt's
      # output to a later one.
      tmp=$(mktemp)
      jq '.lastPane = null' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    fi
  fi
done
