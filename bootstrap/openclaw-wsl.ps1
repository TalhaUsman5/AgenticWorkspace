#Requires -Version 7.0
<#
.SYNOPSIS
    Installs WSL2 + Ubuntu and bootstraps OpenClaw inside it, replacing
    the OpenCode alt-agent slot with OpenClaw as the orchestration layer
    for AgenticWorkspace.

.DESCRIPTION
    Idempotent. Installs, in order:
      - WSL2 with an Ubuntu distro (reboot required on first run)
      - systemd enabled inside that distro
      - Node.js 22+ and the openclaw CLI
      - jq / tmux / gh, which check-agents.sh needs
      - this repo's .openclaw/ skills and monitor script

    Stops short of `openclaw onboard`, which needs live input.

.NOTES
    Run as a STANDARD user, not Administrator - this limits what the
    installer process can access, per OpenClaw's own guidance.
    OpenClaw is experimental software. Its maintainers recommend running
    the gateway on a VM/VPS rather than your main PC if you're security
    conscious. Installing inside WSL2 isolates it from the Windows
    filesystem by default, but is not equivalent to a dedicated box -
    make that call before running this.

.PARAMETER Distro
    Which WSL distro to install into. Defaults to Ubuntu.

.PARAMETER SkipWslInstall
    Skip the WSL2/Ubuntu install step (use after the first reboot).

.EXAMPLE
    .\openclaw-wsl.ps1
    .\openclaw-wsl.ps1 -SkipWslInstall   # after the first reboot
#>

param(
    [string]$Distro = 'Ubuntu',
    [switch]$SkipWslInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  !   $msg" -ForegroundColor Yellow }

# `wsl -l -q` emits UTF-16LE padded with NULs; strip them before comparing,
# or every name comes back looking like "U b u n t u".
function Get-WslDistros {
    $raw = (wsl -l -q 2>$null) -join "`n"
    if (-not $raw) { return @() }
    return ($raw -replace "`0", '') -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
}

# Docker Desktop registers its own utility distros. They are not usable
# general-purpose distros, so they must not count as "WSL is already set up".
$systemDistros = @('docker-desktop', 'docker-desktop-data', 'rancher-desktop', 'rancher-desktop-data')

function Convert-ToWslPath([string]$winPath) {
    $p = $winPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') {
        return "/mnt/$($Matches[1].ToLower())$($Matches[2])"
    }
    return $p
}

# 1. WSL2 + Ubuntu --------------------------------------------------------
if (-not $SkipWslInstall) {
    $distros = Get-WslDistros
    $usable  = $distros | Where-Object { $systemDistros -notcontains $_ }

    if ($distros -contains $Distro) {
        Write-Ok "$Distro already installed"
    } elseif (-not $usable) {
        Write-Step "Installing WSL2 with $Distro (this requires a reboot)"
        if ($distros) {
            Write-Warn2 "Found only system distros: $($distros -join ', ')"
            Write-Warn2 "Those are Docker/Rancher utility distros, not usable for OpenClaw."
        }
        wsl --install -d $Distro
        Write-Host ""
        Write-Host "Reboot now, finish $Distro's first-run prompts (username/password)," -ForegroundColor Yellow
        Write-Host "then re-run: .\openclaw-wsl.ps1 -SkipWslInstall" -ForegroundColor Yellow
        exit 0
    } else {
        Write-Warn2 "$Distro not found, but these distros exist: $($usable -join ', ')"
        Write-Warn2 "Re-run with -Distro <name> to target one of them, or let this install $Distro."
        wsl --install -d $Distro
        Write-Host ""
        Write-Host "Reboot, finish first-run prompts, then re-run with -SkipWslInstall." -ForegroundColor Yellow
        exit 0
    }
}

# Everything below targets one specific distro explicitly. Without -d, `wsl`
# uses the default distro, which on a Docker Desktop machine is often
# docker-desktop.
$wslExec = @('-d', $Distro)

$present = Get-WslDistros
if ($present -notcontains $Distro) {
    Write-Host "Distro '$Distro' is not installed. Run without -SkipWslInstall first." -ForegroundColor Red
    exit 1
}

# 2. Enable systemd inside WSL --------------------------------------------
# /etc/wsl.conf is user state this script did not create, so it is only
# written when systemd is not already enabled, and the previous file is kept.
Write-Step "Enabling systemd in $Distro"
$wslConf = @'
set -euo pipefail
if [ -f /etc/wsl.conf ] && grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf; then
  echo "already-enabled"
  exit 0
fi
if [ -f /etc/wsl.conf ]; then
  cp /etc/wsl.conf "/etc/wsl.conf.bak.$(date +%Y%m%d%H%M%S)"
  echo "backed-up"
fi
cat > /etc/wsl.conf << "EOF"
[boot]
systemd=true
[interop]
enabled=true
appendWindowsPath=true
EOF
echo "written"
'@
$confResult = wsl @wslExec -u root -e bash -c $wslConf
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "Could not configure /etc/wsl.conf"
} elseif ($confResult -match 'already-enabled') {
    Write-Ok "systemd already enabled"
} else {
    if ($confResult -match 'backed-up') { Write-Warn2 "existing /etc/wsl.conf backed up alongside itself" }
    Write-Ok "systemd enabled"
    # Only worth a restart when something actually changed.
    wsl --shutdown
    Start-Sleep -Seconds 3
}

# 3. Node 22+, OpenClaw, and the monitor's dependencies ---------------------
Write-Step "Installing Node.js 22+, OpenClaw, and monitor dependencies"
$installScript = @'
set -euo pipefail

# check-agents.sh hard-requires these three.
sudo apt-get update -qq
sudo apt-get install -y jq tmux curl ca-certificates

NODE_MAJOR=$(node -v 2>/dev/null | sed "s/v//;s/\..*//" || echo "")
if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# gh is not in Ubuntu's default repos.
if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y gh
fi

sudo npm install -g openclaw@latest
mkdir -p ~/.openclaw/workspace/skills ~/.openclaw/scripts ~/.openclaw/state
'@
wsl @wslExec -e bash -c $installScript
if ($LASTEXITCODE -ne 0) {
    Write-Host "Install step failed inside $Distro - see output above." -ForegroundColor Red
    exit 1
}
Write-Ok "OpenClaw and dependencies installed"

# 4. Copy repo config into WSL (skills + monitor script) -------------------
Write-Step "Copying .openclaw/ config into $Distro"
$repoRoot = Split-Path -Parent $PSScriptRoot
$wslRepo  = Convert-ToWslPath $repoRoot

# `~` is expanded by the shell, so these have to run through bash rather than
# being passed as literal arguments to `wsl -e cp`. Passing "~/..." directly
# creates a file whose name is a tilde.
$copyScript = @"
set -euo pipefail
mkdir -p ~/.openclaw/workspace/skills ~/.openclaw/scripts ~/.openclaw/state
cp '$wslRepo/.openclaw/skills/patrol-loop.md' ~/.openclaw/workspace/skills/patrol-loop.md
cp '$wslRepo/.openclaw/check-agents.sh' ~/.openclaw/scripts/check-agents.sh
# Windows checkouts can carry CRLF; a CR in the shebang breaks execution.
sed -i 's/\r$//' ~/.openclaw/scripts/check-agents.sh
chmod +x ~/.openclaw/scripts/check-agents.sh
"@
wsl @wslExec -e bash -c $copyScript
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "Could not copy .openclaw/ config - copy it by hand from $wslRepo/.openclaw/"
} else {
    Write-Ok "patrol-loop.md and check-agents.sh deployed"
}

# 5. Interactive onboarding - must be run by hand ---------------------------
Write-Host ""
Write-Host "WSL + OpenClaw installed. Finish onboarding manually:" -ForegroundColor Green
Write-Host "  wsl -d $Distro"
Write-Host "  openclaw onboard --install-daemon"
Write-Host ""
Write-Host "In the wizard: bind the gateway to loopback only, choose Anthropic as the" -ForegroundColor Yellow
Write-Host "model provider, and connect whichever messaging channel you'll trigger tasks from." -ForegroundColor Yellow
Write-Host ""
Write-Host "Then enable the monitor timer inside WSL - see docs/openclaw-migration.md." -ForegroundColor Yellow
