# Inactive skills

Skills staged here are version-controlled but not loaded, because only `claude/skills/` is symlinked to `~/.claude/skills`.

To activate one:

```powershell
git mv claude/skills-inactive/<name> claude/skills/<name>
```

New Claude Code sessions pick it up automatically.

Currently staged: nothing.

`next/` used to be staged here.
It is active now at `claude/skills/next/`, because OpenClaw invokes it to drive unattended runs.
