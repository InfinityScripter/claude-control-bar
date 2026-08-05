# Claude Control Bar

https://github.com/user-attachments/assets/39381f85-c8ce-4d32-8baa-dce67d39ee7e

A macOS menu bar app for **Claude Code**. It shows what Claude is doing right now — and lets you
change what it has to work with, without opening anything.

- **Sessions** — an animated icon while Claude thinks or runs a tool, a yellow dot when it needs
  your permission, a live turn timer, and **how full each session's context window is**.
- **MCP** — every server, whether it answered, and a switch on each one. Every tool with a switch
  of its own, and — for servers configured in `~/.claude.json` — its description and parameters on
  hover. A muted tool is not merely blocked at call time: Claude Code drops it from the context
  entirely.
- **Limits** — 5-hour and 7-day usage as bars in the menu bar itself, spelled out with reset
  times in the menu.

This is a fork of **[m1ckc3s/claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)**
merged with **[InfinityScripter/claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar)**.
The sessions half, the animations and the lifecycle come from the first; the MCP half, the
context measurement and the limits come from the second. It is a different product from either,
with its own name and bundle id, and it does not touch an installation of either one.

## Install

### As a Claude Code plugin (recommended)

```bash
/plugin marketplace add InfinityScripter/claude-control-bar
```

Then `/plugin install claude-control-bar`. The app is compiled on your own Mac at the next
session start, which means Gatekeeper is never involved — nothing was downloaded. Updates arrive
with the plugin.

### Homebrew

There is no cask, so there is no `brew install` line here to copy — it would fail. What is
missing is a tap of its own; the menu's update check already looks for a `claude-control-bar`
cask, so the day one exists it starts working without a change here. Until then: the plugin
above, or the DMG below.

### DMG

1. Download `claude-control-bar.dmg` from [the latest release](../../releases/latest).
2. Drag **Claude Control Bar** into Applications.
3. Launch it once — that installs the hooks.

The app checks GitHub once a day and offers the newer version in its own menu when there is one.

> [!IMPORTANT]
> **The DMG is not notarized.** This fork has no Apple Developer ID, so the app is ad-hoc signed
> and macOS will block the first launch. On macOS 15 and later the old Control-click → Open
> trick no longer works: open **System Settings → Privacy & Security** and press **Open Anyway**,
> or run `xattr -dr com.apple.quarantine "/Applications/Claude Control Bar.app"`. If that is not
> acceptable, use the plugin channel — it builds from source on your machine and never meets
> Gatekeeper at all.

### Both channels at once

Don't. Claude Code merges plugin hooks with the ones in `settings.json` and runs every match, so
two installs mean two hook processes per tool call. The app arbitrates this itself through
`~/.claude/control-bar/owner.json`: the plugin always wins, and the app channel reclaims the
hooks automatically the moment the plugin directory is gone.

If you also have **claude-status-bar** installed, both apps will react to the same events. That
is left alone on purpose — it is someone else's product, and disabling it behind your back would
be worse than the duplication. The installer says so out loud instead.

## Limits

The 5-hour and 7-day figures come from Anthropic's own usage endpoint — the same one the
`/usage` command inside Claude Code asks — polled every five minutes with the OAuth token
Claude Code keeps in your Keychain. The token is read locally and sent to `api.anthropic.com`
and nowhere else; nothing about your account is stored beyond the two percentages and their
reset times.

Two things worth saying out loud:

- **This is how every tool in this niche works** (cclimit, Usagebar, Usage4Claude, …), but the
  endpoint is undocumented and Anthropic's consumer terms describe the OAuth token as intended
  for Claude Code and claude.ai. If that gray zone is not for you, switch **Limits via
  Anthropic API** off in Options — the section will honestly say it has no data.
- The token Claude Code stores after `claude setup-token` lacks the profile scope this endpoint
  wants; the normal browser sign-in has it.

There is also a passive second source: a `statusLine` wrapper — `/limits-capture install` as a
slash command (it knows where the plugin lives), or
`/usr/bin/python3 "/Applications/Claude Control Bar.app/Contents/Resources/scripts/mcpbar.py" statusline --install`
for a DMG install. It reads the same figures out of the payload Claude Code hands a status line
command, byte-for-byte transparently to whatever status line you already have — the full
`statusLine` object, `padding` and `refreshInterval` included, is saved and restored whole on
uninstall. It costs nothing but only fires while a terminal CLI is redrawing its TUI — the
desktop app never runs `statusLine` at all, which is exactly why the poll above is the default.
The same payload also states the real context window of the model that answered, which is
remembered — see below.

## Context window

Claude Code hands the used-context percentage to `statusLine` and to nothing else, and the
desktop app never runs `statusLine` (it drives the CLI headless, where there is no TUI to draw a
status line into). So the figure is recomputed from the session transcript with the CLI's own
formula:

```
used% = clamp(round((input + cache_creation + cache_read) / window * 100), 0, 100)
```

Window sizes are scraped out of your installed `claude` binary rather than hardcoded — a
hardcoded table rots with every release, and the list is not ours to publish. That table is not
complete, though: transcripts record the *served* model name, and it may not exist in the local
registry at all. On Claude Code 2.1.205 the registry knows `claude-opus-4-8` and maps the alias
`opus` onto it, while transcripts say `claude-opus-5` — a name absent from the binary. An unknown
name therefore borrows the widest window in its own family and is marked with `~`, and a size
observed from a real `statusLine` payload replaces the guess permanently.

## What the menu shows

- **Sessions** — project · branch, a live timer while working, context %, and a CLI/APP badge.
  Click a row to bring that session's terminal to the front.
- **Limits** — 5h and 7d usage with reset countdowns and the age of the reading.
- **MCP** — servers grouped by where they are configured (local config, claude.ai connectors,
  plugins, project `.mcp.json`), each on one row with `enabled/total` tools, a switch, and its
  tool list as a submenu off the same row.
- **A plugin server usually shows `—` instead of a tool count.** Tools are learned by asking the
  server directly, and the app only does that for servers configured in `~/.claude.json`; for the
  rest it falls back to names seen in past transcripts, so a plugin server you have actually used
  gets its list and the others stay blank until you do.
- **Servers from a project's `.mcp.json` are asked about, not started.** That file ships with the
  repository, and Claude Code asks you once before trusting anything in it. This app never runs a
  command out of it — it runs `claude mcp list` in that project and takes the answer, so the
  decision about what may start stays where your approval lives. A server you have not approved
  comes back as *approve in Claude Code* and is left alone.
- **changed:** — what moved since the last check, because a count that is merely different next
  time tells you nothing about whether you moved it or a server did. Servers going down also
  raise a notification; tool counts do not, since that is usually you, one click ago.
- **Options** — timer, thinking words, the Anthropic limits poll, animation style, icon colour,
  completion sound. Below them: the version, and an update line when a newer one exists.

Switching a server or a tool writes to `~/.claude/settings.json` (`deniedMcpServers` and
`permissions.deny`). It takes effect in **new** sessions: the tool list is assembled when a
session starts, so an open tab is unaffected.

A server switched back on spins while the app goes and looks, and shows `next session` once it
has: on, but not in any window that was already open. The look itself is not cheap — `claude mcp
list` starts every configured server and waits for each to answer, about half a minute here, plus
one more run per open project that has servers of its own — so it runs when you flip a switch,
when you open the menu on a picture older than two minutes, and every ten minutes regardless. Not
on every open: that would start every server you have each time you glanced at the icon. Two
checks never overlap; a refresh asked for while one is running is dropped rather than queued.

### Where it works

| Surface | Tracked? |
|---|---|
| Claude Code CLI (terminal) | ✅ |
| Claude Code Desktop — **Code** tab | ✅ |
| Cursor (Claude Code extension) | ✅ |
| Claude Desktop — **Chat/Cowork** tab | ❌ |

## How it works

> [!NOTE]
> You don't open this app; it opens itself when a Claude Code session starts and quits when none
> is running. Opened by hand with no session active, it quits again after a few seconds.

Three parts, deliberately separated:

| Part | Job |
|---|---|
| `hooks/*.js` | One file per session in `~/.claude/control-bar/state.d/`, plus the context measurement |
| `scripts/mcpbar.py` | `claude mcp list`, a JSON-RPC `tools/list` round trip for names and parameters, the switches |
| `Sources/*.swift` | Draws. Computes nothing. |

It does reach the network, in three places: the limits poll to `api.anthropic.com` every five
minutes (off switch in Options), a once-a-day update check against GitHub's and Homebrew's public
APIs, and the MCP health check — which starts your own servers, and remote ones are your servers
talking to whoever they talk to. Every file it writes and every request it makes is listed in
[PRIVACY.md](PRIVACY.md).

There is also a slash command, `/mcp-health`, that prints the same MCP map as text.

## Requirements

- macOS 12+
- [Claude Code](https://claude.com/claude-code) (CLI or the Desktop app)
- Node.js, and the system `/usr/bin/python3`
- Xcode Command Line Tools (`xcode-select --install`) — the plugin channel compiles the app on
  your own machine with `swiftc`, so without them the first build has nothing to build with. Not
  needed for the DMG.

## Menu bar space

Beside the notch there are roughly 772 points, and an item that does not fit is not clipped — it
slides underneath and disappears. The bars cost about 35pt on top of the plain icon. If the item
does not show up, that is usually the reason, not a bug; a menu bar manager parking it behind a
chevron looks identical.

## Troubleshooting

See [Troubleshooting](TROUBLESHOOTING.md). `CONTROL_BAR_DUMP_MENU=1` run against the app binary
prints the menu it would draw, which beats hunting for an item that may be parked off-screen.

## Uninstall

```bash
node "/Applications/Claude Control Bar.app/Contents/Resources/uninstall.js"   # removes only our hooks
```

Then drag the app to the Trash. State it created lives in `~/.claude/control-bar/`.

Installed as a plugin: `/plugin uninstall claude-control-bar` removes the hooks, then drag
`~/Applications/Claude Control Bar.app` to the Trash. If you installed the `statusLine` capture,
run `/limits-capture uninstall` first to get your original command back — do it before removing
the plugin, since the command lives there.

## Acknowledgements

Built on **[claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)** by Mick Cesanek —
the sessions model, the animations, the self-launching lifecycle and the DMG pipeline are his
work, and this fork would not exist without them. **[Contributors →](ACKNOWLEDGEMENTS.md)**

## Trademark / Not Affiliated

This is an unofficial, open-source side project. **It is not affiliated with, endorsed by, or
sponsored by Anthropic.** "Claude" and the Claude spark logo are trademarks of Anthropic, used
here nominatively. This project is MIT licensed, but that covers the source code only and
conveys no rights to Anthropic's trademarks or brand.

## License

MIT — see [LICENSE](LICENSE). Copyright for the original work remains with Mick Cesanek.
