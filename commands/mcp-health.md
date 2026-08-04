---
description: MCP map — which servers answered, how many tools each brings, what is switched off
allowed-tools: Bash(/usr/bin/python3:*)
---

# /mcp-health

A live check: `claude mcp list` plus tool counts, disabled servers, the context window of every
open session, and usage limits.

!`/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mcpbar.py" report --force`

## What to do with it

Show the map above **as it is** — no summary, no reformatting.

Then, only if something is wrong:

- `✗` — the server did not come up. Reinstalling it through the supported command is usually
  faster than debugging the transport: `claude mcp remove <name> --scope user`, then
  `claude mcp add` again.
- `⏸` — a server from a project `.mcp.json` that has not been approved for this project yet.
- `◌` — needs OAuth. A human does that through `/mcp` in an interactive session. Do not ask for
  or enter tokens.
- `○` — the user switched this server off through `deniedMcpServers`. Not a fault.

All green: one line of confirmation, no analysis.

## Switches

Servers and individual tools can be switched from the menu bar, or here:

```
/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mcpbar.py" toggle-server wiki --off
/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mcpbar.py" toggle-tool mcp__wiki__DeletePage --off
```

Changes apply to **new** sessions: the server and tool lists are assembled when a session
starts. An already-open tab is unaffected — do not promise the user otherwise.
