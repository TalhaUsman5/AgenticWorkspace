# Migrating AgenticWorkspace from OpenCode to OpenClaw

OpenCode used to sit in this workspace as an alternative interactive terminal agent.
Nothing filled the slot of *driving* Claude Code when nobody was watching; that was done by hand with `/loop /patrol`.
OpenClaw replaces the slot rather than the tool: it is an orchestration layer, not another editor agent.

## Role mapping

| Old                                                      | New                                                                    |
| -------------------------------------------------------- | ---------------------------------------------------------------------- |
| `.opencode/`, `.config/opencode/opencode.json`           | Removed - OpenClaw doesn't fill an interactive-terminal-agent slot     |
| Manual `/loop /patrol` for unattended runs               | OpenClaw gateway spawns and supervises the loop from outside           |
| `claude/skills-inactive/next/` (staged, never activated) | Activated at `claude/skills/next/`, triggered by OpenClaw rather than by you typing `/next` |
| Claude Code as primary harness                           | Unchanged - still does the actual coding                               |

## How the loop works now

1. You message the OpenClaw gateway on whichever channel you connect during onboarding.
2. OpenClaw creates an isolated `git worktree`, spawns a detached `tmux` session, and runs Claude Code headless inside it with your task context, invoking the `/next` skill.
3. Claude Code works the backlog: `/next` -> implement -> `/patrol` (typecheck/lint/audit/police/tests) -> `/ship`.
4. `.openclaw/check-agents.sh` - a deterministic script, not an LLM - polls the tmux session and the `gh` CLI on a timer, restarts a stuck agent up to 3 times, and only flags the run ready once every "Definition of Done" check passes.

Keeping step 4 out of the model is the point.
Polling stays cheap and predictable, and retry policy lives in one readable script instead of being re-derived by a model on every tick.

## Who writes which check

The state file at `~/.openclaw/state/<task-id>.json` carries four booleans, split by who can actually observe them:

| Check                    | Written by         | Why                                                             |
| ------------------------ | ------------------ | --------------------------------------------------------------- |
| `prCreated`              | `check-agents.sh`  | Visible from outside via `gh pr list`                            |
| `ciPassed`               | `check-agents.sh`  | Visible from outside via `gh pr checks`                          |
| `claudeReviewPassed`     | `/ship`            | Only the run knows whether code-review and security-review ran   |
| `uiScreenshotsIncluded`  | `/ship`            | Only the run knows whether the change touched UI                 |

A run that dies before reaching `/ship` therefore cannot look finished, which is the property that makes the monitor safe to leave unattended.

## Files

- `bootstrap/openclaw-wsl.ps1` - installs WSL2 + Ubuntu, enables systemd, installs Node 22+, `jq`, `tmux`, `gh`, and OpenClaw inside it, then deploys the two files below.
- `.openclaw/skills/patrol-loop/SKILL.md` - the OpenClaw-side skill describing how to spawn and supervise a Claude Code session. Deployed to `~/.openclaw/workspace/skills/` inside WSL.
- `.openclaw/check-agents.sh` - the deterministic monitor. Deployed to `~/.openclaw/scripts/` inside WSL and run on a systemd timer.
- `.openclaw/tests/run-check-agents-tests.sh` - regression tests for the monitor. `jq`, `gh`, and `tmux` are stubbed, so it runs on a plain Windows checkout with only Node and bash.

## Install

```powershell
.\bootstrap\openclaw-wsl.ps1
# reboot when asked, finish Ubuntu's first-run prompts, then:
.\bootstrap\openclaw-wsl.ps1 -SkipWslInstall
```

If the machine already runs Docker Desktop, note that its `docker-desktop` distro is a utility distro and not usable here.
The script recognises that and installs Ubuntu anyway; pass `-Distro <name>` if you want a different target.

## Manual steps (can't be scripted)

OpenClaw's onboarding wizard needs live input - an API key and a messaging channel choice - so `bootstrap/openclaw-wsl.ps1` stops short of it and hands off to:

```bash
wsl -d Ubuntu
openclaw onboard --install-daemon
```

During the wizard: bind the gateway to loopback only, pick Anthropic as the model provider, and connect whichever channel (Telegram/WhatsApp/Discord/etc.) you want to trigger tasks from.

You also need `gh` authenticated inside WSL, since the monitor reads PR state through it:

```bash
gh auth login
```

## The monitor timer

`bootstrap/openclaw-wsl.ps1` installs and enables this for you, and turns on
lingering so it survives closing your last WSL shell.
Enabling it before onboarding is safe: `check-agents.sh` exits 0 immediately
when no runs exist, so the timer no-ops until the gateway spawns work.

Check on it with `systemctl --user list-timers` and
`journalctl --user -u openclaw-check-agents`.

The units it writes, for reference or manual setup:

`~/.config/systemd/user/openclaw-check-agents.service`

```ini
[Unit]
Description=Poll OpenClaw-spawned Claude Code runs

[Service]
Type=oneshot
ExecStart=%h/.openclaw/scripts/check-agents.sh
```

`~/.config/systemd/user/openclaw-check-agents.timer`

```ini
[Unit]
Description=Run the OpenClaw agent monitor every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=openclaw-check-agents.service

[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now openclaw-check-agents.timer
loginctl enable-linger "$USER"   # keep the timer alive when no shell is open
```

## First-run setup on a fresh distro

`wsl --install` is run with `--no-launch`, so a newly registered distro has no
user account until you create one.
The installer refuses to continue in that state rather than installing into
`/root`, where the config would become unreachable once a real user exists.

Create the account interactively with `wsl -d Ubuntu`, then re-run the
installer with `-SkipWslInstall`.
That prompt needs a TTY, so it cannot be completed from a non-interactive
shell or an agent session.

## Security posture

OpenClaw is experimental software that accepts instructions from a messaging channel and runs Claude Code with `--dangerously-skip-permissions`.
Its maintainers recommend running the gateway on a VM or VPS rather than a main workstation.
Installing inside WSL2 isolates it from the Windows filesystem by default, but that is not equivalent to a dedicated box.
Bind the gateway to loopback only, and treat the whole step 4 install as optional - nothing else in this repo depends on it.
