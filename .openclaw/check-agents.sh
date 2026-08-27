#!/usr/bin/env bash
# Deterministic supervisor for OpenClaw-spawned Claude Code sessions.
# Run on a systemd timer (see docs/openclaw-migration.md) - not by an LLM,
# to keep polling cheap and predictable.
set -euo pipefail

STATE_DIR="$HOME/.openclaw/state"
MAX_ATTEMPTS=3

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "gh is required" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "tmux is required" >&2; exit 1; }

[ -d "$STATE_DIR" ] || exit 0

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
  # does not fire on it. Too subtle to leave in a supervisor.
  if [ "$status" = "done" ] || [ "$status" = "failed" ]; then
    continue
  fi

  # patrol-loop.md writes an absolute worktree path; a run whose worktree has
  # been deleted out from under it can never go green, so fail it loudly
  # rather than restarting into a missing directory three times.
  if [ ! -d "$worktree" ]; then
    tmp=$(mktemp)
    jq '.status = "failed"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    echo "[$task_id] worktree $worktree is gone - needs a human"
    continue
  fi

  session_alive=false
  if tmux has-session -t "$session" 2>/dev/null; then
    session_alive=true
  fi

  repo_url=$(git -C "$worktree" remote get-url origin 2>/dev/null || echo "")

  # Check for an associated PR and its CI status via gh CLI.
  pr_number=""
  if [ -n "$repo_url" ]; then
    pr_number=$(gh pr list --repo "$repo_url" \
      --head "agent/${task_id}" --json number --jq '.[0].number' 2>/dev/null || echo "")
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
    tmp=$(mktemp)
    jq '.status = "done"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    echo "[$task_id] all checks green - PR #$pr_number ready for review"
    continue
  fi

  if [ "$session_alive" = "false" ]; then
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
      tmp=$(mktemp)
      jq '.status = "failed"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
      echo "[$task_id] failed after $MAX_ATTEMPTS attempts - needs a human"
    else
      echo "[$task_id] session died, restarting (attempt $((attempts + 1)))"
      tmux new-session -d -s "$session" -c "$worktree"
      tmux send-keys -t "$session" \
        "claude --dangerously-skip-permissions -p '/next'" Enter
      tmp=$(mktemp)
      jq '.attempts += 1' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
    fi
  fi
done
