# Claude Control Bar

**English** | [Русский](README.ru.md)

https://github.com/user-attachments/assets/39381f85-c8ce-4d32-8baa-dce67d39ee7e

A macOS menu bar app for **Claude Code**. It shows what Claude is doing and lets you manage sessions, MCP servers and usage limits from the menu bar.

- **Sessions.** An animated icon while Claude works, a yellow dot when it waits for your permission, a turn timer and context-window usage for each session. Click a session to focus the terminal or editor it runs in.
- **MCP.** Every server and every tool has its own switch. A muted tool disappears from Claude's context at the next session start.
- **Limits.** 5-hour and 7-day usage as bars in the menu bar, with reset times in the menu.

## Install

### As a Claude Code plugin (recommended)

```bash
/plugin marketplace add InfinityScripter/claude-control-bar
```

```bash
/plugin install claude-control-bar
```

The app compiles from source on your Mac at the next session start, so you need the Xcode Command Line Tools (`xcode-select --install`). Updates arrive with the plugin.

### DMG

1. Download `claude-control-bar.dmg` from [the latest release](../../releases/latest).
2. Drag **Claude Control Bar** into Applications.
3. Launch it once to install the hooks.

> [!IMPORTANT]
> The DMG is not notarized, so macOS blocks the first launch. Open **System Settings → Privacy & Security** and press **Open Anyway**, or run
> `xattr -dr com.apple.quarantine "/Applications/Claude Control Bar.app"`.

Pick one install channel. With both installed every hook runs twice; the app resolves the conflict in favor of the plugin, but there is no reason to keep both.

## Usage

You never open the app yourself. It starts with the first Claude Code session and quits when the last one ends. Sessions, limits, MCP switches and Options all live in the menu bar icon.

### Crab mascot

**Crab Walking** is the default animation on a fresh install. The mascot changes with the number of Claude Code sessions working in parallel. Only sessions that are currently thinking or running a tool count; open but idle sessions do not.

| Working sessions | What the Crab does |
| ---: | --- |
| 0 | Sleeps |
| 1 | Relaxes with a cigar |
| 2–3 | Uses the original walking animation |
| 4–5 | Turns red, sways and sweats |
| 6+ | Its head catches fire |

These previews use the same runtime frames and timing as the menu-bar app:

| 0 · Sleeping | 1 · Cigar | 2–3 · Walking |
| :---: | :---: | :---: |
| ![Crab sleeping animation](assets/crab-moods/sleeping.gif) | ![Crab cigar animation](assets/crab-moods/cigar.gif) | ![Crab walking animation](assets/crab-moods/walking.gif) |
| 4–5 · Overheated | 6+ · On fire | Permission needed |
| ![Overheated Crab animation](assets/crab-moods/overheated.gif) | ![Crab on fire animation](assets/crab-moods/on-fire.gif) | ![Crab waiting for permission animation](assets/crab-moods/permission.gif) |

When a session needs permission, the Crab switches to a separate waiting scene: it checks its watch, then looks at the screen. A yellow warning dot stays beside it, and the status text reads `Needs you`. Once permission is handled, it returns to the state for the current number of working sessions.

Server and tool switches apply to new sessions: Claude Code assembles the tool list at session start, so sessions that are already open keep their old set.

The limit figures come from the same Anthropic usage endpoint that the `/usage` command asks. The app polls it with the OAuth token Claude Code keeps in your Keychain and sends it to `api.anthropic.com` only. The poll has an off switch in Options. [PRIVACY.md](PRIVACY.md) lists every file the app writes and every request it makes.

## Requirements

- macOS 12+
- [Claude Code](https://claude.com/claude-code) (CLI or Desktop app)
- Node.js and the system `/usr/bin/python3`
- Xcode Command Line Tools for the plugin channel (it compiles the app locally); the DMG doesn't need them

## Uninstall

Installed as a plugin: run `/plugin uninstall claude-control-bar`, then drag `~/Applications/Claude Control Bar.app` to the Trash.

Installed from the DMG:

```bash
node "/Applications/Claude Control Bar.app/Contents/Resources/uninstall.js"
```

The script removes the hooks; after that drag the app to the Trash. State lives in `~/.claude/control-bar/`.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Acknowledgements & license

The project grew out of [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by Mick Cesanek, merged with [claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar). Contributors are listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

MIT, see [LICENSE](LICENSE). This is an unofficial project with no affiliation to Anthropic. "Claude" is a trademark of Anthropic, used nominatively.
