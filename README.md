# Claude Control Bar

**English** | [Русский](README.ru.md)

https://github.com/user-attachments/assets/39381f85-c8ce-4d32-8baa-dce67d39ee7e

A macOS menu bar app for **Claude Code**: see what Claude is doing right now and manage what it works with — without opening anything.

- **Sessions** — animated icon while Claude thinks, a yellow dot when it needs permission, a live turn timer, and context-window usage per session. Click a session to focus the terminal or editor it lives in.
- **MCP** — every server and every tool with its own on/off switch. A muted tool is dropped from Claude's context entirely, not just blocked.
- **Limits** — 5-hour and 7-day usage as bars right in the menu bar, with reset times in the menu.

## Install

### As a Claude Code plugin (recommended)

```bash
/plugin marketplace add InfinityScripter/claude-control-bar
```

```bash
/plugin install claude-control-bar
```

The app is compiled from source on your Mac at the next session start, so it needs the Xcode Command Line Tools (`xcode-select --install`). Updates arrive with the plugin.

### DMG

1. Download `claude-control-bar.dmg` from [the latest release](../../releases/latest).
2. Drag **Claude Control Bar** into Applications.
3. Launch it once — that installs the hooks.

> [!IMPORTANT]
> The DMG is not notarized, so macOS blocks the first launch. Open **System Settings → Privacy & Security** and press **Open Anyway**, or run
> `xattr -dr com.apple.quarantine "/Applications/Claude Control Bar.app"`.

Pick one channel — installing both means duplicate hooks (the app resolves it in favor of the plugin, but don't).

## Usage

You don't open the app: it launches itself when a Claude Code session starts and quits when none is running. Everything lives in the menu bar icon — sessions, limits, MCP switches, and Options.

Switching a server or tool takes effect in **new** sessions (Claude Code assembles the tool list at session start).

Limits come from Anthropic's usage endpoint (the same one `/usage` asks), polled with the OAuth token Claude Code keeps in your Keychain. The token stays local and is sent to `api.anthropic.com` only; there's an off switch in Options. Every file written and request made is listed in [PRIVACY.md](PRIVACY.md).

## Requirements

- macOS 12+
- [Claude Code](https://claude.com/claude-code) (CLI or Desktop app)
- Node.js and the system `/usr/bin/python3`
- Xcode Command Line Tools — plugin channel only (it compiles the app locally); not needed for the DMG

## Uninstall

Plugin: `/plugin uninstall claude-control-bar`, then drag `~/Applications/Claude Control Bar.app` to the Trash.

DMG:

```bash
node "/Applications/Claude Control Bar.app/Contents/Resources/uninstall.js"
```

Then drag the app to the Trash. State lives in `~/.claude/control-bar/`.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Acknowledgements & License

A fork of [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by Mick Cesanek, merged with [claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar). [Contributors →](ACKNOWLEDGEMENTS.md)

MIT — see [LICENSE](LICENSE). Unofficial project, not affiliated with or endorsed by Anthropic; "Claude" is Anthropic's trademark, used nominatively.
