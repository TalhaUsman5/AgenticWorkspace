# Branden's agent instructions

These are common instructions for Branden's agents across all scenarios.
This file is the single source of truth.
It lives in the AgenticWorkspace repo as `AGENTS.md` and is symlinked to `~/.claude/CLAUDE.md`, `~/.claude/AGENTS.md`, and the repo's own `CLAUDE.md`.
Edit `AGENTS.md` only; never edit the symlinks.

## Hard rules

Non-negotiable in every project:

- Never use the em dash "—". Use plain dash "-" instead.
- When writing commit messages, NEVER auto-add your agent name as co-author.
- Never manually modify CHANGELOG.md files or any files that are marked as auto-generated.
- When writing or substantially editing Markdown files, put each full sentence on its own line.
  Preserve normal Markdown structure, but avoid wrapping multiple sentences onto one physical line.

## Engineering standards

- When making technical decisions, do not give much weight to development cost.
  Instead, prefer quality, simplicity, robustness, scalability, and long term maintainability.
- When doing bug fixes, always start with reproducing the bug in an E2E setting as closely aligned with how an end user would trigger it.
  This makes sure you find the real problem so your fix will actually solve it.
  Prove the fix the same way: trigger the original scenario again and observe it passing.
- When end-to-end testing a product, be picky about the UI you see and be obsessed with pixel perfection.
  If something clearly looks off, even if it is not directly related to what you are doing, try to get it fixed along the way.
- Apply that same high standard to engineering excellence: lint, test failures, and test flakiness.
  If you see one, even if it is not caused by what you are working on right now, still get it fixed.
- Scope discipline for the two rules above: fix small issues (a lint finding, a flaky test, a misleading log or status line) inline as part of the current task.
  If the fix needs real design work, surface it in your report instead of silently expanding scope.

## Ways of working

- Commit messages follow conventional commits: a lowercase type prefix (`feat`, `fix`, `chore`, `refactor`, `docs`, `test`), a colon, then an imperative subject of 72 characters or less.
  The body explains why, not what.
- Split unrelated changes into separate commits; never bundle them.
- Never do dev work directly on `master`/`main`.
  Work on a `develop` branch, or a branch cut from `develop`, and let `/release` promote `develop` into `master`/`main` when a release is cut.
  A repo's own instructions (e.g. its README, CONTRIBUTING.md, or a scoped section in this file) can override this for repos that intentionally commit straight to `master`/`main`.
- Do not commit or push unless asked, and never force-push.
  Carve-out for the autonomous loop: when `/next` has claimed a queue item, the commits and pushes that `/next` and `/ship` make for that item count as asked-for, and do not need a fresh confirmation.
  The carve-out covers only the claimed item's own branch; it never authorises pushing to `master`/`main` or force-pushing anything.
- When a task is ambiguous, state your interpretation and proceed on the reversible parts; ask only when the answer genuinely changes what you build.
- Report honestly: if a check failed, was skipped, or was not run, say so plainly.
  Never describe unverified work as done.

## Operating principles

How to work, regardless of which model is running:

- Investigate before acting.
  Reproduce the problem, read the relevant code, and verify assumptions against the actual system (installed versions, real configs, live behaviour) instead of pattern-matching to a familiar failure.
- Ground claims in evidence.
  Check the source, changelog, or issue tracker rather than trusting memory; if you did not verify it, do not state it as fact.
- Fix root causes, not symptoms.
  When an upstream bug forces a workaround, say so and link the issue in a code comment.
- Verify end to end after changing anything.
  If verification needs something only Branden can do (a physical key press, a login), set up the test and hand over exact steps.
- Lead with the outcome.
  The first sentence of a report answers what happened or what was found; supporting detail comes after.
- When blocked on a decision only Branden can make, present numbered options with a recommendation; otherwise pick the sensible default, state it, and proceed.

## Quality Gate

Default skills are installed at `~/.claude/skills` and work in any project: `typecheck`, `lint`, `audit`, `police`, `patrol`, `equip`, `ship`, `commit`, and `release`.
After completing a set of code changes, run /patrol before committing or reporting the task as done.
Patrol runs typecheck, lint, audit, police, and tests in order, and you must fix failures as they arise until the whole gate is green.
When a repo has no tooling for a gate stage, run /equip to set it up rather than letting the stage stay skipped; only stages equip records as not applicable may be skipped.
Delivery has three shapes: /commit for direct-push repos, /release to promote develop into the release branch, and /ship for pull-request flows.
If the project has a POLICE.md, its rules are law for every changeset; never water them down or grant exceptions.
Repos without their own POLICE.md fall back to the global rules symlinked at `~/.claude/POLICE.md`; a repo file replaces the fallback entirely, so it must carry over any global rules that still apply.

## Unattended operation

Unattended runs are driven externally by OpenClaw, not by looping `/patrol` inside a single Claude Code session.
OpenClaw spawns each task into its own git worktree plus detached tmux session and invokes `/next`, which works the backlog item through `/patrol` and `/ship` on its own.

A run is only considered ready for merge once every check in its state file (`~/.openclaw/state/<task-id>.json`, maintained by `check-agents.sh`) is true:

```json
{
  "checks": {
    "prCreated": true,
    "ciPassed": true,
    "claudeReviewPassed": true,
    "uiScreenshotsIncluded": true
  }
}
```

`prCreated` and `ciPassed` are filled in automatically via `gh`.
`claudeReviewPassed` and `uiScreenshotsIncluded` are the agent's own responsibility - `/ship` should not exit successfully without setting them (see `claude/skills/ship/`).

A stuck session is restarted up to 3 times before `check-agents.sh` gives up and surfaces it to a human.
Do not build additional self-restart logic into `/next` or `/patrol` - retry policy lives in the deterministic monitor, not in the model loop.

## Definition of done

Work is finished only when all of these hold:

1. /patrol passes end to end, and any SKIPPED stage is named in the report.
2. The change has been exercised for real, not only through tests: run the app, reload the config, or drive the flow the way an end user would.
3. Bug fixes carry their E2E reproduction: shown failing before the fix, shown passing after.
4. Docs and comments touched by the change match the new reality.
5. The final report states what was done, what was skipped, and anything left for a human decision.

## This repository (AgenticWorkspace)

Rules scoped to work inside the AgenticWorkspace repo itself:

- This is a dotfiles and agent-instructions repo; configs here are symlinked live into system paths, so edits take effect on the real machine immediately.
- Windows is the primary platform and scripts are PowerShell 7; Linux/Omarchy support is secondary.
- Work on a branch cut from `develop`, and deliver it as a pull request into `develop`; `develop` is promoted into `master` when a release is cut.
  This repo follows the global branching rule rather than overriding it.
- Setup scripts must stay idempotent; safe to re-run is a requirement.
- WezTerm reads `~/.config/wezterm/` through a directory symlink, and its file watcher misses edits made to the symlink target; after config changes, reload with Ctrl+Shift+R rather than trusting auto-reload.
- Skill changes under `claude/skills/` are live for new Claude Code sessions with no install step; `claude/skills-inactive/` is staged and not loaded.
- `.openclaw/` is deployed into WSL by `bootstrap/openclaw-wsl.ps1`, not symlinked, so edits there do not take effect until that script is re-run.
- Quality gate tooling: lint is `stylua --check .` plus `Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1`.
- Tests: `bash .openclaw/tests/run-check-agents-tests.sh` covers the unattended-run monitor, which is the one component here that runs with nobody reading its output. It stubs `jq`, `gh`, and `tmux`, so it needs only bash and Node. Nothing else in the repo has an automated test; the dotfiles are verified by using them.
  WezTerm config changes are verified by reloading WezTerm by hand, because `wezterm.exe` is flagged RUNASADMIN and cannot be driven from a normal shell.
- Typecheck is not applicable here (Lua and PowerShell have no standalone type checker), and dependency audit is not applicable (no package manifests); do not re-litigate these gaps.
- Secrets scanning uses `gitleaks`, and lint needs `stylua` plus the `PSScriptAnalyzer` module; all three are installed by `bootstrap/workspace-windows.ps1`.
  If a gate stage reports the tool missing, run that script rather than skipping the stage.

## Branden's Opinions

If `~/OPINIONS.md` exists, read it when you are working on something that would benefit from being informed by Branden's viewpoints.

## Voice Profile

If `~/VOICE.md` exists, read it before talking or posting on behalf of Branden using his identity, to see how Branden talks.
