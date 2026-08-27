---
name: ship
description: Deliver completed work: run the quality gate, get the diff reviewed, commit with conventions, push, and open a pull request. Use when a task is done and ready to deliver.
---

# Ship

The standardized delivery path.
Every agent shipping through this skill produces the same shape of branch, commit, and pull request.

## Preconditions

- A git repo with a remote and an identifiable default branch.
- Never ship directly to the default branch: if currently on it, create a branch first, named `<type>/<short-slug>` where type is one of feat, fix, chore, refactor, docs, or test.
- Never force-push.

## Steps

1. **Gate**: run /patrol and fix until it passes.
   If patrol is blocked, stop and report; blocked work does not ship.
2. **Review**: run the harness's built-in /code-review over the diff and address correctness findings, then run the built-in /security-review and address its findings.
   Security findings are never shipped around: fix them or stop and report.
   If addressing either review changed code, re-run /patrol.
3. **Commit**: conventional commit format (`type(scope): imperative subject` at 72 chars or less, body explaining why, not what).
   Split unrelated changes into separate commits rather than bundling.
   Never add an agent name as co-author.
4. **Push and open the PR** with `gh pr create`.
   Use the repo's PR template if `.github/PULL_REQUEST_TEMPLATE.md` exists.
   The body must cover: what changed and why, the patrol verdict as test evidence, review findings addressed, and `Closes #N` when the work came from an issue.
5. **Record the checks you own** (only when `OPENCLAW_TASK_ID` is set in the environment, i.e. this is an unattended OpenClaw run).
   `check-agents.sh` fills in `prCreated` and `ciPassed` from outside, but it cannot see whether the reviews in step 2 actually ran or whether UI work carries screenshots, so it trusts this skill for those two:

   ```bash
   state="$HOME/.openclaw/state/$OPENCLAW_TASK_ID.json"
   tmp=$(mktemp)
   jq --argjson review true --argjson shots true \
      '.checks.claudeReviewPassed = $review | .checks.uiScreenshotsIncluded = $shots' \
      "$state" > "$tmp" && mv "$tmp" "$state"
   ```

   Set `claudeReviewPassed` to true only if step 2's code-review and security-review both ran and their findings are addressed.
   Set `uiScreenshotsIncluded` to true if the change touched UI and the PR body has before/after screenshots, or if the change touched no UI at all.
   Leave a flag false and say so in the report rather than setting it optimistically; a false flag holds the run open for a human instead of announcing it as ready.
6. **Report**: the PR URL, the final patrol verdict, and anything a human reviewer should look at first.

## Judgement calls

- If the working tree contains changes unrelated to the task being shipped, leave them out of the commits and say so in the report.
- If the repo has no remote or no PR flow (a local-only project), fall back to committing on a branch and reporting; do not invent a workflow the project does not have.
- Repos that deliver by direct push use /commit instead; repos that deliver by promoting develop into the release branch use /release for that promotion.
- Draft PRs are the default when patrol passed but the task's own acceptance criteria are unverified; say why in the PR body.
