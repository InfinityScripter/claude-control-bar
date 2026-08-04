# Privacy

Claude Control Bar collects no data and has no servers. Everything it does happens on your Mac.

## Network

One update check a day: a request to GitHub's public releases API for the latest tag, and one to
Homebrew's public formulae API for the current cask version. Both only decide whether the menu
shows an update line. Nothing is sent to the developer — as with any update check, GitHub and
Homebrew see that a request arrived; the developer never does.

That is the whole list. There is no telemetry, no crash reporting and no analytics.

## What it reads on your machine

Showing what Claude is doing means reading a few things that belong to you. None of it leaves the
Mac, and all of it is listed here rather than left to be discovered.

- **Session transcripts** (`~/.claude/projects/**/*.jsonl`). Two reasons. The context percentage
  is computed from the token counts the transcript records, since Claude Code hands that figure
  to a `statusLine` command and to nothing else. And the last few KB are scanned for the
  `interrupted by user` marker, which is how the app notices a turn that ended without an event.
  Both read the file; neither copies it anywhere.
- **The `statusLine` payload**, if you installed the limits capture. The wrapper receives the JSON
  Claude Code hands your status line command — which includes your usage limits and the model
  name — takes the two percentages and the context window size, and passes the bytes on unchanged.
  The rest is not stored. Undo with `mcpbar.py statusline --uninstall`.
- **`~/.claude/settings.json`**, to read and write which MCP servers and tools are switched off.
  A backup is taken the first time, at `settings.json.bak-control-bar`.
- **Your MCP servers**, via `claude mcp list` and a `tools/list` request to each. That returns
  tool names, descriptions and parameters — the same information Claude Code itself receives.
- **The current directory and git branch** of each session, to label its row.

## Where it writes

Everything lives under `~/.claude/control-bar/`: one small JSON file per session in `state.d/`,
the MCP picture in `mcp.json`, the limits in `limits.json`.

With `CLAUDE_STATUSBAR_DEBUG=1` set — off by default — the hook also appends a line per event to
`control-bar/hooks.log`, including the first 160 characters of the event's `message` field. That
can contain fragments of what you typed, so the file is capped and rotated rather than grown
forever, and it is worth deleting when you are done debugging.

## What that means for trust

Once installed, the hook scripts in `~/.claude/control-bar/` run on every Claude Code event. That
is how the app knows anything at all, and it makes those files trusted local code — worth keeping
in a directory only you can write to.

---
Back to the [README](README.md).
