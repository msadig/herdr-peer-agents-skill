# Herdr Peer Agents Skill

[![skills.sh](https://skills.sh/b/msadig/herdr-peer-agents-skill)](https://skills.sh/msadig/herdr-peer-agents-skill)

Agent skill for using [Herdr](https://herdr.dev) as a peer-agent runtime: spawn coding agents in panes, send them prompts, submit them reliably, wait for completion, and read their responses.

Use cases:

- spawn a reviewer agent to inspect your current diff
- spawn an implementer agent for a bounded slice of work
- ask Claude, Codex, or Pi peers for independent verification
- coordinate parallel work inside Herdr without piling everything into one terminal

## What it provides

- `SKILL.md` — skill instructions for Pi/Claude/Codex-style agent skill loaders
- `scripts/herdr-peer.sh` — small wrapper around Herdr CLI

## Requirements

- Herdr installed and running: <https://herdr.dev/docs/>
- At least one coding agent CLI available, e.g. `pi`, `claude`, or `codex`
- Bash + Python 3 for the helper script

## Install with skills.sh

The easiest cross-agent install path is the open agent skills CLI from [skills.sh](https://www.skills.sh/).

Install interactively:

```bash
npx skills add msadig/herdr-peer-agents-skill
```

Install globally for Claude Code and Codex without prompts:

```bash
npx skills add msadig/herdr-peer-agents-skill \
  --global \
  --agent claude-code \
  --agent codex \
  --yes
```

Install for all detected supported agents:

```bash
npx skills add msadig/herdr-peer-agents-skill --all
```

Useful skills.sh commands:

```bash
# Preview skills available in this repo
npx skills add msadig/herdr-peer-agents-skill --list

# List installed skills
npx skills list

# Update installed skills later
npx skills update herdr-peer-agents

# Remove the skill
npx skills remove herdr-peer-agents
```

By default, `skills` can install via symlink so all selected agents share one canonical copy. Use `--copy` only if you specifically need independent copies.

Restart already-running agents so they discover the skill.

## Manual install with symlinks

Clone the repo:

```bash
git clone git@github.com:msadig/herdr-peer-agents-skill.git
cd herdr-peer-agents-skill
```

Symlink into the agent skill directories you use:

```bash
mkdir -p ~/.pi/agent/skills ~/.claude/skills ~/.codex/skills
ln -sfn "$PWD" ~/.pi/agent/skills/herdr-peer-agents
ln -sfn "$PWD" ~/.claude/skills/herdr-peer-agents
ln -sfn "$PWD" ~/.codex/skills/herdr-peer-agents
```

Restart already-running agents so they discover the skill.

## Quick usage

List agents:

```bash
./scripts/herdr-peer.sh list
```

Spawn a Pi reviewer:

```bash
./scripts/herdr-peer.sh start reviewer --cwd "$PWD" --split right -- pi
```

Ask it to review:

```bash
./scripts/herdr-peer.sh ask reviewer \
  "Review the current git diff. Do not edit files. Return findings and final verdict." \
  --timeout 300000 \
  --lines 200
```

Close it:

```bash
./scripts/herdr-peer.sh close reviewer
```

Spawn a Claude peer:

```bash
./scripts/herdr-peer.sh start claude_peer --cwd "$PWD" --split right -- claude
```

Spawn a Codex peer:

```bash
./scripts/herdr-peer.sh start codex_peer --cwd "$PWD" --split right -- codex
```

The helper handles Codex's extra Enter requirement automatically.

## Raw Herdr pattern

```bash
herdr agent start reviewer --cwd "$PWD" --split right --no-focus -- pi
herdr agent get reviewer
herdr agent send reviewer "Review this change. Do not edit files."
herdr pane send-keys <pane_id> Enter
herdr agent wait reviewer --status idle --timeout 300000
herdr agent read reviewer --source recent-unwrapped --lines 200
```

## Notes

- Prefer `--no-focus` to avoid stealing the user's active pane.
- Use `pane run` for ordinary shell commands/tests/servers.
- Use `agent wait` or `wait agent-status` only for recognized coding agents.
- Use clear names: `reviewer`, `implementer`, `verifier`, `tests`, `server`.
- Always read peer output before acting on it.

## License

MIT
