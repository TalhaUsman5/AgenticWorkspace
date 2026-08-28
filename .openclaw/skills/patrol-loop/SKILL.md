---
name: patrol-loop
description: "Spawn and supervise an unattended Claude Code run on a project: create a git worktree, start a detached tmux session against /next, and hand monitoring to check-agents.sh. Use when asked to work a backlog item or keep working the backlog on a named project."
metadata: { "openclaw": { "emoji": "🚨" } }
---

# patrol-loop

Trigger: a message naming a project directory and a task (or "keep working
the backlog on <project>").

## What to do

1. Resolve `<project>` to its local path (ask if ambiguous).
   Resolve it to an absolute path now; every path written below must be
   absolute, because the monitor runs from a systemd timer with an
   unrelated working directory and cannot resolve `../` against yours.

   If the path is under `/mnt/`, say so before starting. Windows drives
   mounted into WSL are slow enough to matter for a full build-and-test
   loop, and their permission model does not carry the executable bit or
   Unix ownership the way git expects. Prefer a clone under `$HOME`.
2. Create an isolated worktree so the new work can't break the main tree:
   ```
   git -C <project> worktree add <project>-<task-id> -b agent/<task-id>
   ```
3. Spawn a detached tmux session for the run:
   ```
   tmux new-session -d -s aw-<task-id> -c <project>-<task-id>
   ```
4. Inside that session, launch Claude Code headless with the task context and
   the workspace's own `AGENTS.md` instructions, invoking the backlog-intake
   skill:
   ```
   tmux send-keys -t aw-<task-id> \
     "OPENCLAW_TASK_ID=<task-id> claude --dangerously-skip-permissions -p '/next'" Enter
   ```
   `OPENCLAW_TASK_ID` must go on the command line. `tmux setenv` only reaches
   panes created after it runs, so the shell already sitting in this session
   never sees it, and `/ship` then has no state file to record its checks in.
   (`/next` picks the next backlog item, works it, runs `/patrol`, then `/ship`
   per AGENTS.md - see the workspace repo's own skill definitions.)
5. Write an initial state file so the deterministic monitor can pick this run
   up without polling you or another model.
   `OPENCLAW_TASK_ID` is exported into the session so `/ship` can find this
   same file when it records its own checks:
   ```
   ~/.openclaw/state/<task-id>.json
   {
     "status": "running",
     "session": "aw-<task-id>",
     "project": "/abs/path/to/<project>",
     "worktree": "/abs/path/to/<project>-<task-id>",
     "startedAt": "<ISO 8601 UTC timestamp, e.g. `date -u +%Y-%m-%dT%H:%M:%SZ`>",
     "attempts": 0,
     "checks": {
       "prCreated": false,
       "ciPassed": false,
       "claudeReviewPassed": false,
       "uiScreenshotsIncluded": false
     }
   }
   ```
   `startedAt` is what lets `check-agents.sh` compute a run's wall-clock
   duration for the run-history record (see below); a run started without it
   still gets recorded, just with a null duration.
   Note that the worktree's branch is not the branch the PR ends up on.
   `/next` cuts its own `<type>/issue-<n>-<slug>` branch inside the worktree
   and works there, so `agent/<task-id>` is only the starting point.
   `check-agents.sh` reads the worktree's current branch rather than assuming
   a name; do not record a branch name in the state file.
6. Do NOT poll the session yourself in a loop - that's `check-agents.sh`'s
   job, run on a timer. Reply to the user that the run has started and where
   to see it (`tmux attach -t aw-<task-id>`), then stop.

## When the monitor reports back

`check-agents.sh` updates the state file and notifies the gateway (via
`openclaw agent --agent main --message ... --deliver`, timeboxed so a stuck
CLI or an unreachable gateway can never block the sweep) when:
- all `checks` pass -> summarize the PR to the user and mark `status: "done"`.
- attempts hit 3 without success, or the worktree has vanished -> surface the
  failure and the last tmux pane output to the user; do not restart a 4th
  time automatically.

Each terminal outcome is notified once: the transition to `done`/`failed` and
the notification happen together, and a terminal state is never revisited on
a later sweep.
Notification failure (missing `openclaw`, unreachable gateway, a hang) never
breaks the sweep or leaves the state file inconsistent - it is best-effort on
top of state that is already correct.

In that same tick, `check-agents.sh` also appends one row to
`~/.openclaw/run-history.jsonl` - a durable log that survives the state file
being deleted and the worktree being removed.
See `docs/openclaw-migration.md`'s "Run history" section for the row shape
and `scripts/openclaw-runs.ps1` for summarising it.

## Division of labour over the checks

`prCreated` and `ciPassed` are observable from outside, so `check-agents.sh`
fills them in via `gh`.
`claudeReviewPassed` and `uiScreenshotsIncluded` are only knowable from
inside the run, so `/ship` writes them (see `claude/skills/ship/SKILL.md`).
Never set the latter two from here or from the monitor: a run that dies
before `/ship` must not be able to look finished.
