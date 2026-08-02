# AgenticWorkspace

Dotfiles and agent instructions for an agentic engineering workflow on Windows 11, with optional Linux/Omarchy support.

WezTerm handles terminal multiplexing natively (tabs, panes, copy mode) via a Ctrl+Space leader key.
Catppuccin Mocha is the color scheme across WezTerm, Neovim, and Claude Code.
Claude Code is the primary AI agent harness.

## Structure

```
.
├── setup.ps1                       # One-shot Windows setup (runs all scripts below)
├── AGENTS.md                       # Agent instructions - single source of truth
├── CLAUDE.md                       # Symlink to AGENTS.md (created by install-configs.ps1)
├── claude/
│   ├── settings.json               # Claude Code global settings (theme, etc.)
│   ├── skills/                     # Default agent skills, symlinked to ~/.claude/skills
│   │   ├── typecheck/              # Run the project's type checker, fix until green
│   │   ├── lint/                   # Run the project's linter/formatter, fix until clean
│   │   ├── audit/                  # Dependency CVE scan + secrets scan on the changeset
│   │   ├── police/                 # Enforce POLICE.md behaviour rules against a changeset
│   │   ├── patrol/                 # Full quality gate: typecheck + lint + audit + police + tests
│   │   └── ship/                   # Standardized delivery: gate, review, commit, push, PR
│   └── skills-inactive/            # Staged skills, not loaded until moved into skills/
│       └── next/                   # Autonomous-loop work intake (next -> work -> patrol -> ship)
├── .config/
│   ├── wezterm/wezterm.lua         # Terminal: tabs/panes, Catppuccin Mocha, fullscreen
│   ├── opencode/opencode.json      # OpenCode: theme, model, shared AGENTS.md instructions
│   └── nvim/                       # Neovim: lazy.nvim, oil.nvim, neogit, snacks.nvim, LSP
├── scripts/
│   └── install-configs.ps1         # Symlink configs into system paths, install fonts
└── bootstrap/
    ├── workspace-windows.ps1       # Install dev tools (winget, npm, gh extensions)
    └── windows.ps1                 # Symlink dotfiles, set up shell profile
```

## Quick start

### Windows 11

Run a single script from an elevated PowerShell 7+ prompt (or with Developer Mode enabled):

```powershell
git clone https://github.com/Bimzy27/AgenticWorkspace $env:USERPROFILE\AgenticWorkspace
cd $env:USERPROFILE\AgenticWorkspace
Set-ExecutionPolicy Bypass -Scope Process -Force
.\setup.ps1
```

`setup.ps1` runs in order:
1. `bootstrap\workspace-windows.ps1` - installs all dev tools via winget/npm/gh
2. `bootstrap\windows.ps1` - symlinks dotfiles, sets up PowerShell profile
3. `scripts\install-configs.ps1` - symlinks configs into system paths, installs IosevkaTerm Nerd Font

Each step is idempotent - safe to re-run.

> **Symlinks on Windows**: requires Developer Mode (`Settings -> System -> Developer Mode`) or an elevated prompt.

After setup:

```powershell
gh auth login           # authenticate GitHub CLI
claude                  # authenticate Claude Code
```

### Linux / Omarchy

```bash
git clone https://github.com/Bimzy27/AgenticWorkspace ~/AgenticWorkspace
cd ~/AgenticWorkspace
bash bootstrap/linux.sh
```

## WezTerm keybindings

Leader key: `Ctrl+Space`

| Key | Action |
|-----|--------|
| `Leader + \` | Split pane horizontally |
| `Leader + -` | Split pane vertically |
| `Leader + h/j/k/l` | Navigate panes (vim-style) |
| `Leader + H/J/K/L` | Resize pane |
| `Leader + z` | Zoom/unzoom pane |
| `Leader + x` | Close pane |
| `Leader + c` | New tab |
| `Leader + n/p` | Next/previous tab |
| `Leader + 1-5` | Jump to tab by number |
| `Leader + ,` | Rename tab |
| `Leader + [` | Enter copy mode (vi keys) |

## Tools

| Tool | Purpose |
|------|---------|
| [WezTerm](https://wezfurlong.org/wezterm/) | Terminal - GPU-accelerated, native tabs/panes |
| [Neovim](https://neovim.io) | Editor |
| [Claude Code](https://claude.ai/code) | Primary AI agent harness |
| [OpenCode](https://opencode.ai) | Alternative terminal AI agent |
| [OpenSpec](https://github.com/Fission-AI/OpenSpec) | Spec-driven development workflow |
| [Agentic Project Tracker](https://github.com/Bimzy27/AgenticProjectTracker) | Mission control desktop app for agent-driven projects |
| [GitHub CLI](https://cli.github.com) | Git forge integration |
| [lazygit](https://github.com/jesseduffield/lazygit) | TUI git client |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Fast grep |
| [zoxide](https://github.com/ajeetdsouza/zoxide) | Smart `cd` |

## Agent instructions

`AGENTS.md` is the single source of truth for all agent instructions.
`CLAUDE.md` is a symlink to `AGENTS.md`, created by `scripts/install-configs.ps1` at install time - it is not tracked in git.

`install-configs.ps1` also symlinks `AGENTS.md` into `~/.claude/` as both `CLAUDE.md` and `AGENTS.md` so the instructions apply globally across every project.

To update agent instructions, edit `AGENTS.md` only.

## Agent skills

`claude/skills/` holds default skills that work in any project, symlinked to `~/.claude/skills` by `install-configs.ps1`:

| Skill | Purpose |
|-------|---------|
| `/typecheck` | Detect and run the project's type checker, fixing failures until it passes |
| `/lint` | Detect and run the project's linter and formatter, fixing findings until clean |
| `/audit` | Scan dependencies for known CVEs and the changeset for leaked secrets |
| `/police` | Enforce the project's `POLICE.md` behaviour rules against the current changeset |
| `/patrol` | The full quality gate: typecheck, lint, audit, police, then tests, fixed until green |
| `/commit` | Quick delivery: sanity-pass the diff, conventional commit, push |
| `/release` | Promote develop into the release branch to trigger a production deploy |
| `/ship` | Standardized PR delivery: run the gate, code-review and security-review the diff, commit, push, open a PR |

Each skill resolves commands from the project itself first (docs, package scripts, task runners) and falls back to ecosystem defaults, so no per-project setup is required.

`POLICE.md` is an optional per-project file of human-written behaviour rules that tools cannot express (testing discipline, architectural boundaries, security posture).
`/police` bootstraps one from a template when missing.

The intended workflow: agents finish a task, run `/patrol`, fix whatever fails, then deliver through `/ship`.
For unattended operation, drive `/patrol` on a loop (for example Claude Code's `/loop /patrol`) so asynchronous agents keep the gate green as they work.

`claude/skills-inactive/` stages skills that are written but not yet loaded.
It currently holds `/next`, the work-intake skill that completes the autonomous loop (`/next` -> work -> `/patrol` -> `/ship`).
Activate it with `git mv claude/skills-inactive/next claude/skills/next` once the pipeline is ready for unattended operation.
