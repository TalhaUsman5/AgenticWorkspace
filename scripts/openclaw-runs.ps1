#Requires -Version 7.0
<#
.SYNOPSIS
    Summarises OpenClaw's durable run-history log.

.DESCRIPTION
    Reads ~/.openclaw/run-history.jsonl - one row per run that reached a
    terminal state, appended by check-agents.sh - and reports the numbers
    the unattended pipeline otherwise has none of: total runs, success rate,
    how long a run takes, how often a run needs a restart, and which
    Definition-of-Done check most often blocks a run from reaching `done`.

    That last number is the useful one: it tells you whether runs are
    failing on CI, on review, or never getting far enough to open a PR at
    all, without reading a single tmux transcript.

    Read-only - nothing is installed, written, or restarted.

.PARAMETER Distro
    Which WSL distro holds the history file. Defaults to Ubuntu, matching
    bootstrap/openclaw-wsl.ps1 and scripts/openclaw-doctor.ps1.

.PARAMETER HistoryPath
    Read a run-history.jsonl file directly from disk instead of shelling
    into WSL. Exists so this script itself can be exercised without a live
    WSL distro; production use only needs -Distro.

.EXAMPLE
    .\scripts\openclaw-runs.ps1
    .\scripts\openclaw-runs.ps1 -Distro Ubuntu-22.04

.NOTES
    Exits 0 once a summary is produced (including "no runs yet"), 1 when the
    history file could not be read at all.
#>

param(
    [string]$Distro = 'Ubuntu',
    [string]$HistoryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Definition-of-Done order. A row's first false check in this order is the
# stage that blocked it - false earlier means the run never got as far as
# the later checks, which is the "never got far enough to record anything"
# signal the summary calls out separately from a CI or review failure.
$CheckOrder = @('prCreated', 'ciPassed', 'claudeReviewPassed', 'uiScreenshotsIncluded')

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return $sorted[0] }
    $rank = $Percentile * ($sorted.Count - 1)
    $lower = [Math]::Floor($rank)
    $upper = [Math]::Ceiling($rank)
    if ($lower -eq $upper) { return $sorted[$lower] }
    $frac = $rank - $lower
    return $sorted[$lower] + ($sorted[$upper] - $sorted[$lower]) * $frac
}

function Format-Duration {
    param($Seconds)
    if ($null -eq $Seconds) { return 'n/a' }
    $ts = [TimeSpan]::FromSeconds([double]$Seconds)
    if ($ts.TotalHours -ge 1) { return ('{0}h{1:00}m' -f [Math]::Floor($ts.TotalHours), $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1) { return ('{0}m{1:00}s' -f [Math]::Floor($ts.TotalMinutes), $ts.Seconds) }
    return "$([Math]::Round([double]$Seconds))s"
}

function Get-BlockingCheck {
    param($Checks)
    foreach ($name in $CheckOrder) {
        if ($Checks.$name -ne $true) { return $name }
    }
    return $null
}

# Pure function over already-parsed rows, kept separate from the WSL/file
# read below so it can be exercised directly against synthetic data.
function Get-RunHistorySummary {
    param([object[]]$Rows)

    $total = $Rows.Count
    $summary = [ordered]@{
        Total          = $total
        Done           = 0
        Failed         = 0
        SuccessRate    = $null
        MedianDuration = $null
        P90Duration    = $null
        AttemptCounts  = [ordered]@{}
        Restarted      = 0
        Blockers       = [ordered]@{}
        TopBlocker     = $null
    }
    if ($total -eq 0) { return [pscustomobject]$summary }

    $doneRows = @($Rows | Where-Object { $_.status -eq 'done' })
    $failedRows = @($Rows | Where-Object { $_.status -eq 'failed' })
    $summary.Done = $doneRows.Count
    $summary.Failed = $failedRows.Count
    $summary.SuccessRate = $summary.Done / $total

    $durations = @($Rows | Where-Object { $null -ne $_.durationSeconds } | ForEach-Object { [double]$_.durationSeconds })
    $summary.MedianDuration = Get-Percentile -Values $durations -Percentile 0.5
    $summary.P90Duration = Get-Percentile -Values $durations -Percentile 0.9

    foreach ($row in $Rows) {
        $key = "$([int]$row.attempts)"
        if (-not $summary.AttemptCounts.Contains($key)) { $summary.AttemptCounts[$key] = 0 }
        $summary.AttemptCounts[$key]++
        if ([int]$row.attempts -ge 1) { $summary.Restarted++ }
    }

    foreach ($name in $CheckOrder) { $summary.Blockers[$name] = 0 }
    foreach ($row in $failedRows) {
        $blocker = Get-BlockingCheck -Checks $row.checks
        if ($blocker) { $summary.Blockers[$blocker]++ }
    }
    if ($failedRows.Count -gt 0) {
        $top = $summary.Blockers.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
        if ($top.Value -gt 0) { $summary.TopBlocker = $top.Key }
    }

    return [pscustomobject]$summary
}

function Read-RunHistoryContent {
    param([string]$Distro, [string]$HistoryPath)

    # The leading `,` stops PowerShell's normal pipeline unrolling from
    # collapsing a zero-element array result down to $null on the way out -
    # without it, "the file exists but has no rows yet" becomes
    # indistinguishable from "could not read the file at all" at the call site.
    if ($HistoryPath) {
        if (-not (Test-Path $HistoryPath)) { return ,@() }
        return ,@(Get-Content -Path $HistoryPath | Where-Object { $_.Trim() })
    }

    $raw = wsl -d $Distro -e bash -c 'cat "$HOME/.openclaw/run-history.jsonl" 2>/dev/null'
    if ($LASTEXITCODE -ne 0 -and -not $raw) { return $null }
    return ,@($raw | Where-Object { $_ -and $_.Trim() })
}

# Only run the report when executed directly - lets a test dot-source this
# file and call Get-RunHistorySummary / Get-BlockingCheck in isolation
# without shelling into WSL or needing a history file on disk.
if ($MyInvocation.InvocationName -ne '.') {
    $lines = Read-RunHistoryContent -Distro $Distro -HistoryPath $HistoryPath
    if ($null -eq $lines) {
        Write-Host "Could not read run history inside '$Distro' - is the distro reachable?" -ForegroundColor Red
        exit 1
    }

    $rows = @()
    foreach ($line in $lines) {
        try { $rows += (ConvertFrom-Json -InputObject $line) }
        catch { Write-Host "Skipping unparsable run-history row: $line" -ForegroundColor DarkYellow }
    }

    if ($rows.Count -eq 0) {
        Write-Host 'No runs recorded yet in ~/.openclaw/run-history.jsonl' -ForegroundColor DarkYellow
        exit 0
    }

    $summary = Get-RunHistorySummary -Rows $rows

    Write-Host "OpenClaw run history - $($summary.Total) run(s)" -ForegroundColor Cyan
    Write-Host ('  {0} done, {1} failed - {2:P0} success rate' -f $summary.Done, $summary.Failed, $summary.SuccessRate)
    Write-Host ('  duration: median {0}, p90 {1}' -f (Format-Duration $summary.MedianDuration), (Format-Duration $summary.P90Duration))
    Write-Host ('  {0} of {1} run(s) needed at least one restart' -f $summary.Restarted, $summary.Total)

    Write-Host "`n  attempts before terminal:"
    foreach ($key in ($summary.AttemptCounts.Keys | Sort-Object { [int]$_ })) {
        Write-Host ('    {0} attempt(s): {1}' -f $key, $summary.AttemptCounts[$key])
    }

    Write-Host "`n  where failed runs got blocked:"
    foreach ($name in $CheckOrder) {
        Write-Host ('    {0}: {1}' -f $name, $summary.Blockers[$name])
    }
    if ($summary.TopBlocker) {
        Write-Host ("  most common blocker: $($summary.TopBlocker)") -ForegroundColor Yellow
    } elseif ($summary.Failed -gt 0) {
        Write-Host '  no single check accounts for the failures - inspect the failed rows by hand' -ForegroundColor Yellow
    }

    exit 0
}
