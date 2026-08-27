---
name: next
description: Pull the next work item from the project's queue, claim it, and drive it to delivery. The intake step of the autonomous loop: next, work, patrol, ship.
---

# Next

Turn a waiting queue into finished, shipped work.
One item per invocation: claim it, do it, deliver it, stop.

## Commit and push authority

AGENTS.md rules "do not commit or push unless asked", which is correct for interactive work but would block an autonomous loop.
Its carve-out covers this skill: once /next has claimed a queue item, the commits and pushes /next and /ship make for that item count as asked-for.
The carve-out is scoped to the claimed item's own branch, so pushing to `master`/`main` and force-pushing stay forbidden here too.

## How this skill gets invoked

Unattended runs do not come from a human typing `/next`.
OpenClaw spawns a worktree and a detached tmux session and calls `claude -p '/next'` inside it, then hands supervision to `.openclaw/check-agents.sh`.
See `.openclaw/skills/patrol-loop.md` for the spawn contract and `docs/openclaw-migration.md` for the whole loop.

## Resolve the queue

Use the first source that exists in the project:

1. **GitHub issues**: open, unassigned issues labeled `agent-ready` (`gh issue list --label agent-ready --no-assignee`), oldest first.
   If the label convention is absent, do not guess from the general issue pool; report that no queue is configured.
2. **OpenSpec**: changes under `openspec/changes/*/tasks.md` with unchecked tasks, in the order the change's tasks file defines.
3. **Backlog file**: unchecked items in a root `BACKLOG.md`.

If every source is empty, report `NEXT: IDLE` and stop; the loop's scheduler decides when to look again.

## Claim before working

Concurrent agents share the queue, so claim atomically before touching code:

- GitHub issue: assign yourself and comment that an agent has claimed it (`gh issue edit <n> --add-assignee @me`).
  If the assignment races and someone else got it, pick the next item.
- OpenSpec or backlog: mark the item in-progress in its file and commit that single-line change immediately on a branch, so other agents see the claim.

## Work the item

1. Restate the item as acceptance criteria; if the item is too vague to state criteria, comment asking for clarification, unclaim it, and move on to the next item.
2. Implement on a branch named from the item (`feat/issue-123-short-slug`).
3. Run /patrol and fix until green.
4. Deliver via /ship, with `Closes #N` linking when the item is a GitHub issue.
5. Update the queue: check off the OpenSpec or backlog item, or let the PR's `Closes` handle the issue.

## Report

End with: the item claimed, the PR URL or delivery result, and `NEXT: SHIPPED`, `NEXT: BLOCKED (<reason>)`, or `NEXT: IDLE`.
Never claim a second item in the same invocation; the loop calls this skill again when it wants more.
