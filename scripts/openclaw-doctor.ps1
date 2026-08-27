#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only readiness check for the OpenClaw unattended pipeline.

.DESCRIPTION
    Answers "is the unattended pipeline actually working?" in one command,
    instead of a dozen ad-hoc `wsl -d <distro> -- ...` probes.

    Checks, grouped:
      - Distro: the WSL distro exists, has a real default user, runs systemd
      - Binaries: node/npm/jq/tmux/gh/openclaw/claude are installed inside it
      - Deployment: check-agents.sh, the patrol-loop skill, and this repo's
        Claude Code skills/AGENTS.md are actually deployed
      - Runtime: the gateway answers health checks, is bound to loopback only
        (verified against live listening sockets, not just config), and the
        monitor timer + lingering are enabled
      - Auth: gh and claude are both logged in

    Every check is inspection only - nothing is installed, written, or
    restarted.

.PARAMETER Distro
    Which WSL distro to check. Defaults to Ubuntu, matching
    bootstrap/openclaw-wsl.ps1.

.EXAMPLE
    .\scripts\openclaw-doctor.ps1
    .\scripts\openclaw-doctor.ps1 -Distro Ubuntu-22.04

.NOTES
    Exits 0 when every check passes, 1 when any check fails.
#>

param(
    [string]$Distro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Check {
    param(
        [string]$Group,
        [string]$Title,
        [ValidateSet('PASS', 'FAIL', 'SKIP')]
        [string]$Status,
        [string]$Detail,
        [string]$Remedy
    )
    $marker = switch ($Status) {
        'PASS' { '[PASS]' }
        'FAIL' { '[FAIL]' }
        'SKIP' { '[SKIP]' }
    }
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'DarkYellow' }
    }
    $line = "$marker $Group > $Title"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $color
    if ($Status -eq 'FAIL' -and $Remedy) {
        Write-Host "       remedy: $Remedy" -ForegroundColor Yellow
    }
}

# `wsl -l -q` emits UTF-16LE padded with NULs; strip them before comparing,
# or every name comes back looking like "U b u n t u". Same helper as
# bootstrap/openclaw-wsl.ps1.
function Get-WslDistro {
    $raw = (wsl -l -q 2>$null) -join "`n"
    if (-not $raw) { return @() }
    return ($raw -replace "`0", '') -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
}

$systemDistros = @('docker-desktop', 'docker-desktop-data', 'rancher-desktop', 'rancher-desktop-data')

# Ordered so the report reads Distro -> Binaries -> Deployment -> Runtime -> Auth
# regardless of what order the bash side emits results in.
$checkMeta = [ordered]@{
    distro_exists        = @{ Group = 'Distro'; Title = "WSL distro '$Distro' exists and is not a Docker/Rancher utility distro"; Remedy = "Run bootstrap\openclaw-wsl.ps1 (pass -Distro <name> to target something other than Ubuntu)" }
    default_user         = @{ Group = 'Distro'; Title = 'Default user is a real account, not root'; Remedy = "Create a user account: wsl -d $Distro, then re-run bootstrap\openclaw-wsl.ps1 -SkipWslInstall" }
    systemd_pid1          = @{ Group = 'Distro'; Title = 'systemd is PID 1 inside the distro'; Remedy = 'Enable systemd in /etc/wsl.conf ([boot] systemd=true), run `wsl --shutdown`, or re-run bootstrap\openclaw-wsl.ps1' }
    bin_node              = @{ Group = 'Binaries'; Title = 'node >= 22 is installed'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 to install Node.js 22+' }
    bin_npm               = @{ Group = 'Binaries'; Title = 'npm is installed'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 to install Node.js 22+ (bundles npm)' }
    bin_jq                = @{ Group = 'Binaries'; Title = 'jq is installed'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 (installs jq via apt)' }
    bin_tmux              = @{ Group = 'Binaries'; Title = 'tmux is installed'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 (installs tmux via apt)' }
    bin_gh                = @{ Group = 'Binaries'; Title = 'gh is installed'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 (installs the GitHub CLI)' }
    bin_openclaw          = @{ Group = 'Binaries'; Title = 'openclaw is installed'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 (npm install -g openclaw@latest)' }
    bin_claude            = @{ Group = 'Binaries'; Title = 'claude is installed'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 (npm install -g @anthropic-ai/claude-code)' }
    deploy_check_agents   = @{ Group = 'Deployment'; Title = '~/.openclaw/scripts/check-agents.sh exists and is executable'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 to deploy .openclaw/check-agents.sh' }
    deploy_patrol_loop    = @{ Group = 'Deployment'; Title = 'patrol-loop is ready in `openclaw skills list`'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 to deploy .openclaw/skills/patrol-loop/SKILL.md' }
    deploy_claude_skills  = @{ Group = 'Deployment'; Title = '~/.claude/skills contains next, patrol, and ship'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 to deploy claude/skills/ into WSL' }
    deploy_agents_md      = @{ Group = 'Deployment'; Title = '~/.claude/AGENTS.md exists'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 to deploy AGENTS.md into WSL' }
    runtime_health        = @{ Group = 'Runtime'; Title = 'Gateway responds to `openclaw health`'; Remedy = "Finish onboarding or start the service: wsl -d $Distro -- openclaw onboard --install-daemon" }
    runtime_bind          = @{ Group = 'Runtime'; Title = 'Gateway is bound to loopback only (verified via ss -ltn)'; Remedy = "Re-run onboarding and bind to loopback only, then: wsl -d $Distro -- openclaw daemon restart" }
    runtime_timer          = @{ Group = 'Runtime'; Title = 'openclaw-check-agents.timer is enabled and active'; Remedy = 'Run bootstrap\openclaw-wsl.ps1 to install and enable the monitor timer' }
    runtime_linger         = @{ Group = 'Runtime'; Title = 'Lingering is enabled for the user'; Remedy = "wsl -d $Distro -u root -- loginctl enable-linger <user>" }
    auth_gh                = @{ Group = 'Auth'; Title = 'gh reports a logged-in account'; Remedy = "wsl -d $Distro -- gh auth login" }
    auth_claude             = @{ Group = 'Auth'; Title = 'claude is authenticated'; Remedy = "wsl -d $Distro -- claude  (follow the login prompt, or: claude auth login)" }
}

function Write-Skipped {
    param([string[]]$Keys, [string]$Because)
    foreach ($key in $Keys) {
        $meta = $checkMeta[$key]
        Write-Check -Group $meta.Group -Title $meta.Title -Status 'SKIP' -Detail $Because
    }
}

$failed = $false

# 1. Distro exists and is not a Docker/Rancher utility distro -------------
$distros = Get-WslDistro
$usable = $distros | Where-Object { $systemDistros -notcontains $_ }

if ($distros -contains $Distro -and $systemDistros -notcontains $Distro) {
    Write-Check -Group 'Distro' -Title $checkMeta['distro_exists'].Title -Status 'PASS'
} else {
    $detail = if ($systemDistros -contains $Distro) {
        "'$Distro' is a Docker/Rancher utility distro, not a usable target"
    } elseif ($usable) {
        "not found; other distros present: $($usable -join ', ')"
    } else {
        'not found; no usable distro installed'
    }
    Write-Check -Group 'Distro' -Title $checkMeta['distro_exists'].Title -Status 'FAIL' -Detail $detail -Remedy $checkMeta['distro_exists'].Remedy
    $remainingKeys = $checkMeta.Keys | Where-Object { $_ -ne 'distro_exists' }
    Write-Skipped -Keys $remainingKeys -Because "distro '$Distro' is not available"
    exit 1
}

# 2. Everything else runs as one script inside the distro -----------------
# Single-quoted here-string: no PowerShell interpolation, so bash's own `$`
# passes through untouched. Bundled into one `wsl -d ... -e bash -c` call
# rather than one invocation per check, since each `wsl` call pays its own
# startup cost.
$diagnosticScript = @'
set -uo pipefail

emit() { printf 'RESULT|%s|%s|%s\n' "$1" "$2" "$3"; }

who=$(whoami 2>/dev/null || echo "")
if [ -n "$who" ] && [ "$who" != "root" ]; then
  emit default_user PASS "$who"
else
  emit default_user FAIL "${who:-unknown}"
fi

pid1=$(ps -p 1 -o comm= 2>/dev/null || echo "")
if [ "$pid1" = "systemd" ]; then
  emit systemd_pid1 PASS "pid 1 is systemd"
else
  emit systemd_pid1 FAIL "pid 1 is '${pid1:-unknown}'"
fi

check_bin() {
  key="$1"; bin="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    emit "$key" FAIL "not found"
    return
  fi
  ver=""
  case "$bin" in
    node) ver=$(node -v 2>/dev/null) ;;
    npm) ver=$(npm -v 2>/dev/null) ;;
    jq) ver=$(jq --version 2>/dev/null) ;;
    tmux) ver=$(tmux -V 2>/dev/null) ;;
    gh) ver=$(gh --version 2>/dev/null | head -1) ;;
    openclaw) ver=$(openclaw --version 2>/dev/null) ;;
    claude) ver=$(claude --version 2>/dev/null) ;;
  esac
  if [ "$bin" = "node" ]; then
    major=$(printf '%s' "$ver" | sed -E 's/^v?([0-9]+).*/\1/')
    if [ -n "$major" ] && [ "$major" -ge 22 ] 2>/dev/null; then
      emit "$key" PASS "$ver"
    else
      emit "$key" FAIL "$ver (need >= 22)"
    fi
  else
    emit "$key" PASS "$ver"
  fi
}
check_bin bin_node node
check_bin bin_npm npm
check_bin bin_jq jq
check_bin bin_tmux tmux
check_bin bin_gh gh
check_bin bin_openclaw openclaw
check_bin bin_claude claude

if [ -x "$HOME/.openclaw/scripts/check-agents.sh" ]; then
  emit deploy_check_agents PASS "executable"
elif [ -e "$HOME/.openclaw/scripts/check-agents.sh" ]; then
  emit deploy_check_agents FAIL "exists but not executable"
else
  emit deploy_check_agents FAIL "missing"
fi

if command -v openclaw >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  skills_json=$(openclaw skills list --json 2>/dev/null || echo "")
  eligible=$(printf '%s' "$skills_json" | jq -r '[.skills[]? | select(.name=="patrol-loop")][0].eligible // "missing"' 2>/dev/null || echo "")
  if [ "$eligible" = "true" ]; then
    emit deploy_patrol_loop PASS "eligible"
  elif [ "$eligible" = "missing" ] || [ -z "$eligible" ]; then
    emit deploy_patrol_loop FAIL "not listed"
  else
    emit deploy_patrol_loop FAIL "listed but not eligible"
  fi
else
  emit deploy_patrol_loop FAIL "openclaw or jq not installed"
fi

missing_skills=""
for s in next patrol ship; do
  [ -d "$HOME/.claude/skills/$s" ] || missing_skills="$missing_skills $s"
done
if [ -z "$missing_skills" ]; then
  emit deploy_claude_skills PASS "next, patrol, ship present"
else
  emit deploy_claude_skills FAIL "missing:$missing_skills"
fi

if [ -f "$HOME/.claude/AGENTS.md" ]; then
  emit deploy_agents_md PASS "present"
else
  emit deploy_agents_md FAIL "missing"
fi

if command -v openclaw >/dev/null 2>&1; then
  health_out=$(openclaw health --json 2>/dev/null)
  health_rc=$?
  if [ $health_rc -eq 0 ]; then
    if command -v jq >/dev/null 2>&1; then
      ok=$(printf '%s' "$health_out" | jq -r '.ok // false' 2>/dev/null || echo "false")
    else
      ok="true"
    fi
    if [ "$ok" = "true" ]; then
      emit runtime_health PASS "ok"
    else
      emit runtime_health FAIL "gateway reported not ok"
    fi
  else
    health_err=$(openclaw health 2>&1 >/dev/null | head -1)
    emit runtime_health FAIL "${health_err:-command failed (exit $health_rc)}"
  fi
else
  emit runtime_health FAIL "openclaw not installed"
fi

if command -v openclaw >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
  status_json=$(openclaw gateway status --json 2>/dev/null || echo "")
  port=$(printf '%s' "$status_json" | jq -r '.gateway.port // empty' 2>/dev/null || echo "")
  if [ -z "$port" ]; then
    emit runtime_bind FAIL "gateway port unknown - is the service installed?"
  else
    listeners=$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -E ":${port}\$" || true)
    if [ -z "$listeners" ]; then
      emit runtime_bind FAIL "no listener found on port $port"
    else
      wildcard=$(printf '%s\n' "$listeners" | grep -E '^(0\.0\.0\.0|\*|\[::\]):' || true)
      if [ -n "$wildcard" ]; then
        emit runtime_bind FAIL "bound to all interfaces on port $port"
      else
        emit runtime_bind PASS "loopback only on port $port"
      fi
    fi
  fi
else
  emit runtime_bind FAIL "openclaw, jq, or ss not available"
fi

timer_enabled=$(systemctl --user is-enabled openclaw-check-agents.timer 2>/dev/null || echo "not-found")
timer_active=$(systemctl --user is-active openclaw-check-agents.timer 2>/dev/null || echo "not-found")
if [ "$timer_enabled" = "enabled" ] && [ "$timer_active" = "active" ]; then
  emit runtime_timer PASS "enabled, active"
else
  emit runtime_timer FAIL "enabled=$timer_enabled active=$timer_active"
fi

linger=$(loginctl show-user "$who" -p Linger 2>/dev/null || echo "")
if [ "$linger" = "Linger=yes" ]; then
  emit runtime_linger PASS "enabled"
else
  emit runtime_linger FAIL "${linger:-unknown}"
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    emit auth_gh PASS "logged in"
  else
    emit auth_gh FAIL "not logged in"
  fi
else
  emit auth_gh FAIL "gh not installed"
fi

if command -v claude >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    claude_json=$(claude auth status 2>/dev/null || echo "")
    logged_in=$(printf '%s' "$claude_json" | jq -r '.loggedIn // false' 2>/dev/null || echo "false")
  else
    logged_in="false"
  fi
  if [ "$logged_in" = "true" ]; then
    emit auth_claude PASS "logged in"
  else
    emit auth_claude FAIL "not logged in"
  fi
else
  emit auth_claude FAIL "claude not installed"
fi
'@

$rawOutput = wsl -d $Distro -e bash -c $diagnosticScript
$wslExit = $LASTEXITCODE
$resultLines = @($rawOutput | Where-Object { $_ -like 'RESULT|*' })

$innerKeys = $checkMeta.Keys | Where-Object { $_ -ne 'distro_exists' }

if ($wslExit -ne 0 -or $resultLines.Count -eq 0) {
    Write-Skipped -Keys $innerKeys -Because "could not run diagnostics inside $Distro (exit $wslExit)"
    exit 1
}

$results = @{}
foreach ($line in $resultLines) {
    $parts = $line -split '\|', 4
    if ($parts.Count -lt 3) { continue }
    $results[$parts[1]] = @{ Status = $parts[2]; Detail = if ($parts.Count -ge 4) { $parts[3] } else { '' } }
}

foreach ($key in $innerKeys) {
    $meta = $checkMeta[$key]
    if (-not $results.ContainsKey($key)) {
        Write-Check -Group $meta.Group -Title $meta.Title -Status 'FAIL' -Detail 'no result reported' -Remedy $meta.Remedy
        $failed = $true
        continue
    }
    $result = $results[$key]
    if ($result.Status -eq 'PASS') {
        Write-Check -Group $meta.Group -Title $meta.Title -Status 'PASS' -Detail $result.Detail
    } else {
        Write-Check -Group $meta.Group -Title $meta.Title -Status 'FAIL' -Detail $result.Detail -Remedy $meta.Remedy
        $failed = $true
    }
}

if ($failed) { exit 1 }
exit 0
