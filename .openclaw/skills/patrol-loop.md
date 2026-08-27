# patrol-loop

Trigger: a message naming a project directory and a task (or "keep working
the backlog on <project>").

## What to do

1. Resolve `<project>` to its local path (ask if ambiguous).
   Resolve it to an absolute path now; every path written below must be
   absolute, because the monitor runs from a systemd timer with an
   unrelated working directory and cannot resolve `../` against yours.
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
     "claude --dangerously-skip-permissions -p '/next'" Enter
   ```
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
     "attempts": 0,
     "checks": {
       "prCreated": false,
       "ciPassed": false,
       "claudeReviewPassed": false,
       "uiScreenshotsIncluded": false
     }
   }
   ```
   ```
   tmux setenv -t aw-<task-id> OPENCLAW_TASK_ID <task-id>
   ```
6. Do NOT poll the session yourself in a loop - that's `check-agents.sh`'s
   job, run on a timer. Reply to the user that the run has started and where
   to see it (`tmux attach -t aw-<task-id>`), then stop.

## When the monitor reports back

`check-agents.sh` updates the state file and will message you (the OpenClaw
agent) when:
- all `checks` pass -> summarize the PR to the user and mark `status: "done"`.
- attempts hit 3 without success -> surface the failure and the last tmux
  pane output to the user; do not restart a 4th time automatically.

## Division of labour over the checks

`prCreated` and `ciPassed` are observable from outside, so `check-agents.sh`
fills them in via `gh`.
`claudeReviewPassed` and `uiScreenshotsIncluded` are only knowable from
inside the run, so `/ship` writes them (see `claude/skills/ship/SKILL.md`).
Never set the latter two from here or from the monitor: a run that dies
before `/ship` must not be able to look finished.
