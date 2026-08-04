---
description: Install, remove or inspect the statusLine limits capture (the optional second source for the 5h/7d bars)
allowed-tools: Bash(/usr/bin/python3:*)
argument-hint: "[install|uninstall|status]"
---

# /limits-capture

The menu bar bars get their figures from Anthropic's usage endpoint on their own. This capture is
the optional second source: it wraps the `statusLine` command so the same figures refresh from
the payload Claude Code hands it — free, and fresher while a terminal CLI is active.

The user asked: `$ARGUMENTS` (empty means `status`).

Run exactly one of these, matching what was asked:

- install — `/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mcpbar.py" statusline --install`
- uninstall — `/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mcpbar.py" statusline --uninstall`
- status — `/usr/bin/python3 "${CLAUDE_PLUGIN_ROOT}/scripts/mcpbar.py" statusline`

Show the command's output as it is. Add only this, once, after an install: the wrapper saved the
previous `statusLine` object whole — including fields like `padding` and `refreshInterval` — and
`/limits-capture uninstall` restores it exactly.
