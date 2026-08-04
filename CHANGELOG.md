# Changelog

All notable changes to Claude Control Bar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

Entries up to and including 0.4.3 belong to
[claude-status-bar](https://github.com/m1ckc3s/claude-status-bar), the project this was forked
from, and are kept so the history reads continuously.

## [0.5.0] - 2026-08-04

Renamed to **Claude Control Bar** and merged with
[claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar). The app no longer only
reports on Claude Code — it switches parts of it off.

### Added

- **Context window usage per session**, in the row and in its tooltip. Claude Code gives that
  number to `statusLine` and to nothing else, and the desktop app never runs `statusLine`, so it
  is recomputed from the transcript with the CLI's own formula.
- **MCP section**: servers grouped by where they are configured, one row each with a switch, an
  `enabled/total` tool count and the server's tool list as a submenu off that same row.
- **A spinner on a row being checked**, and `next session` once it has been — a re-enabled server
  is on, but a session assembles its server list at startup, so an open one keeps what it had.
  The check is ordered by the switch itself rather than waiting for the ten-minute timer.
- **Tool cards on hover** — description and parameters, read from the server's own `tools/list`
  response. Parameters are new data; the backend did not collect `inputSchema` before.
- **Usage bars in the menu bar**: the 5h and 7d limits, labelled, with the detail in the menu.
- **A `changed:` line** naming what moved since the last check, plus a notification when a server
  falls over. Tool counts change silently — that is usually you, one click ago.
- `statusline --install`, which wraps an existing `statusLine` command to capture limits without
  altering a byte of its output.
- `CONTROL_BAR_DUMP_MENU=1` prints the menu the app would draw.

### Security

- **A server configured in a project's `.mcp.json` is listed but never started.** The health
  check read that file straight out of the repository and handed its `command` to a subprocess,
  with none of the approval flags Claude Code gates it on — so cloning a repository and opening
  Claude Code in it was enough for a command from someone else's config to run on the next
  check, approved or not, switched off in this app or not. Servers you added yourself are
  unaffected; the row for a project one now says *approve in Claude Code* and stays inert until
  you have.
- **A backup of `settings.json` can no longer be wider than the file it copies.** The backup was
  created fresh, so there was no mode to inherit and the usual `umask 022` made it `0644` while
  the original stood at `0600` — and that file holds the `env` of MCP servers, tokens included.
  Backups now take the source's mode, never wider than the owner.
- **A settings file that will not parse is left alone.** Reading swallowed every error and
  returned "no file", so one click while the user had the file open in an editor mid-edit
  replaced all of their settings with a single deny rule — and the backup step, reading the same
  unparseable file, wrote nothing either. A parse failure now aborts the toggle.
- **A change made by someone else between our read and our write is no longer overwritten.** The
  lock only ever held back this app's own processes; Claude Code and the user's editor do not
  take it. The file's fingerprint is now re-checked immediately before the replace, and a
  mismatch abandons the write.

### Fixed

- **A `settings.json` symlinked into a dotfiles repository stays a symlink.** The atomic replace
  swapped the link itself for a regular file, so the dotfiles original quietly stopped receiving
  changes — no error, just a sync that had died. Both the Python backend and the Node hooks now
  resolve the link and write through to its target.
- **`/mcp-health` no longer dies on a project's HTTP server.** That case produces the state
  `unknown`, which had no entry in the glyph table the report indexes directly, so one correctly
  configured remote server in any open project took the whole command down with a `KeyError`.
- **Turning off "Limits via Anthropic API" now removes the figures.** The switch stopped future
  polls but nothing cleared what had already been fetched, so the bars kept showing old
  percentages with no sign they had stopped moving. Readings that came from the API are dropped
  when the API is off; a statusLine capture is the user's own second source and stays.
- **Two MCP checks can no longer run at once.** The backend ran on a concurrent queue with a
  plain boolean for "busy", so a toggle during a check started a second pass over the same
  servers and the same cache files, and whichever finished first announced that the work was
  done. The queue is serial now, in-flight operations are counted rather than flagged, and a
  refresh asked for while one is already running is dropped instead of queued.
- **A model missing from the local registry no longer inflates the context percentage.** Claude
  Code 2.1.205 knows `claude-opus-4-8` and aliases `opus` to it, while transcripts say
  `claude-opus-5` — a name absent from the binary. Falling through to the 200k default put a
  154k-token session at 77% when the honest figure was 15%. Unknown names now borrow their
  family's widest window and are marked as inferred; a size observed from a real `statusLine`
  payload replaces the guess outright.
- **Switching a server no longer rewrites `~/.claude/settings.json` as a single line.** It is a
  file people edit by hand.
- **A session start no longer clears the whole state directory** when the app is not running.
  Two sessions opening at once both saw it down, and the second wiped the first one's file;
  liveness is the pid now.
- **Reinstalling writes nothing when nothing differs**, instead of rewriting settings.json on
  every launch.
- The routine that cleaned up after an earlier rename deleted bundles **by upstream's id** —
  i.e. this fork would have removed claude-status-bar from the user's disk. It now retires only
  this project's own predecessors, to the Trash rather than by unlink.
- `build.sh` no longer hardcodes a version, nor an Apple Team ID belonging to someone else (the
  grep never matched, so it silently produced an unnotarized DMG while claiming otherwise).
- A development build no longer installs hooks or touches installed apps.
- **"Thinking words" switched off now removes the word.** It used to fall through to the plain
  "Thinking…", which beside an unchecked box is indistinguishable from a broken switch.
- **Roughly half the CPU the app used while Claude works.** Sampling the running process put
  `claudeDesktopRunning()` — which asks LaunchServices about every running application, over IPC,
  on the main thread — at half of everything the 0.4s timer did. It is now reached only when no
  session exists at all, and the quit decision it feeds is sampled every 2s rather than 2.5 times
  a second. The transcript tail is re-read only when the file has actually moved, the animation's
  frames are composed once per look instead of twenty times a second, and the status item title
  is reassigned only when the text it would show has changed. Measured on an M4: 10.2% of a core
  before, 4.7–5.9% after, with the timer's share of a sample falling from 112 to 19.
- **`settings.json` is written through a temp file and renamed**, and left alone entirely if it
  changed between our read and our write. A truncating write that died halfway left an empty
  settings file; a read-modify-write silently dropped whatever Claude Code or the user had
  written in between.
- **The once-a-day update check is once a day even when it fails.** The timestamp was stored only
  on success, so an unreachable GitHub meant both requests fired again on every menu open —
  contradicting PRIVACY.md, and hammering hardest exactly when the network was already unwell.
- **The newest Node is picked numerically.** Version directories were sorted as text, so
  `v9.11.2` outranked `v20.19.0` and the installer could run under a Node too old for the file
  APIs it uses.
- **The debug log is capped at 1 MB and rotated.** It carries an excerpt of each event's message,
  so an uncapped file is a transcript nobody asked for.
- **Two parallel toggles no longer lose one of the changes.** Every click runs as its own
  process; both read the same settings.json and the second write erased the first (measured:
  43 lost of 50 runs of two concurrent toggles). The whole read-modify-write now holds an
  exclusive file lock — 12 concurrent toggles, 12 surviving changes, covered by a test that
  runs real processes.
- **File permissions survive a toggle.** The atomic-write temp file was born with the process
  umask, so a 0600 settings.json became 0644 — and it can carry MCP env values. The original
  mode is copied onto the replacement; tested 0600 → 0600.
- **The MCP map is anchored to projects.** `claude mcp list` answers for the directory it runs
  in, so local- and project-scoped servers were invisible or misclassified. The global check is
  now pinned to a fixed cwd, and servers from live sessions' project configs (`projects[cwd]`
  in ~/.claude.json and the project's .mcp.json) are enumerated and probed from their own
  directory, labelled with their project. A remote project server says "not checked" rather
  than inventing a colour.
- **The statusLine capture keeps the whole object.** Install used to save only `command`, so
  `padding`, `refreshInterval` and `hideVimModeIndicator` vanished on install and did not come
  back on uninstall. The full object is saved, only `command` is swapped, and uninstall
  restores it exactly.
- **A failed build can no longer destroy the installed app.** build.sh removed the app first
  and compiled after; a half-installed CLT or a full disk left nothing but a log. It now
  builds and signs a staging bundle and swaps only after the binary and plist verify —
  and two sessions starting at once can no longer run two builds (a lock file, loser skips).
- **The capture stopped rewriting an unchanged limits.json on every redraw**, and the debug
  log rotation from earlier applies here too.
- **CONTRIBUTING.md describes this project**, not upstream's display-only contract, and
  PRIVACY.md discloses that the health check starts your configured MCP servers on a schedule.
- `/limits-capture` — a slash command that installs, removes or inspects the statusLine
  capture without asking the user to guess the plugin's versioned path.
- **PRIVACY.md now lists what is read locally** — transcripts, the `statusLine` payload,
  `settings.json`, the MCP tool lists — not only what crosses the network.
- **Limits are real now, not whatever a terminal last said.** The 5h/7d figures come from
  Anthropic's usage endpoint — the same one `/usage` asks — polled every five minutes with the
  OAuth token Claude Code already keeps in the Keychain. The `statusLine` capture only fired
  while a terminal CLI was redrawing its TUI, so in the desktop app the bars froze on whatever
  they last showed. The capture stays as a free secondary source; the poll has an off switch in
  Options ("Limits via Anthropic API") because it spends the user's own token, and PRIVACY.md
  names the request.

### Changed

- New identity, frozen in `identity.env`: bundle id
  `io.github.infinityscripter.claude-control-bar`, executable `ClaudeControlBar`, state directory
  `~/.claude/control-bar/`. Menu bar managers key an item's visibility on the bundle id, so this
  re-hides the item once — a one-time cost, paid deliberately rather than by inheriting an id
  that is not ours.
- The DMG is **not notarized**: this fork has no Apple Developer ID. The README says so plainly
  where it previously claimed the opposite.

## [0.4.3] - 2026-07-31

### Added
- **Completion Sound has an "Every turn" option.** The chime can now play the moment any turn finishes, instead of only after turns of a minute or longer. Still off by default.

### Changed
- New app icon.

## [0.4.2] - 2026-07-29

### Fixed
- **Hooks no longer break when Homebrew upgrades Node.** The installer used to write the exact Node binary path into the hook commands, which for Homebrew-installed Node includes the version number, so the next `brew upgrade node` left every hook pointing at a deleted directory: no status, no icon, and no self-heal (that lives in the hooks too). Hook commands now resolve `node` at run time through stable locations instead. If your icon silently died at some point and never came back, this was probably you: install this update and launch the app once. Found, diagnosed, and fixed by [@pedrol2b](https://github.com/pedrol2b) ([#48](https://github.com/m1ckc3s/claude-status-bar/pull/48)), who also contributed the repo's first automated test suite.


## [0.4.1] - 2026-07-22

### Fixed
- **Installing while a Claude Code session is already open no longer looks broken.** The app still quits a few seconds after the first launch (nothing to show yet), but now the hooks relaunch it the moment any session does anything, including sessions that were open before you installed. Previously the icon stayed gone until you started a brand-new session. Thanks to [@Bardin08](https://github.com/Bardin08) for the model bug report and root-cause analysis ([#44](https://github.com/m1ckc3s/claude-status-bar/issues/44)).
- Quit still means quit: quitting from the menu suppresses the relaunch until your next new Claude Code session (or you open the app yourself).

## [0.4.0] - 2026-07-22

### Added
- **Homebrew!** Install (or switch over from an existing DMG install) with `brew install --cask claude-status-bar && open -a "Claude Status Bar"`. The launch at the end is required: it installs the Claude Code hooks, and on a switch-over it also removes your old copy. See [upstream's HOMEBREW.md](https://github.com/m1ckc3s/claude-status-bar/blob/main/HOMEBREW.md) for the full story.
- **The update line in the menu is now brew-aware.** Installed via brew: "Update via brew" appears with a copy button (click, paste in your terminal) and only once Homebrew can actually deliver the new version (the cask lags a release by up to a day). Installed via DMG: "Update available" opens the releases page as before, plus a "Switch to Homebrew" copy button.
- **Completion sound is back**, now as a Completion Sound menu with a length threshold (Off / 1 min+ / 5 min+ / 15 min+) instead of a single on/off toggle. It chimes when a turn that ran at least the chosen length finishes, per session, and is off by default.

### Changed
- **The app bundle is renamed to "Claude Status Bar.app"** (was `ClaudeStatusBar.app`), matching the app's name and its Homebrew cask token. One-time transition: on first launch the app removes the old-named copy from /Applications (after verifying by bundle identifier that it really is this app), so updating over the rename never leaves two copies. Scripts pointing at the old path need the new, quoted path.
- The dropdown timer is now the same size as the session name and sits on its baseline, so it reads as part of the row instead of floating slightly high.
- The working spinner in the dropdown is a touch smaller.

## [0.3.4] - 2026-07-09

### Added
- **Session rows show the git branch** next to the project name ("myrepo · fix-auth"), read straight from `.git/HEAD` (no `git` invocation), works for worktrees, shows a short SHA when detached, shows nothing outside a repo. Updates on session activity and on opening the menu, so a folder that becomes a repo mid-session (git init, first branch) is picked up live. Thanks to [@ethan0905](https://github.com/ethan0905) ([#37](https://github.com/m1ckc3s/claude-status-bar/pull/37)).
- **Same-named projects are told apart.** When two live sessions share a folder name (two clones or worktrees of one repo), rows qualify it with the parent folder: "work/myrepo" vs "tmp/myrepo". Hovering a row shows the full name, branch, and path.

### Fixed
- The dropdown timer now sits on the same text baseline as the session name instead of floating slightly high.
- Long session names keep constant letter spacing on every row; a name that does not fit truncates with an ellipsis instead of being subtly squished next to the timer.

## [0.3.3] - 2026-07-08

### Changed
- The working spinner in the dropdown is now the native macOS spinner. It is smoother and looks cleaner, especially in dark mode.
- Menu cleanup: Animation and Color are their own menu items now, instead of one combined Settings menu. Idle sessions hide after a fixed 15 minutes (the interval picker was removed).

### Removed
- The completion sound, and its toggle.

## [0.3.2] - 2026-07-02

### Added
- Thinking words: the menu bar now rotates through playful verbs while working, more like Claude Code. On by default; toggle it in the menu.

### Changed
- Condensed the settings into a single Settings menu.
- Completion sound now chimes only after turns longer than 5 minutes (was 1 minute).

### Known issues
- Upstream Claude Code bug: pressing Ctrl+C during the reasoning phase in the terminal can leave the icon stuck on a thinking word, since Claude Code emits no hook or transcript signal for that interrupt. Sending your next prompt clears it.

## [0.3.1] - 2026-06-28

### Fixed
- Idle sessions no longer vanish from the menu bar. The icon now follows the live session: it stays while Claude is running and clears when you close it.
- The session list never goes empty: there's always a session to click, or an "Open Claude" shortcut when only the desktop app is open.

### Changed
- Desktop conversations appear only once you work in them, so clicking through conversations no longer clutters the list. Terminal and editor sessions still show the moment they start.
- Menu polish: the session spinner matches the row text, a smaller timer, a tidier Options section, and a light-mode toggle you can actually see.

## [0.3.0] - 2026-06-26

### Added
- **Multi-session support.** The menu bar now tracks every running Claude Code session at once instead of one at a time. When several are active it surfaces the most important one in the bar (a session awaiting your permission outranks one that's working, which outranks idle) and lists them all in the dropdown.
- **Session dropdown.** Each running session gets its own row showing its project, a live status icon (a spinner while working, an amber dot when it needs your approval, a caret when resting), an elapsed timer, and a CLI or APP tag for where it's running.
- **Click a session to jump to it.** Clicking a desktop-app session brings the Claude app forward; clicking a terminal session brings its terminal app forward. Heads up: it raises the terminal app, not a specific window or tab, so if you have several terminal windows open it surfaces your most recent one, not necessarily the exact session you clicked. Precise per-tab focus is in progress: [issue #19](https://github.com/m1ckc3s/claude-status-bar/issues/19).
- **Hide idle sessions** after a delay you choose (5, 15, or 30 minutes, 1 hour, or never), so the list stays focused on what's active.
- **Intel Mac support.** The app now ships as a universal binary and runs natively on both Apple Silicon and Intel Macs.
- **Crab Walking adapts to the color theme.** In System mode the pixel-art crab now renders as a shaded monochrome silhouette that matches the menu bar; Orange mode keeps it full-color. Thanks to @florianheysen for the original implementation.

### Changed
- The menu is now organized around sessions: a Sessions list at the top, with Options, animation, and color settings below.

## [0.2.2] - 2026-06-25

### Fixed
- Fixed install for nvm/fnm users. The hook setup only looked for Node on the login shell's PATH, so the menu bar icon would show but never animate. It now checks the common Node locations and falls back to your interactive shell. Stuck installs heal on the next launch.

## [0.2.1] - 2026-06-25

### Fixed
- Edge case where closing the app (or the Claude desktop app) mid-animation left the menu bar stuck. On reopen it would still show the old "thinking" state with the timer climbing, because a force-quit fires no Stop hook. The status now resets to the idle resting icon when the owning session ends or resumes.
- The menu bar no longer parks on "Waiting for you" after a turn. Claude Code's CLI sends an idle notification ("Claude is waiting for your input") when a session sits idle, and the app was turning that into a persistent label. Now only permission notifications affect the icon, so it simply rests when idle.

## [0.2.0] - 2026-06-25

### Added
- **Awaiting-permission dot now works in the Claude desktop app**, not just the terminal CLI. Previously the yellow "awaiting permission" dot only appeared in the CLI, because the only signal we had (the `Notification` hook) never fires for permission prompts in the desktop app. The app now also listens to Claude Code's `PermissionRequest` hook, which fires the moment an approval dialog is shown in both the CLI and the desktop app, so the dot lights up the instant Claude is waiting on you to approve a tool.

## [0.1.0] - 2026-06-22

### Added
- **Crab Walking** animation style: a pixel-art Clawd crab that scuttles in the menu bar while Claude works. Pick it under Animation. It's always its orange pixel-art self (the Claude and Claude Code styles still follow the Orange/System color setting).
- Optional **completion sound**: a soft chime when a turn longer than a minute finishes. Off by default, toggle it under Options.
- **Version and update check** in the menu: shows your current version, plus a one-click "Update available" that opens the latest release when there's a newer one. The check is a once-a-day read of GitHub's public release tag; no data is collected and nothing is sent to the developer.
- Menu **section headers** (Options / Animation / Color) for easier navigation.

## [0.0.5] - 2026-06-22

### Fixed
- The app no longer quits while a session that was already running before you installed it is actively working. Such a session never fired its one-time `SessionStart` hook, so it wasn't being tracked, even though its other hooks fire normally. The status hooks now register the session on any activity, so any actively-working session keeps the icon alive. (Thanks to the bug report that pinned this down.)

## [0.0.4] - 2026-06-22

### Fixed
- The app now actually runs on macOS 12 (Monterey) and later, as the README states. Earlier builds were compiled without a pinned deployment target, so the binary inherited the build machine's OS (macOS 26) and refused to launch on anything older, despite the stated 12.0 requirement. The build now targets macOS 12.0 explicitly.

## [0.0.3] - 2026-06-22

### Changed
- Reworked how the icon appears on desktop-app launch. The app is now started by the existing session hook (which fires when the Claude desktop app opens, when `claude` runs in a terminal, or when a conversation is opened) and quits itself when Claude is closed and no session is active. This keeps the "icon appears when the desktop app opens" behavior from 0.0.2 with no background helper.

### Removed
- The background watcher (a `launchd` LaunchAgent running a shell script) introduced in 0.0.2. It showed up as a "bash" item under Login Items and Extensions, which was confusing. There is no longer any login item or background item. Upgrading from 0.0.2 removes the old LaunchAgent automatically.

### Fixed
- The menu bar icon now reliably disappears when you quit the Claude desktop app, detected directly rather than relying on the session-end hook (which is unreliable during app shutdown).
- Upgrades now self-heal: the app re-runs its installer when the version changes, so updating from an older version refreshes the hooks and removes the old background watcher without any manual step. Previously the installer only ran on a first-ever install.

## [0.0.2] - 2026-06-21

### Added
- Desktop app watcher: the menu bar icon now appears the moment the Claude desktop app opens, before you start a conversation, and disappears shortly after you quit it. Previously the icon only showed once a session began. Implemented as a lightweight `launchd` LaunchAgent that tracks the Claude desktop process (installed via `install.js`, removed via `uninstall.js`).

### Changed
- Ending a Claude Code session no longer hides the icon while the Claude desktop app is still open.

### Fixed
- Uninstall now removes all of the app's own hooks, including the `SessionStart` / `SessionEnd` lifecycle hooks that a previous version left behind. It only ever touches this app's hooks, never any others.

### Notes
- The desktop watcher is part of the DMG / standalone install path. The Claude Code plugin install path keeps the session-only behavior.

## [0.0.1] - 2026-06-21

### Added
- Initial release: macOS menu bar status indicator for Claude Code, driven entirely by Claude Code hooks.
- Animated Claude spark, elapsed turn timer, and an "awaiting permission" dot.
- Two animation styles (Claude, Claude Code) and two color modes (Orange, System), persisted in preferences.
- Refcounted session lifecycle: launches when Claude Code opens, quits when the last session ends.
- Signed and notarized DMG so it opens without a Gatekeeper warning.
- Claude Code plugin marketplace manifest for the plugin install path.

[0.5.0]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.0
[0.4.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.4.3
[0.4.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.4.2
[0.4.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.4.0
[0.3.4]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.4
[0.3.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.3
[0.3.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.2
[0.3.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.1
[0.3.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.0
[0.2.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.2
[0.2.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.1
[0.2.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.0
[0.1.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.1.0
[0.0.5]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.5
[0.0.4]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.4
[0.0.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.3
[0.0.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.2
[0.0.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.1
