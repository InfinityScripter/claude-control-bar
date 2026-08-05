# Privacy

Claude Control Bar collects no data and has no servers. Everything it does happens on your Mac.

## Network

- **A usage poll to `api.anthropic.com` every five minutes**, authenticated with the OAuth token
  Claude Code keeps in your Keychain. It returns your 5-hour and 7-day limit percentages — the
  same numbers `/usage` shows — and nothing else is asked for or stored. The token is sent to
  Anthropic and to no other host: the request refuses redirects outright, so a `30x` answer from
  the endpoint, a proxy or a future move of the API cannot carry the token to another origin —
  it is reported as a failed poll instead. Switch **Limits via Anthropic API** off in Options and
  this request never happens.
- **One update check a day**: a request to GitHub's public releases API for the latest tag, and
  one to Homebrew's public formulae API for the current cask version. Both only decide whether
  the menu shows an update line.

Nothing is sent to the developer — GitHub, Homebrew and Anthropic see that a request arrived;
the developer never does. Those are the only requests the app makes for itself. There is no
telemetry, no crash reporting and no analytics.

One indirect kind of traffic is worth naming: the MCP health check runs `claude mcp list` and a
`tools/list` round trip, which **starts your configured MCP servers** — every ten minutes, and
after a toggle. A remote (HTTP/SSE) server sees a connection each time; a corporate one may log
it; a stdio server runs briefly as a local process. That is your own configuration doing what it
does when a session starts, but the app is what triggers it on a schedule.

One boundary inside that: this app never runs a command out of a project's own `.mcp.json`. That
file arrives with the repository rather than from you, and Claude Code asks once before trusting
it. Instead of reading the file and starting things itself, the app runs `claude mcp list` in
that project and takes the answer — so whether a server may start is decided where your approval
is recorded, not here. Cloning a repository and opening it cannot make this app execute anything
out of its config.

## What it reads on your machine

Showing what Claude is doing means reading a few things that belong to you. None of it leaves the
Mac, and all of it is listed here rather than left to be discovered.

- **Session transcripts** (`~/.claude/projects/**/*.jsonl`). Two reasons. The context percentage
  is computed from the token counts the transcript records, since Claude Code hands that figure
  to a `statusLine` command and to nothing else. And the last few KB are parsed for the interrupt
  marker Claude Code writes when a turn is cut short, which is how the app notices a turn that
  ended without an event. Both read the file; neither copies it anywhere.
- **The `statusLine` payload**, if you installed the limits capture. The wrapper receives the JSON
  Claude Code hands your status line command — which includes your usage limits and the model
  name — takes the two percentages and the context window size, and passes the bytes on unchanged.
  The rest is not stored. Undo with `mcpbar.py statusline --uninstall`.
- **`~/.claude/settings.json`**, to read and write which MCP servers and tools are switched off.
  A backup is taken the first time, at `settings.json.bak-control-bar`, and a dated one before
  every switch — see "Where it writes".
- **`~/.claude.json`**, for the list of configured MCP servers and how to start each one. That
  file also holds the `env` block of every server, which is where API tokens live if you put them
  there. It is read to launch a server and ask it for its tools, and nothing out of it is copied,
  logged or shown — but it is read, and a file with your tokens in it deserves saying out loud.
- **Your MCP servers**, via `claude mcp list` and a `tools/list` request to each. That returns
  tool names, descriptions and parameters — the same information Claude Code itself receives.
- **Claude Code's own MCP logs** (`~/Library/Caches/claude-cli-nodejs/**/mcp-logs-*`), for the
  tool count each server prints when it starts. Only that number is taken.
- **Claude desktop's session cache** (`~/Library/Application Support/Claude/claude-code-sessions`),
  for the tool list of your claude.ai connectors: they report nothing at startup, so this is the
  only place their schemas exist locally.
- **Your Claude Code OAuth token**, if the Anthropic limits poll is switched on (Options → "Limits
  via Anthropic API"). Read from the login Keychain entry, or from `~/.claude/.credentials.json`
  where there is no Keychain. It is sent to `api.anthropic.com` and nowhere else, is never
  written to disk by this app, and never appears in a log. Switch the option off and it is not
  read at all.
- **The current directory and git branch** of each session, to label its row.

## Where it writes

Everything of its own lives under `~/.claude/control-bar/`: one small JSON file per session in
`state.d/`, the MCP picture in `mcp.json`, the limits in `limits.json`.

The one exception is next door: every switch takes a dated backup of your settings beside the
original, at `~/.claude/settings.json.bak-<date>`. The ten most recent are kept and older ones
are deleted. They carry the same permissions as the file they copy, because a backup of a secret
is still the secret.

That directory is kept readable by you alone — `0700` on the folders, `0600` on the files, checked
and corrected on every refresh rather than only at install. A macOS home folder is readable by the
group `staff`, which is every local account on the machine, so files left at the usual `0644`
would have handed your working directories, transcript paths and account limits to any other user
of the same Mac.

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
