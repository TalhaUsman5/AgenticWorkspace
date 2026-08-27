#!/usr/bin/env bash
# tdev - launch a tmux dev session
# Usage: tdev [session-name] [project-dir]
# Creates: agent pane (left, 60%) | neovim pane (right, 40%)

set -euo pipefail

SESSION="${1:-dev}"
DIR="${2:-$(pwd)}"

# Resolve to absolute path
DIR="$(cd "$DIR" && pwd)"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Attaching to existing session: $SESSION"
  tmux attach-session -t "$SESSION"
  exit 0
fi

# New session, first window named after the project
tmux new-session -d -s "$SESSION" -c "$DIR" -n "$(basename "$DIR")"

# Split right 40% for neovim; left pane keeps focus
tmux split-window -t "$SESSION:1" -h -p 40 -c "$DIR"

# Right pane: open neovim
tmux send-keys -t "$SESSION:1.2" 'nvim .' Enter

# Left pane: open Claude Code
if command -v claude &>/dev/null; then
  tmux send-keys -t "$SESSION:1.1" 'claude' Enter
else
  echo "Warning: 'claude' not found on PATH"
fi

# Focus agent pane
tmux select-pane -t "$SESSION:1.1"

tmux attach-session -t "$SESSION"
