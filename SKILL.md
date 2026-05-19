---
name: herdr-peer-agents
description: Use Herdr to spawn peer coding agents in panes, send them prompts, submit with Enter, wait for completion, and read their responses. Use for code review, implementation help, verifier agents, or agent-to-agent collaboration inside Herdr.
---

# Herdr Peer Agents

Use this skill when you need another coding agent to help with implementation, review changes, verify assumptions, or run in parallel inside Herdr.

Herdr panes are real terminals. Herdr has four levels:

- **Workspace**: project/task context
- **Tab**: a view inside a workspace
- **Pane**: a terminal area inside a tab
- **Agent**: a detected coding agent running in a pane

Agent communication is terminal-based:

1. start or identify a peer agent
2. send text to its terminal
3. submit the prompt with Enter
4. wait for the agent to become `idle`
5. read the peer agent's terminal output

Important: `herdr agent send <target> <text>` writes text into the target terminal. It may not submit the prompt by itself. For reliable submission, follow it with `herdr pane send-keys <pane_id> Enter`. Codex may require pressing Enter twice to submit its composer.

Use Herdr to organize parallel work instead of piling commands into the current pane. Do not steal visible focus unless the user asked for it; prefer `--no-focus`.

## Check Herdr is available

```bash
herdr status
herdr workspace list
herdr tab list
herdr pane list
herdr agent list
```

Use the `pane_id`, `workspace_id`, `tab_id`, and `terminal_id` returned by Herdr for later commands. If Herdr is not running, tell the user to start Herdr first.

## Optional helper script

This skill includes a small wrapper at `scripts/herdr-peer.sh` for common operations. The wrapper tries `herdr agent start` first, caches the returned pane/terminal IDs, waits for Herdr to detect the spawned process as an agent, and then renames it so later calls can use the friendly name reliably. If the `agent start` pane disappears or never detects, it falls back to `herdr pane split` + `herdr pane run <agent-command>`.

```bash
# from the skill directory, or with an absolute path
./scripts/herdr-peer.sh list
./scripts/herdr-peer.sh start reviewer --cwd "$PWD" --split right -- pi
./scripts/herdr-peer.sh ask reviewer "Review the git diff. Do not edit files."
./scripts/herdr-peer.sh close reviewer
```

Use raw Herdr commands below when you need finer control.

## Helper panes for commands, servers, and tests

For ordinary commands, servers, and tests, use pane commands instead of agent commands. Prefer `pane run` over raw key injection when submitting a complete shell command:

```bash
herdr pane split <pane_id> --direction right --cwd "$PWD" --no-focus
herdr pane rename <new_pane_id> tests
herdr pane run <new_pane_id> "just test"
herdr pane read <new_pane_id> --source recent-unwrapped --lines 120
```

Use `herdr wait output` for normal processes and servers:

```bash
herdr wait output <pane_id> --match "ready" --source recent-unwrapped --lines 120 --timeout 120000
```

Use agent waits only for recognized coding agents.

## Spawn a peer agent

Start a named peer agent in the same project:

```bash
herdr agent start reviewer \
  --cwd "$PWD" \
  --split right \
  --no-focus \
  -- pi
```

Start an implementation helper below the current pane:

```bash
herdr agent start implementer \
  --cwd "$PWD" \
  --split down \
  --no-focus \
  -- pi
```

Use `--cwd PATH` to set the peer agent's working directory.

Use `--workspace WORKSPACE_ID` and `--tab TAB_ID` when you need exact placement in an existing Herdr workspace/tab:

```bash
herdr agent start reviewer \
  --cwd "$PWD" \
  --workspace w123 \
  --tab w123:1 \
  --split right \
  --no-focus \
  -- pi
```

Herdr pane placement supports split directions (`right` or `down`) plus workspace/tab selection. It does not require stealing user focus; prefer `--no-focus`.

Use clear names like `reviewer`, `implementer`, `verifier`, `tests`, `server`, or `docs`. Names make later operations auditable:

```bash
herdr agent rename <target> reviewer
herdr pane rename <pane_id> tests
```

## Send a prompt and wait for response

Get the target pane id:

```bash
herdr agent get reviewer
```

Send a prompt:

```bash
herdr agent send reviewer "Review the current git diff for correctness, safety, and missing tests. Reply with concise findings and a final APPROVE or CHANGES_REQUESTED."
```

Submit it with Enter using the peer's `pane_id` from `agent get`:

```bash
herdr pane send-keys <pane_id> Enter
```

For Codex peers, send Enter twice if the prompt appears in the composer but does not run:

```bash
herdr pane send-keys <pane_id> Enter
herdr pane send-keys <pane_id> Enter
```

Wait for completion. Use `idle`, not `done`, for `herdr agent wait` CLI completion waits:

```bash
herdr agent wait reviewer --status idle --timeout 300000
```

For low-level pane waits, Herdr also supports semantic agent status waits:

```bash
herdr wait agent-status <pane_id> --status idle --timeout 300000
herdr wait agent-status <pane_id> --status blocked --timeout 300000
```

Read the response:

```bash
herdr agent read reviewer --source recent-unwrapped --lines 160
```

## One-shot review workflow

```bash
herdr agent start reviewer --cwd "$PWD" --split right --no-focus -- pi
sleep 3
herdr agent get reviewer
herdr agent send reviewer "You are a code reviewer. Inspect the current repository changes. Focus on bugs, regressions, security issues, and missing tests. Do not edit files. Return findings as bullets plus final verdict."
herdr pane send-keys <reviewer_pane_id> Enter
herdr agent wait reviewer --status idle --timeout 300000
herdr agent read reviewer --source recent-unwrapped --lines 200
```

## Implementation helper workflow

Use this when the main agent wants a peer to implement a bounded slice.

```bash
herdr agent start implementer --cwd "$PWD" --split right --no-focus -- pi
sleep 3
herdr agent get implementer
herdr agent send implementer "Help implement the smallest safe change for: <task>. Before editing, summarize your plan. Keep changes minimal. When done, summarize files changed and tests run."
herdr pane send-keys <implementer_pane_id> Enter
herdr agent wait implementer --status idle --timeout 600000
herdr agent read implementer --source recent-unwrapped --lines 240
```

After reading the response, inspect any file changes yourself before reporting success.

## Bidirectional communication pattern

A peer can message back by using the same Herdr commands if it knows the other agent's name or pane id:

```bash
herdr agent list
herdr agent send <main-agent-name-or-terminal-id> "I found an issue: ..."
herdr pane send-keys <main_agent_pane_id> Enter
```

For clean collaboration, tell each spawned agent:

- its role (`reviewer`, `implementer`, `verifier`)
- whether it may edit files
- how to report completion
- whether it should message another Herdr agent
- an explicit end state to avoid loops

## Safety rules

- Prefer `--no-focus` so the user's active pane is not stolen.
- Use short, bounded prompts with an explicit stop condition.
- For review agents, say `Do not edit files`.
- For implementation agents, say exactly what files/scope are allowed when possible.
- Always read the peer output before acting on it.
- Close temporary peer panes when finished:

```bash
herdr pane close <pane_id>
```

## Troubleshooting

If `herdr agent start <name> -- ...` returns `agent_status: unknown` and `herdr agent get <name>` fails immediately, wait for detection and/or use the returned `pane_id`/`terminal_id`. The helper script does this automatically: it caches both IDs, polls `herdr pane get <pane_id>`, and renames the detected terminal back to the requested friendly name. If that pane disappears or never detects, the helper falls back to the manual start pattern: split a pane, run the agent command, then rename after detection.

Manual recovery:

```bash
# If the pane exists and the agent is detected
herdr pane get <pane_id>
herdr agent rename <terminal_id> <friendly-name>
herdr agent get <friendly-name>

# If agent start failed/disappeared
herdr pane split <current_pane_id> --direction right --cwd "$PWD" --no-focus
herdr pane rename <new_pane_id> <friendly-name>
herdr pane run <new_pane_id> "pi"
herdr agent rename <new_terminal_id> <friendly-name>
```

If a prompt is visible in the target composer but does not submit, send Enter again:

```bash
herdr pane send-keys <pane_id> Enter
herdr pane send-keys <pane_id> Enter
```

If `herdr agent wait <name> --status done` fails, use:

```bash
herdr agent wait <name> --status idle
```

If sending text appears in the peer pane but nothing happens, submit Enter explicitly:

```bash
herdr pane send-keys <pane_id> Enter
```

If the agent target name is ambiguous, use its `terminal_id` or `pane_id` from:

```bash
herdr agent list
```
