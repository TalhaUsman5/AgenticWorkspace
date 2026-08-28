#!/usr/bin/env bash
# Regression tests for scripts/openclaw-runs.ps1's summary math.
#
# Dot-sources the script (which, per its own guard, only runs its top-level
# report when invoked directly - see the `$MyInvocation.InvocationName -ne
# '.'` check) so Get-RunHistorySummary and Get-BlockingCheck can be called
# in isolation against synthetic rows, with no WSL distro or history file
# required. Also exercises the full CLI path via -HistoryPath against a
# real JSONL fixture.
#
# Usage: bash .openclaw/tests/run-openclaw-runs-tests.sh
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-$TESTS_DIR/../../scripts/openclaw-runs.ps1}"

if [ ! -f "$SCRIPT" ]; then
  echo "cannot find openclaw-runs.ps1 at $SCRIPT" >&2
  exit 1
fi

command -v pwsh >/dev/null 2>&1 || { echo "pwsh is required" >&2; exit 1; }

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; echo "         expected: $2"; echo "         actual:   $3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "openclaw-runs.ps1 regression tests"

echo
echo "an empty history summarises to zero without dividing by zero"
out=$(pwsh -NoProfile -Command "
  . '$SCRIPT'
  \$s = Get-RunHistorySummary -Rows @()
  Write-Output \"\$(\$s.Total)|\$(\$s.Done)|\$(\$s.Failed)|\$(\$null -eq \$s.SuccessRate)|\$(\$null -eq \$s.MedianDuration)\"
")
is "total/done/failed/successRate/median all read as empty-safe" "$out" "0|0|0|True|True"

echo
echo "median and p90 duration are computed from durationSeconds only"
out=$(pwsh -NoProfile -Command "
  . '$SCRIPT'
  \$rows = 1..9 | ForEach-Object {
    [pscustomobject]@{ status = 'done'; attempts = 0; durationSeconds = \$_ * 100
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$true; claudeReviewPassed = \$true; uiScreenshotsIncluded = \$true } }
  }
  \$s = Get-RunHistorySummary -Rows \$rows
  Write-Output \"\$(\$s.MedianDuration)|\$(\$s.P90Duration)\"
")
is "median is the middle value, p90 near the top of a 1..9*100 series" "$out" "500|820"

echo
echo "a row with no durationSeconds is excluded from the duration stats"
out=$(pwsh -NoProfile -Command "
  . '$SCRIPT'
  \$rows = @(
    [pscustomobject]@{ status = 'done'; attempts = 0; durationSeconds = 100
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$true; claudeReviewPassed = \$true; uiScreenshotsIncluded = \$true } },
    [pscustomobject]@{ status = 'done'; attempts = 0; durationSeconds = \$null
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$true; claudeReviewPassed = \$true; uiScreenshotsIncluded = \$true } }
  )
  \$s = Get-RunHistorySummary -Rows \$rows
  Write-Output \$s.MedianDuration
")
is "the null-duration row does not skew the median" "$out" "100"

echo
echo "attempt distribution counts runs by attempts, and restarts are attempts >= 1"
out=$(pwsh -NoProfile -Command "
  . '$SCRIPT'
  \$rows = @(
    [pscustomobject]@{ status = 'done'; attempts = 0; durationSeconds = 1
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$true; claudeReviewPassed = \$true; uiScreenshotsIncluded = \$true } },
    [pscustomobject]@{ status = 'failed'; attempts = 2; durationSeconds = 1
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$false; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false } },
    [pscustomobject]@{ status = 'failed'; attempts = 2; durationSeconds = 1
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$false; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false } }
  )
  \$s = Get-RunHistorySummary -Rows \$rows
  Write-Output \"\$(\$s.AttemptCounts['0'])|\$(\$s.AttemptCounts['2'])|\$(\$s.Restarted)\"
")
is "0-attempt and 2-attempt buckets, restart count" "$out" "1|2|2"

echo
echo "the blocking check is the first false in DoD pipeline order"
out=$(pwsh -NoProfile -Command "
  . '$SCRIPT'
  \$never = [pscustomobject]@{ prCreated = \$false; ciPassed = \$false; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false }
  \$ci    = [pscustomobject]@{ prCreated = \$true; ciPassed = \$false; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false }
  \$review= [pscustomobject]@{ prCreated = \$true; ciPassed = \$true; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false }
  \$allOk = [pscustomobject]@{ prCreated = \$true; ciPassed = \$true; claudeReviewPassed = \$true; uiScreenshotsIncluded = \$true }
  Write-Output \"\$(Get-BlockingCheck \$never)|\$(Get-BlockingCheck \$ci)|\$(Get-BlockingCheck \$review)|\$(Get-BlockingCheck \$allOk)\"
")
is "never-got-a-PR, blocked-on-CI, blocked-on-review, none" "$out" "prCreated|ciPassed|claudeReviewPassed|"

echo
echo "the top blocker is the most common first-false check among failed runs"
out=$(pwsh -NoProfile -Command "
  . '$SCRIPT'
  \$rows = @(
    [pscustomobject]@{ status = 'failed'; attempts = 3; durationSeconds = 1
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$false; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false } },
    [pscustomobject]@{ status = 'failed'; attempts = 3; durationSeconds = 1
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$false; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false } },
    [pscustomobject]@{ status = 'failed'; attempts = 3; durationSeconds = 1
      checks = [pscustomobject]@{ prCreated = \$true; ciPassed = \$true; claudeReviewPassed = \$false; uiScreenshotsIncluded = \$false } }
  )
  \$s = Get-RunHistorySummary -Rows \$rows
  Write-Output \$s.TopBlocker
")
is "ciPassed blocks two of three failures, so it wins" "$out" "ciPassed"

echo
echo "the CLI path reads a JSONL fixture end to end via -HistoryPath"
cat > "$WORK/history.jsonl" <<'JSONL'
{"taskId":"t1","project":"p","branch":"feat/a","status":"done","startedAt":"2026-01-01T00:00:00Z","endedAt":"2026-01-01T00:10:00Z","durationSeconds":600,"attempts":0,"checks":{"prCreated":true,"ciPassed":true,"claudeReviewPassed":true,"uiScreenshotsIncluded":true},"prNumber":1,"merged":true}
{"taskId":"t2","project":"p","branch":"","status":"failed","startedAt":"2026-01-02T00:00:00Z","endedAt":"2026-01-02T00:05:00Z","durationSeconds":300,"attempts":3,"checks":{"prCreated":false,"ciPassed":false,"claudeReviewPassed":false,"uiScreenshotsIncluded":false},"prNumber":null,"merged":null}
JSONL
cli_out=$(pwsh -NoProfile -File "$SCRIPT" -HistoryPath "$WORK/history.jsonl")
cli_status=$?
is "exits clean" "$cli_status" "0"
is "reports the right run count" "$(echo "$cli_out" | grep -c '^OpenClaw run history - 2 run(s)$')" "1"
is "reports the success rate" "$(echo "$cli_out" | grep -c '50 % success rate')" "1"
is "names the top blocker" "$(echo "$cli_out" | grep -c 'most common blocker: prCreated')" "1"

echo
echo "a missing history file is reported as no runs yet, not an error"
cli_out=$(pwsh -NoProfile -File "$SCRIPT" -HistoryPath "$WORK/does-not-exist.jsonl")
cli_status=$?
is "exits clean" "$cli_status" "0"
is "says no runs recorded yet" "$(echo "$cli_out" | grep -c 'No runs recorded yet')" "1"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
