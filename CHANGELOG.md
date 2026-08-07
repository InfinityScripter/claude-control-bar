# Changelog

All notable changes to Claude Control Bar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

Entries up to and including 0.4.3 belong to
[claude-status-bar](https://github.com/m1ckc3s/claude-status-bar), the project this was forked
from, and are kept so the history reads continuously.

## [0.7.1] - 2026-08-07

### Added

- **A click on an extension-panel session opens that very conversation.** The Claude Code
  extension registers a URI handler: `<scheme>://anthropic.claude-code/open?session=<id>`
  resumes exactly that session in the editor's Claude panel. The scheme is read from the
  editor's own Info.plist (Cursor says `cursor`, VS Code `vscode`), so every fork works with
  no catalog to maintain, and `open -b` pins the receiving app in case two forks claim one
  scheme. An editor whose extension lacks the handler still comes to the front as before.
  A session running in an integrated *terminal* keeps app-level focus on purpose:
  deep-linking one of those would open a second copy of a conversation that already lives
  in the terminal.

## [0.7.0] - 2026-08-07

### Fixed

- **A session row click focuses the app that actually hosts the session.** The click used to
  resolve the app from `TERM_PROGRAM`, and every VS Code fork inherits `vscode` — so a session
  living in Cursor's terminal opened Visual Studio Code, and a session in the IDE extension
  panel (which sets no `TERM_PROGRAM` at all) opened nothing. The hooks now record
  `__CFBundleIdentifier`, the bundle id LaunchServices stamps on every process launched from an
  app bundle, and the click prefers `open -b <id>` — no name catalog to maintain, and a tmux
  session (`TERM_PROGRAM` says `tmux`, an app `open -a` cannot find) now focuses the terminal
  that launched the tmux server. The `TERM_PROGRAM` map stays as the fallback for ssh and
  pre-upgrade state files.

### Added

- **An IDE badge.** A session living inside an editor — the Claude Code extension panel or a
  VS Code-family integrated terminal (Cursor, Windsurf, VS Code) — now wears **IDE**;
  standalone terminals keep **CLI**, the desktop app keeps **APP**.
- **The README says out loud that sessions are local.** The whole Sessions section is fed by
  hooks firing on this machine; a session running elsewhere (ssh, a cloud worktree, the
  browser) writes no state here, so it is not listed and cannot be focused from here.

## [0.6.0] - 2026-08-07

### Added

- **One-click update that builds from source.** With a Swift toolchain on the machine (Xcode
  command line tools or Xcode), the update row becomes "Update to X": one click downloads the
  release source from GitHub, builds it in place with the same script every channel uses, swaps
  the bundle only after the staging copy verifies, and restarts. No DMG, no Gatekeeper — the
  quarantine that blocks downloaded apps does not apply to a binary compiled on this machine.
  The build is bounded by a watchdog, Quit cancels it cleanly, failures land in
  `~/.claude/control-bar/problems.log`, and the outgoing bundle survives one generation as
  `.previous` beside the app — a compiled-but-broken build must leave something to go back to.
  Without a toolchain the row keeps its old behaviour and opens the release page.
- **A denied network-volume permission now names itself and offers the way back.** macOS counts
  FUSE mounts (arc, sshfs) as network volumes; declining the one-time "access files on a network
  volume" dialog made every MCP check fail with a bare `EPERM`, and the system never asks again.
  The failed check now grows two rows: one opens the right Privacy pane in System Settings, the
  other is a copyable `tccutil reset` command that makes macOS show the original dialog again on
  the next check.

### Fixed

- **The `EPERM` marker survives a crowded error list.** The check error is capped at 200
  characters for the menu; with several projects failing at once the permission error could be
  cut off mid-list, and the new help rows would never appear. Permission errors now sort to the
  front of the line before the cap.

## [0.5.6] - 2026-08-06

### Fixed

- **"Awaiting permission" no longer outlives the prompt it announces.** Denying a permission
  prompt — or dismissing it with Esc — fires no hook at all in Claude Code, so the session's
  state file froze mid-wait and the amber dot sat in the menu bar for up to two hours,
  outranking every live session. The transcript is the one witness that does record the answer:
  while a prompt waits the file is silent, so a user/assistant record younger than the prompt is
  proof it was answered, whatever form the answer took — and the app now reads exactly that.
  Three smaller things kept the old freeze alive and are fixed with it: the tail read stopped at
  8 KB while the bookkeeping Claude Code appends after an interrupt runs to 112 KB in a single
  line (the window now escalates to 1 MB, and only when the cheap read finds nothing, so a
  streaming session pays the old price); a window that happened to cut a multi-byte character —
  an emoji, a dash — made the decoder reject the entire chunk and silently disabled both
  recovery nets for as long as the file sat still; and the last-resort age cap is 30 minutes
  now, not two hours. If Claude Code ever changes the transcript's timestamp format, the app
  logs the drift to Console once per file change instead of degrading in silence.
- **A declined notification permission is now said out loud.** macOS shows the permission dialog
  once per app, ever — no later version, reinstall or second request brings it back, only the
  user in System Settings. The app used to swallow that refusal whole: someone who declined a
  year ago could never learn why "MCP server went down" banners stopped. A menu row now appears
  when notifications are off and opens the app's own pane in System Settings (falling back to
  Settings' root, with a Console trace, on the macOS releases where the undocumented pane link
  stops resolving). The status is re-read at launch, on every menu open and on every delivery
  attempt, so flipping the switch back on clears the row without a restart. The check also no
  longer crashes the bare-binary diagnostic modes (`CONTROL_BAR_DUMP_MENU`,
  `CONTROL_BAR_DIAGNOSE`), where asking the notification center for anything is a trap.

## [0.5.5] - 2026-08-06

### Fixed

- **The app no longer closes itself ten seconds after launch while Claude Code is running.**
  Whether it was still needed was decided by counting the session files the hooks leave in
  `state.d/` — and a session whose hooks never fired writes none (no `node` on the PATH, hooks
  switched off, setting sources that skip the user's file). It never happened next to the
  desktop app, which is a GUI application and is detected a second way, which is exactly why
  this read as "the plugin only works on the desktop". The process table now gets the last
  word: with any `claude` process alive the app stays. Asked through libproc rather than by
  spawning `pgrep`, and only once every cheaper check has already said "not needed".
- **Clicking a session row switches to that session.** For a desktop conversation the click
  merely focused the Claude app — which is normally frontmost already, so every row did nothing
  visible and all of them did the same nothing. The app does file each conversation, at
  `claude-code-sessions/<account>/<workspace>/local_<uuid>.json`, with the CLI session id
  inside — the very id the rows are keyed by. The row resolves it and opens
  `claude://claude.ai/epitaxy/<sessionId>`. Not `claude://code/<id>`: that route wants a bridge
  session id, which a local conversation does not have — 0 of 441 session files on a real
  install carry one. Focusing the app remains the fallback for a conversation with no record on
  disk; a terminal session still brings its terminal to the front.
- **The context percentage in a terminal session is Claude Code's own figure, not a guess.** It
  was recomputed from the transcript against an assumed window size — and the window belongs to
  the session, not to the model: the same `claude-opus-5` answers with 200k in one place and 1M
  in another. Assuming the narrow one turned 30% into 90%. Claude Code states both the size and
  the finished percentage in the statusLine payload, so that is kept per session in
  `context.d/` and preferred to the arithmetic. The recomputation stays for the desktop app and
  the editor extensions, which run no status line at all; a reading older than fifteen minutes
  counts as absent, so a session that moved to the desktop cannot freeze on what the terminal
  last saw. The record is deleted with its session.

### Changed

- **The update row says "Update available".** The version moved into its tooltip, where it is
  not a second number sitting beside the one the line above already gives. "Restart to finish
  updating" lost its version for the same reason.
- **The README no longer claims the plugin channel never meets Gatekeeper.** It says what is
  actually true: the app is compiled from source on your Mac, which needs the Xcode command
  line tools.

## [0.5.4] - 2026-08-06

### Fixed

- **Installing the limits capture no longer silences a foreign `statusline.sh`.** The wrapper's
  recursion guard was a substring check on the saved command's text — and `statusline.sh` is the
  file name from the official Claude Code example, so a user's own status line under that name
  was dropped instead of run: after install their status line simply went blank. The guard is
  now an environment sentinel only this script sets; the saved command's text no longer matters.
- **Uninstalling the capture cannot overwrite a status line the user changed by hand.** "Our
  sidecar files exist" used to pass for "the current command is ours", so after a manual change
  `statusline --uninstall` restored the command saved at install time over the user's newest
  choice. Install now records the exact command it writes, uninstall restores only on an exact
  match (or the wrapper's real path), and otherwise refuses out loud: "changed after install".
  A failed settings write also rolls the sidecar files back instead of leaving a half-install
  that reads as an installed capture.
- **The hook installer and uninstaller no longer delete strangers that resemble them.**
  Ownership was `command.includes("~/.claude/control-bar")` — also a prefix of a user's own
  `control-bar-extra/custom.js`, and a substring of any hook that merely reads a file out of our
  directory. Both kinds of stranger were silently removed on every install and uninstall, and
  the plugin bootstrap used the same check, so one such foreign hook kept the plugin from ever
  claiming the hooks lease. All three now match the exact scripts a hook can point at:
  `update.js` and `lifecycle.js` inside precisely `~/.claude/control-bar/`, with a right-hand
  token boundary on the bare spelling — `update.js` is itself a prefix of a neighbour's
  `update.js.bak`, and "exact" has to mean exact on that side too.
- **Backup rotation touches only its own backups.** The ten-most-recent cleanup globbed
  `settings.json.bak-2*`, which also matches dated backups made by hand or by another tool —
  files whose loss nothing can undo. Backups now live in their own namespace,
  `settings.json.bak-control-bar-<date>-<microseconds>`, rotation is bounded to that exact
  prefix, and pre-existing `.bak-*` files are never deleted. The microseconds also mean two
  switches within one second no longer share a single snapshot — PRIVACY.md promises one per
  switch, and now that is what happens.
- **The MCP check takes a real inter-process lock.** `refresh.lock` was only consulted by the
  statusLine path's spawner; the app's "Check MCP now" and `report --force` ran `refresh()`
  straight past it, so two checks could start every configured server twice and race their
  writes of `mcp.json`, last one winning. `refresh()` itself now takes a non-blocking `flock`
  for the whole check — held to process exit, so a crashed holder releases it — and a
  contending call returns the last picture instead of running a duplicate check — and when
  there is no picture yet (first run), `report` says a check is already running instead of
  presenting a confident "0/0 connected" that was never measured.
- **An ordinary notification cannot park the icon on a two-hour permission alert.** The CLI
  fallback classified notifications by substrings, and `allow` lives inside `shallow`: a
  "Shallow clone finished" notification read as a permission prompt, whose amber state only
  times out after two hours. `notification_type` is now trusted whenever present, and the
  legacy text fallback matches whole words only.
- **"Switch to Homebrew" is offered only once the cask exists.** The row was added for any
  non-brew install as soon as GitHub reported a newer release, while the cask API still returns
  404 — a command guaranteed to fail, handed out by the app's own menu. The row now requires a
  successfully fetched cask version, exactly like the brew-managed upgrade row always did.
- **The hover card shows the tool's real full name.** The identifier line printed
  `mcp__<display name>__<tool>`, but a plugin or claude.ai connector loads its tools under its
  toolPrefix — `plugin:claude-mem:mcp-search` lives in context as
  `plugin_claude-mem_mcp-search`. The switch learned that distinction in 0.5.1; the card now
  uses the same prefix instead of re-deriving a wrong one from the display name.

## [0.5.3] - 2026-08-05

### Security

- **`statusline --install` cannot wipe `settings.json` any more.** The two switches in the menu
  are careful about that file — a lock for the whole read-modify-write, a fingerprint checked
  again just before the rename, and a refusal to treat an unparseable file as an empty one. The
  status line installer, one function away, had none of it: it read through `read_json(...) or {}`
  and wrote with no fingerprint at all. Reproduced against the pre-fix code: with the file
  momentarily invalid — someone editing it by hand — a single `--install` replaced the whole of
  it, `permissions.deny` and the `env` block with its tokens included, with one `statusLine` key.
  No backup was left either, because `backup_settings()` on a file it cannot read quietly returns
  nothing. Both install and uninstall now use the same contract as the switches, and refuse
  rather than guess.

### Fixed

- **Switching a tool off actually switches it off, for plugin servers and claude.ai connectors.**
  The deny rule was assembled from the server's display name, and no real tool name contains a
  space or a colon: `plugin:claude-mem:mcp-search` reaches Claude Code as
  `plugin_claude-mem_mcp-search`, and a connector under its uuid. The rule matched nothing, so
  the tool loaded into every new session while the switch sat off and the "N of M tools on" count
  promised a saving that was not happening — the panel agreeing with itself, since the same wrong
  string was used to read the state back. The spelling Claude Code actually uses is now resolved
  once, in the backend, from the transcripts and the desktop connector cache, and the app is
  handed it rather than rebuilding it. On the development machine that is five servers whose
  switches did nothing. Turning a tool back on also clears the old rule, which would otherwise sit
  in `settings.json` forever, matching nothing.
- **A working session is no longer shown as idle.** The transcript's last line was searched for
  `interrupted by user` anywhere in the raw JSONL, and a tool result is itself a `"type":"user"`
  record — so Claude reading any file that contains the phrase (three of this repository's own
  files do) stopped the animation and the timer mid-turn, and cost a session waiting on permission
  its amber alert. Measured across this machine's transcripts: 27 lines carry the phrase without
  being an interrupt, against 2 that are one. The record is now parsed and the marker matched
  exactly.
- **"A server went down" notifications are delivered.** They were posted for the app's whole life
  without ever asking for permission, and macOS does not prompt on delivery — it declines, with
  nothing but an `NSLog` to say so. Permission is now requested the first time there is something
  to report, so the prompt arrives attached to a real event rather than at first launch.
- **The panel stops starting servers the user switched off.** Collecting tool descriptions runs
  each server's own command, and the list came from `~/.claude.json` with no regard for the
  switches — so a disabled server was launched twice an hour by the very panel that shows it as
  off (reproduced: a disabled server whose command was `touch marker` created the marker). Its
  answer was not even used.
- **`--install` and `--uninstall` recognise their own status line, not any file called
  `statusline.sh`.** That is the name in Claude Code's own documented example, so a user with
  their own status line was told "already installed" and, on uninstall, had their command deleted
  by an operation that promises to undo only its own work.
- **Both channels' hooks can no longer fire at once on a machine using nvm, volta or asdf.** The
  plugin claimed ownership of the hooks before trying to remove the app channel's copies, and it
  looked for node in three fixed paths. Where node lives elsewhere the removal could not run, the
  claim was already written, and `install.js` — which reads that claim and stands down — never
  reclaimed them: two sets of hooks, every event, permanently. The claim is now written only once
  the duplicates are gone, and node is looked for where the app itself looks for it.
- **A saved multi-line status line command is run whole.** The wrapper read one line of it.
- **A pre-release is no longer treated as newer than the release it precedes.** `0.6.0-rc.1`
  compared above `0.6.0`, because an unparsable component became `0` and left the version one
  component longer.
- **A check asked for while another is running is no longer dropped.** A toggle schedules a
  re-check; if a scheduled refresh was already in flight — one that started before the toggle and
  cannot know about it — the new request was discarded and the row stayed stale until the
  ten-minute timer came round.
- **A backend that dies says so.** Its exit code and stderr both went to `/dev/null`, so a script
  failing on a traceback was indistinguishable from one with nothing to report.
- **A dangling `settings.json` symlink stays a symlink.** `realpath` throws on one, and the
  fallback wrote a regular file over the link — the exact dotfiles breakage the resolution exists
  to prevent. A `settings.json` that does not parse now stops the installer with a sentence
  instead of an unhandled stack trace.
- **Assorted:** the saved status line command is written `0600` like everything else in the state
  directory; a log or transcript vanishing mid-sort no longer takes down the whole refresh; the
  refresh lock outlives the refresh it guards; the triage bot points at this repository's issue
  forms rather than the upstream project's; the DMG cleanliness guard inspects the volume
  `hdiutil` actually mounted rather than an assumed path.

### Documentation

- PRIVACY.md now lists everything that is read, including `~/.claude.json` (which holds MCP server
  `env` blocks), Claude Code's MCP logs, the desktop connector cache and the OAuth token behind
  the limits poll — and says that the dated `settings.json` backups live beside the original
  rather than in the state directory.

## [0.5.2] - 2026-08-04

### Security

- **The usage poll no longer follows redirects.** `urllib` copies the `Authorization` header onto
  the redirected request, across origins included — unlike `requests`, which strips it — so a
  single `302` from the endpoint, a proxy or a future move of the API would have delivered the
  account's OAuth token to another host. Reproduced against two local servers on the system
  Python the app actually runs. Redirects are now refused outright and a `30x` is reported as a
  failed poll; checking the final URL afterwards would have been too late, the header having
  already been sent.
- **State files are owner-only.** `~/.claude/control-bar/` and everything under it is created at
  `0700`/`0600`, and existing installs are corrected on every refresh — an upgrade alone does not
  fix permissions. A macOS home folder is readable by the group `staff`, i.e. every local account
  on the machine, and these files hold working directories, transcript paths, account limit
  percentages and, with `CLAUDE_STATUSBAR_DEBUG=1`, fragments of what was typed.

### Fixed

- **The menu says when the app on disk is newer than the app that is running.** Installing over a
  running copy — a DMG, `brew upgrade --cask` — replaces the bundle, but macOS keeps the old
  executable image alive until the app restarts. Measured here: 0.5.1 sat in `/Applications` for
  two hours while a 0.5.0 process drew the menu, and nothing anywhere said so. It is not only
  cosmetic: a process whose bundle was replaced could no longer write its own preferences, so the
  daily update check had nowhere to store the latest tag and the "Update to X" line could never
  appear again either — the app went permanently quiet about updates. There is now a
  **Restart to finish updating to X** row that quits and comes back as the copy on disk; it waits
  for the old process to exit first, because two copies of the same bundle path run side by side
  quite happily.
- **A green server row no longer hides a failed one of the same name.** Two projects with a
  server called `db` collapsed into one row keyed by name, and whichever was seen first won —
  so a working `db` in one project masked a broken `db` in the one being worked in. The row stays
  single (`settings.json` addresses a server by `serverName` alone, so two switches for one name
  would lie in the other direction), but it now takes the worst state of the two and names the
  project it came from.
- **A project whose health check fails is reported instead of vanishing.** The loop reused the
  same `error` variable as the overall check: a project that timed out was skipped by `continue`,
  and the next project that answered reset the variable to nothing. The menu showed neither the
  broken project nor a "check failed" line. Project failures are now collected separately and
  named one by one.
- **A malformed `.mcp.json` no longer removes a project from the map.** The parse that decides
  whether a project is worth checking swallowed its own error and answered "no servers here", so
  a broken config — precisely what a health tool exists to surface — took the whole project's
  servers off the map silently. An unparseable file now sends the project to `claude mcp list`,
  which is where the diagnosis belongs.
- **A development build outside `/Applications` stays a development build.** The installed-copy
  test matched `/Applications/` anywhere in the path, so a build under `/tmp/Applications/…` or
  `~/projects/Applications/…` would have installed hooks into a live `settings.json` and moved
  apps to the Trash. The path is now anchored at `/Applications` or `~/Applications`.

## [0.5.1] - 2026-08-04

### Fixed

- **Servers from a project's `.mcp.json` are back, and the row about them tells the truth.**
  0.5.0 closed a real hole — the app read that file and started its servers itself, so opening a
  cloned repository was enough to run a command from someone else's config — but it closed it by
  refusing to touch project servers at all, and labelled every one of them *approve in Claude
  Code*. For a server the user had already approved that was simply false: nothing was waiting on
  them, and a working server went dark with its tools. The mistake behind it was reading approval
  out of `enabledMcpjsonServers`, which is empty even for approved servers — that list is not
  where the decision lives.
  The app now asks instead of deciding: `claude mcp list` is run in the project's own directory
  and its answer is taken as-is. Claude Code applies its own approval policy, starts what it is
  allowed to start, and reports the rest as `⏸ Pending approval`. No command out of `.mcp.json`
  is ever executed by this app, approved or not — so the hole stays closed while approved servers
  keep working. Costs one extra health check per project that has servers.

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

[0.5.3]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.3
[0.5.2]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.2
[0.5.1]: https://github.com/InfinityScripter/claude-control-bar/releases/tag/v0.5.1
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
