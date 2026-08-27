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
│   │   └── next/                   # Autonomous-loop work intake (next -> work -> patrol -> ship)
│   └── skills-inactive/            # Staged skills, not loaded until moved into skills/
├── .config/
│   ├── wezterm/wezterm.lua         # Terminal: tabs/panes, Catppuccin Mocha, fullscreen
│   └── nvim/                       # Neovim: lazy.nvim, oil.nvim, neogit, snacks.nvim, LSP
├── .openclaw/
│   ├── skills/patrol-loop.md       # OpenClaw skill: spawn + supervise a Claude Code run
│   ├── check-agents.sh             # Deterministic monitor, run on a systemd timer in WSL
│   └── tests/run-check-agents-tests.sh  # Regression tests for the monitor
├── docs/
│   └── openclaw-migration.md       # How the unattended loop is wired, and its manual steps
├── scripts/
│   └── install-configs.ps1         # Symlink configs into system paths, install fonts
└── bootstrap/
    ├── workspace-windows.ps1       # Install dev tools (winget, npm, gh extensions)
    ├── openclaw-wsl.ps1            # Install WSL2 + Ubuntu + OpenClaw, deploy .openclaw/ config
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

Then, only if you want unattended runs:

4. `bootstrap\openclaw-wsl.ps1` - installs WSL2 + OpenClaw (optional)

> Step 4 is optional and separate from the rest - `setup.ps1` does not run it.
> It installs a second runtime (WSL2) and an experimental, always-on gateway process.
> Skip it if you only want the editor/terminal/Claude Code setup.
> Finish onboarding by hand afterward: `wsl -d Ubuntu` then `openclaw onboard --install-daemon`.
> See [docs/openclaw-migration.md](docs/openclaw-migration.md).

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
| [OpenClaw](https://openclaw.ai) | Orchestration layer - spawns/supervises unattended Claude Code runs |
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
| `/next` | Autonomous work intake: claim the next queue item, work it, deliver it through `/patrol` and `/ship` |

Each skill resolves commands from the project itself first (docs, package scripts, task runners) and falls back to ecosystem defaults, so no per-project setup is required.

`POLICE.md` is an optional per-project file of human-written behaviour rules that tools cannot express (testing discipline, architectural boundaries, security posture).
`/police` bootstraps one from a template when missing.

The intended workflow: agents finish a task, run `/patrol`, fix whatever fails, then deliver through `/ship`.

`claude/skills-inactive/` stages skills that are written but not yet loaded; it is currently empty.

## Unattended operation

Unattended runs are driven from outside Claude Code by OpenClaw, rather than by looping `/patrol` inside one session.

1. You message the OpenClaw gateway on whichever channel you connected during onboarding.
2. OpenClaw creates an isolated `git worktree`, spawns a detached `tmux` session, and runs Claude Code headless inside it against `/next`.
3. Claude Code works the backlog: `/next` -> implement -> `/patrol` -> `/ship`.
4. `.openclaw/check-agents.sh` - a plain shell script on a systemd timer, not a model - polls tmux and `gh`, restarts a stuck run up to 3 times, and only marks the run ready once every check in its state file passes.

The four checks are split by what can observe them: `check-agents.sh` fills in `prCreated` and `ciPassed` from `gh`, while `/ship` writes `claudeReviewPassed` and `uiScreenshotsIncluded` from inside the run.
A run that dies before `/ship` therefore cannot look finished.

Install it with `bootstrap\openclaw-wsl.ps1`, then finish onboarding by hand.
Full detail, including the manual onboarding steps, is in [docs/openclaw-migration.md](docs/openclaw-migration.md).
