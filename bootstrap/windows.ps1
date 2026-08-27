# bootstrap/windows.ps1 - set up dotfiles on Windows 11
# Run from an elevated PowerShell 7+ prompt:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\bootstrap\windows.ps1
#
# Or non-elevated if Developer Mode is enabled (for symlinks).

param(
    [switch]$SymlinksOnly
)

$ErrorActionPreference = 'Stop'
$DOTFILES = Split-Path $PSScriptRoot -Parent

function New-Link {
    param($Src, $Dst)
    $dstDir = Split-Path $Dst -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    if (Test-Path $Dst) { Remove-Item $Dst -Recurse -Force }
    New-Item -ItemType SymbolicLink -Path $Dst -Target $Src | Out-Null
    Write-Host "  linked: $Dst -> $Src"
}

# ── Symlinks ──────────────────────────────────────────────────────────────────

Write-Host "Creating symlinks..."

# WezTerm - directory symlink so wezterm.lua can require() sibling modules.
# ~\.config\wezterm\wezterm.lua takes precedence over ~\.wezterm.lua.
New-Link "$DOTFILES\.config\wezterm" "$env:USERPROFILE\.config\wezterm"
if (Test-Path "$env:USERPROFILE\.wezterm.lua") {
    Remove-Item "$env:USERPROFILE\.wezterm.lua" -Force
    Write-Host "  removed legacy: $env:USERPROFILE\.wezterm.lua"
}

# Neovim - AppData\Local\nvim
New-Link "$DOTFILES\.config\nvim" "$env:LOCALAPPDATA\nvim"

# AGENTS.md → Claude global config
$claudeDir = "$env:USERPROFILE\.claude"
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
New-Link "$DOTFILES\AGENTS.md" "$claudeDir\CLAUDE.md"

# CLAUDE.md in repo → AGENTS.md (same-directory symlink)
$claudeMd = "$DOTFILES\CLAUDE.md"
if (Test-Path $claudeMd) { Remove-Item $claudeMd -Force }
New-Item -ItemType SymbolicLink -Path $claudeMd -Target "$DOTFILES\AGENTS.md" | Out-Null
Write-Host "  linked: $claudeMd -> AGENTS.md"

if ($SymlinksOnly) { Write-Host "Done (symlinks only)."; exit 0 }

# ── Winget packages ───────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Installing packages via winget..."

$packages = @(
    @{ Id = 'wez.wezterm';               Name = 'WezTerm' },
    @{ Id = 'Neovim.Neovim';             Name = 'Neovim' },
    @{ Id = 'Git.Git';                   Name = 'Git' },
    @{ Id = 'BurntSushi.ripgrep.MSVC';   Name = 'ripgrep' },
    @{ Id = 'sharkdp.fd';                Name = 'fd' },
    @{ Id = 'junegunn.fzf';              Name = 'fzf' },
    @{ Id = 'ajeetdsouza.zoxide';        Name = 'zoxide' },
    @{ Id = 'sharkdp.bat';               Name = 'bat' },
    @{ Id = 'eza-community.eza';         Name = 'eza' },
    @{ Id = 'JesseDuffield.lazygit';     Name = 'lazygit' },
    @{ Id = 'OpenJS.NodeJS.LTS';         Name = 'Node.js LTS' },
    @{ Id = 'GoLang.Go';                 Name = 'Go' },
    @{ Id = 'Microsoft.PowerShell';      Name = 'PowerShell 7' }
)

foreach ($pkg in $packages) {
    Write-Host "  Installing $($pkg.Name)..."
    winget install --id $pkg.Id -e --accept-source-agreements --accept-package-agreements --silent 2>$null
    if (-not $?) { Write-Warning "  $($pkg.Name) may already be installed or failed - continuing." }
}

# ── Agent CLIs (npm) ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Installing agent CLIs via npm..."
foreach ($cli in @('@anthropic-ai/claude-code', '@fission-ai/openspec')) {
    Write-Host "  Installing $cli..."
    npm install -g $cli
    if (-not $?) { Write-Warning "  $cli install failed - continuing." }
}

# ── PowerShell profile ────────────────────────────────────────────────────────

$profileContent = @'

# dotfiles
Invoke-Expression (& { (zoxide init powershell | Out-String) })
'@

if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

if (-not (Select-String -Path $PROFILE -Pattern 'dotfiles' -Quiet)) {
    Add-Content -Path $PROFILE -Value $profileContent
    Write-Host "Updated PowerShell profile: $PROFILE"
}

$manContent = @'

# man - fall back to --help for non-cmdlets (nvim, git, etc.)
Remove-Alias man -Force -ErrorAction SilentlyContinue
function man {
    param([string]$Command)
    $cmdlet = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmdlet -and $cmdlet.CommandType -in 'Cmdlet', 'Function', 'Alias') {
        Get-Help $Command -Full
    } elseif ($cmdlet) {
        & $Command --help
    } else {
        Write-Error "man: no entry for $Command"
    }
}
'@

if (-not (Select-String -Path $PROFILE -Pattern 'fall back to --help' -Quiet)) {
    Add-Content -Path $PROFILE -Value $manContent
    Write-Host "Updated PowerShell profile: added man function"
}

Write-Host ""
Write-Host "Bootstrap complete. Restart your terminal."
