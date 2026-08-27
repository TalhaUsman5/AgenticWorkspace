#Requires -Version 7
<#
.SYNOPSIS
    Windows workspace installer - installs all tools needed for agentic development.

.DESCRIPTION
    Installs (idempotently via winget/npm/gh):
      - Git + GitHub CLI
      - WezTerm
      - Neovim
      - Visual Studio Code + Claude Code extension + GitHub Copilot extensions
      - Claude for Desktop
      - Agentic Project Tracker  (latest GitHub release)
      - Claude CLI  (@anthropic-ai/claude-code)
      - OpenSpec CLI  (@fission-ai/openspec)
      - GitHub Copilot CLI  (gh extension)

    Safe to re-run - already-installed packages are skipped.

.PARAMETER SkipVSCode
    Skip VS Code and its extensions.

.PARAMETER SkipExtensions
    Install VS Code but skip extension installation.

.EXAMPLE
    # Standard install (elevated prompt or Developer Mode enabled)
    pwsh -File bootstrap\workspace-windows.ps1

    # Skip VS Code entirely
    pwsh -File bootstrap\workspace-windows.ps1 -SkipVSCode
#>

param(
    [switch]$SkipVSCode,
    [switch]$SkipExtensions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # don't abort on individual tool failures

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Header([string]$text) {
    Write-Host ""
    Write-Host "━━━ $text " -ForegroundColor Cyan -NoNewline
    Write-Host ("━" * [Math]::Max(0, 60 - $text.Length)) -ForegroundColor Cyan
}

function Write-Step([string]$text) {
    Write-Host "  → $text" -ForegroundColor White
}

function Write-Ok([string]$text) {
    Write-Host "  ✓ $text" -ForegroundColor Green
}

function Write-Warn([string]$text) {
    Write-Host "  ! $text" -ForegroundColor Yellow
}

function Write-Fail([string]$text) {
    Write-Host "  ✗ $text" -ForegroundColor Red
}

# Refresh PATH in the current session after winget installs
function Update-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

# Install a winget package; skip if already installed
function Install-Winget {
    param(
        [string]$Id,
        [string]$Name,
        [string[]]$ExtraArgs = @()
    )

    Write-Step "Installing $Name ($Id)..."

    # Check if already installed
    $existing = winget list --id $Id --exact 2>$null | Select-String $Id
    if ($existing) {
        Write-Ok "$Name already installed - skipping"
        return
    }

    $wingetArgs = @(
        'install', '--id', $Id,
        '--exact',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--silent'
    ) + $ExtraArgs

    winget @wingetArgs
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {  # -1978335189 = already installed
        Write-Ok "$Name installed"
    } else {
        Write-Warn "$Name install exited $LASTEXITCODE - may need manual install"
    }
}

# ── Preflight ─────────────────────────────────────────────────────────────────

Write-Header "Preflight"

# winget
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Fail "winget not found. Install the App Installer from the Microsoft Store, then re-run."
    exit 1
}
Write-Ok "winget $(winget --version)"

# Elevation check (soft warning - Developer Mode covers symlinks)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn "Not running as Administrator. Some installs may prompt for UAC elevation."
    Write-Warn "Re-run as Admin for a fully silent install, or enable Developer Mode."
}

# ── Core tools ────────────────────────────────────────────────────────────────

Write-Header "Core tools"

Install-Winget -Id 'Microsoft.PowerShell'     -Name 'PowerShell 7'
Install-Winget -Id 'Git.Git'                  -Name 'Git'
Install-Winget -Id 'GitHub.cli'               -Name 'GitHub CLI'
Install-Winget -Id 'OpenJS.NodeJS.LTS'        -Name 'Node.js LTS'
Install-Winget -Id 'wez.wezterm'              -Name 'WezTerm'
Install-Winget -Id 'Neovim.Neovim'            -Name 'Neovim'

Update-Path

# ── Visual Studio Code ────────────────────────────────────────────────────────

if (-not $SkipVSCode) {
    Write-Header "Visual Studio Code"

    Install-Winget -Id 'Microsoft.VisualStudioCode' -Name 'VS Code'
    Update-Path

    if (-not $SkipExtensions) {
        if (Get-Command code -ErrorAction SilentlyContinue) {
            Write-Step "Installing VS Code extensions..."

            $extensions = @(
                @{ Id = 'anthropics.claude-code';  Name = 'Claude Code' },
                @{ Id = 'GitHub.copilot';          Name = 'GitHub Copilot' },
                @{ Id = 'GitHub.copilot-chat';     Name = 'GitHub Copilot Chat' }
            )

            foreach ($ext in $extensions) {
                Write-Step "  Extension: $($ext.Name) ($($ext.Id))"
                code --install-extension $ext.Id --force 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "  $($ext.Name) installed"
                } else {
                    Write-Warn "  $($ext.Name) - check manually in VS Code Extensions tab"
                }
            }
        } else {
            Write-Warn "'code' not on PATH yet. Restart your terminal, then run:"
            Write-Warn "  code --install-extension anthropics.claude-code"
            Write-Warn "  code --install-extension GitHub.copilot"
            Write-Warn "  code --install-extension GitHub.copilot-chat"
        }
    }
}

# ── Claude for Desktop ────────────────────────────────────────────────────────

Write-Header "Claude for Desktop"

Install-Winget -Id 'Anthropic.Claude' -Name 'Claude for Desktop'

# ── Agentic Project Tracker ───────────────────────────────────────────────────

Write-Header "Agentic Project Tracker"

$aptRepo = 'Bimzy27/AgenticProjectTracker'

# The NSIS installer registers per-user; the uninstall entry carries the version.
function Get-AgenticProjectTrackerVersion {
    $entry = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'Agentic Project Tracker*' } |
        Select-Object -First 1
    if ($entry -and $entry.PSObject.Properties['DisplayVersion']) { return $entry.DisplayVersion }
    return $null
}

try {
    $release = Invoke-RestMethod "https://api.github.com/repos/$aptRepo/releases/latest" -ErrorAction Stop
    $latestVersion = $release.tag_name -replace '^v', ''
    $installedVersion = Get-AgenticProjectTrackerVersion

    if ($installedVersion -eq $latestVersion) {
        Write-Ok "Agentic Project Tracker $installedVersion already installed - skipping"
    } else {
        if ($installedVersion) {
            Write-Step "Updating Agentic Project Tracker $installedVersion -> $latestVersion..."
        } else {
            Write-Step "Installing Agentic Project Tracker $latestVersion..."
        }

        $asset = $release.assets |
            Where-Object { $_.name -like 'AgenticProjectTracker-Setup-*.exe' } |
            Select-Object -First 1
        if (-not $asset) { throw "release $($release.tag_name) has no installer asset" }

        $installerPath = Join-Path ([IO.Path]::GetTempPath()) $asset.name
        Write-Step "Downloading $($asset.name)..."
        Invoke-WebRequest $asset.browser_download_url -OutFile $installerPath -ErrorAction Stop

        # /S = NSIS silent install; an existing install is upgraded in place
        $proc = Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -PassThru
        Remove-Item $installerPath -ErrorAction SilentlyContinue

        if ($proc.ExitCode -eq 0) {
            Write-Ok "Agentic Project Tracker $latestVersion installed"
        } else {
            Write-Warn "Installer exited $($proc.ExitCode) - install manually from https://github.com/$aptRepo/releases/latest"
        }
    }
} catch {
    Write-Warn "Agentic Project Tracker install failed: $($_.Exception.Message)"
    Write-Warn "Install manually from https://github.com/$aptRepo/releases/latest"
}

# ── Claude CLI ────────────────────────────────────────────────────────────────

Write-Header "Claude CLI  (@anthropic-ai/claude-code)"

if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Step "Installing via npm..."
    npm install -g @anthropic-ai/claude-code
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Claude CLI installed"
        $claudeVersion = claude --version 2>$null
        if ($claudeVersion) { Write-Ok "Version: $claudeVersion" }
    } else {
        Write-Fail "npm install failed - check Node.js installation"
    }
} else {
    Write-Warn "npm not on PATH. Restart your terminal after Node.js install, then run:"
    Write-Warn "  npm install -g @anthropic-ai/claude-code"
}

# ── OpenSpec CLI ──────────────────────────────────────────────────────────────

Write-Header "OpenSpec CLI"

if (Get-Command npm -ErrorAction SilentlyContinue) {
    $npmClis = @(
        @{ Pkg = '@fission-ai/openspec';  Name = 'OpenSpec CLI'; Cmd = 'openspec' }
    )

    foreach ($cli in $npmClis) {
        Write-Step "Installing $($cli.Name) ($($cli.Pkg))..."
        npm install -g $cli.Pkg
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$($cli.Name) installed"
        } else {
            Write-Warn "$($cli.Name) install failed - try manually: npm install -g $($cli.Pkg)"
        }
    }
} else {
    Write-Warn "npm not on PATH. Restart your terminal after Node.js install, then run:"
    Write-Warn "  npm install -g @fission-ai/openspec"
}

# ── GitHub Copilot CLI ────────────────────────────────────────────────────────

Write-Header "GitHub Copilot CLI  (gh extension)"

if (Get-Command gh -ErrorAction SilentlyContinue) {
    # Check if already authenticated
    $null = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "GitHub CLI not authenticated. Run the following, then re-run this script:"
        Write-Warn "  gh auth login"
        Write-Warn "Copilot CLI extension will be installed after authentication."
    } else {
        Write-Step "Installing gh copilot extension..."
        gh extension install github/gh-copilot 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "GitHub Copilot CLI installed  (gh copilot suggest / gh copilot explain)"
        } else {
            # May already be installed
            $existing = gh extension list 2>$null | Select-String 'gh-copilot'
            if ($existing) {
                Write-Ok "GitHub Copilot CLI already installed"
                gh extension upgrade github/gh-copilot 2>$null
            } else {
                Write-Warn "gh extension install failed - try manually: gh extension install github/gh-copilot"
            }
        }
    }
} else {
    Write-Warn "'gh' not on PATH. Restart terminal after GitHub CLI install, then run:"
    Write-Warn "  gh auth login"
    Write-Warn "  gh extension install github/gh-copilot"
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Header "Summary"

$checks = @(
    @{ Cmd = 'git';     Label = 'Git' },
    @{ Cmd = 'gh';      Label = 'GitHub CLI' },
    @{ Cmd = 'nvim';    Label = 'Neovim' },
    @{ Cmd = 'node';    Label = 'Node.js' },
    @{ Cmd = 'npm';     Label = 'npm' },
    @{ Cmd = 'claude';   Label = 'Claude CLI' },
    @{ Cmd = 'openspec'; Label = 'OpenSpec CLI' },
    @{ Cmd = 'code';     Label = 'VS Code' }
)

Update-Path

foreach ($check in $checks) {
    $cmd = Get-Command $check.Cmd -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Ok "$($check.Label)  ($($cmd.Source))"
    } else {
        Write-Warn "$($check.Label)  - not found on PATH (may need terminal restart)"
    }
}

# Agentic Project Tracker check
$aptVersion = Get-AgenticProjectTrackerVersion
if ($aptVersion) {
    Write-Ok "Agentic Project Tracker $aptVersion"
} else {
    Write-Warn "Agentic Project Tracker  - not installed (see https://github.com/$aptRepo/releases/latest)"
}

# gh copilot check
$copilotExt = gh extension list 2>$null | Select-String 'gh-copilot'
if ($copilotExt) {
    Write-Ok "GitHub Copilot CLI  (gh copilot)"
} else {
    Write-Warn "GitHub Copilot CLI  - run 'gh auth login' then 'gh extension install github/gh-copilot'"
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Restart your terminal to pick up all PATH changes"
Write-Host "  2. Run:  gh auth login"
Write-Host "  3. Run:  claude              # authenticate with Anthropic"
Write-Host "  4. Run dotfiles setup:  .\bootstrap\windows.ps1"
Write-Host ""
Write-Host "Copilot CLI usage:"
Write-Host "  gh copilot suggest 'create a dockerfile for a node app'"
Write-Host "  gh copilot explain 'git rebase -i HEAD~3'"
Write-Host ""
