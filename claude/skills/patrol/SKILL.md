---
name: patrol
description: Run the full quality gate (typecheck, lint, police, tests) and fix failures until everything passes. Use at the end of any coding task, before committing, or as the gate stage of an unattended run.
---

# Patrol

The quality gate for a set of changes.
Run every stage, fix failures as they arise, and do not report success until the whole gate is green.

## Stages, in order

1. **typecheck** - follow the sibling `typecheck` skill (read its SKILL.md next to this one).
2. **lint** - follow the sibling `lint` skill.
3. **audit** - follow the sibling `audit` skill; a SKIPPED audit (missing scanner) does not fail the gate but must appear in the report.
4. **police** - follow the sibling `police` skill; skip only if the project has no police file, and say so.
5. **tests** - resolve the project's test command the same way the other skills resolve theirs (project docs and skills first, then package scripts or task-runner targets, then the ecosystem default such as `npm test`, `pytest`, `cargo test`, `go test ./...`, `dotnet test`).
   Run the full suite.

A stage with no tooling configured is not a free pass: follow the sibling `equip` skill to set the missing tool up, then run the stage for real.
Only a stage that equip records as not applicable for this stack (or a tool that cannot be installed in this environment) may be reported SKIPPED, and it must be named in the report.

## Loop

1. Run the current stage.
   If it fails, fix the failures and re-run the stage until it passes, capping at 5 fix cycles per stage.
2. Move to the next stage only when the current one passes.
3. After all five stages have passed individually, run one final sweep of all stages back to back, because a fix made in a later stage can break an earlier one.
   The sweep must be fully green to declare the gate passed.
4. If any stage is still failing after its cap, stop and report; do not paper over it.

Fixing rules carry over from the stage skills: root causes only, no suppressions, no deleted tests, no weakened assertions.
A flaky test is a failure to fix, not to retry into passing.

## Report

End with a table of stage, status, and fixes applied, then a single verdict line: `PATROL: PASS` or `PATROL: FAIL at <stage>`.
On failure, include the exact failing output so the next agent or human can pick it up without re-running.

## Unattended operation

Patrol is idempotent and safe to re-run, which makes it the building block for asynchronous agent loops:

- Agents should run /patrol after completing any coding task, before committing or reporting done.
- For continuous operation, do not loop patrol inside one session. Unattended runs are spawned and supervised from outside by OpenClaw, which invokes `/next` per task; patrol is one stage inside that run, not the loop itself.
- When patrol fails in a loop, the fix belongs in the same iteration; never leave the gate red for the next cycle to discover.
