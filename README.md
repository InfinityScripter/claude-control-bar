# Claude Control Bar

A macOS menu bar app for **Claude Code**. It shows what Claude is doing right now — and lets you
change what it has to work with, without opening anything.

- **Sessions** — an animated icon while Claude thinks or runs a tool, a yellow dot when it needs
  your permission, a live turn timer, and **how full each session's context window is**.
- **MCP** — every server, whether it answered, and a switch on each one. Every tool, with its
  description and parameters on hover, and a switch on each of those too. A muted tool is not
  merely blocked at call time: Claude Code drops it from the context entirely.
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

> [!NOTE]
> Not available yet. The cask needs a tap and a published release; `./build.sh --dmg` produces
> the image, and the menu's update check already looks for a `claude-control-bar` cask so it
> works the day one exists. Until then, use the plugin or the DMG.

```bash
brew install --cask claude-control-bar && open -a "Claude Control Bar"
```

That final launch matters: it is what wires up the Claude Code hooks.

### DMG

1. Download the latest `claude-control-bar.dmg` from [Releases](../../releases).
2. Drag **Claude Control Bar** into Applications.
3. Launch it once — that installs the hooks.

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

## Limits, and why they need one extra step

Claude Code never writes your usage limits to disk. They live in the process and leave through
exactly one door: the JSON payload handed to a `statusLine` command. So the app can only show
them if something is standing in that door.

```bash
/usr/bin/python3 ~/.claude/plugins/.../scripts/mcpbar.py statusline --install
```

The wrapper saves whatever `statusLine` command you already had, passes it the exact same bytes,
and prints its output unchanged — your status line does not change by a character. Undo with
`statusline --uninstall`. Limits are per account, not per session, so one terminal session keeps
the figures fresh for every window the app shows. Without this the Limits section says it has no
data rather than inventing a number.

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
  plugins, project `.mcp.json`), each with `enabled/total` tools and a switch. **All tools** is
  the flat inventory of everything currently costing you context.
- **changed:** — what moved since the last check, because a count that is merely different next
  time tells you nothing about whether you moved it or a server did. Servers going down also
  raise a notification; tool counts do not, since that is usually you, one click ago.
- **Options** — timer, thinking words, animation style, icon color, completion sound.

Switching a server or a tool writes to `~/.claude/settings.json` (`deniedMcpServers` and
`permissions.deny`). It takes effect in **new** sessions: the tool list is assembled when a
session starts, so an open tab is unaffected.

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

The app's only network activity is a once-a-day update check against GitHub's and Homebrew's
public APIs ([details](PRIVACY.md)).

There is also a slash command, `/mcp-health`, that prints the same MCP map as text.

## Requirements

- macOS 12+
- [Claude Code](https://claude.com/claude-code) (CLI or the Desktop app)
- Node.js, and the system `/usr/bin/python3` (Command Line Tools)

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
brew uninstall --zap claude-control-bar                                      # app + every file it created
```

Installed as a plugin: `/plugin uninstall claude-control-bar` removes the hooks, then drag
`~/Applications/Claude Control Bar.app` to the Trash. If you installed the `statusLine` capture,
run `mcpbar.py statusline --uninstall` first to get your original command back.

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
