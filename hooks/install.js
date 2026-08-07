#!/usr/bin/env node
// Installs the status-bar hooks into ~/.claude/settings.json (merging, never
// clobbering existing hooks) and copies update.js to ~/.claude/control-bar/.
// Re-runnable: existing status-bar hooks are stripped before re-adding.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const home = os.homedir();
const sbDir = path.join(home, ".claude", "control-bar");
const updateDest = path.join(sbDir, "update.js");
const lifecycleDest = path.join(sbDir, "lifecycle.js");
const settingsPath = path.join(home, ".claude", "settings.json");
const ownerPath = path.join(sbDir, "owner.json");

// Two install channels, one set of hooks. As a Claude Code plugin the hooks are declared in
// hooks/hooks.json; as a brew/DMG app they are written into settings.json from here. Claude
// Code MERGES plugin hooks with settings.json hooks and runs every matching command, with no
// deduplication — so a user who has both gets two node processes per tool call, forever.
//
// The plugin wins, always: Claude Code removes its declared hooks on `plugin uninstall`, while
// hooks written into settings.json outlive any uninstall this app might not get to run. The
// lease is reclaimed the moment the plugin directory is gone from disk — a fact, not a timeout.
const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
const owner = readJSON(ownerPath);
if (owner && owner.channel === "plugin" && owner.pluginRoot && fs.existsSync(owner.pluginRoot)) {
  console.log("Plugin channel owns the hooks (" + owner.pluginRoot + ") — nothing to install.");
  process.exit(0);
}

// Retire the old 0.0.2 background watcher LaunchAgent on upgrade (0.0.3+ self-quits).
const OLD_AGENT_LABEL = "com.local.claudestatusbar.watcher";
const oldAgentPlist = path.join(home, "Library", "LaunchAgents", OLD_AGENT_LABEL + ".plist");
try { cp.execSync(`launchctl bootout gui/${process.getuid()}/${OLD_AGENT_LABEL}`, { stdio: "ignore" }); } catch {}
if (fs.existsSync(oldAgentPlist)) { fs.rmSync(oldAgentPlist); console.log("Removed old desktop watcher LaunchAgent."); }

fs.mkdirSync(sbDir, { recursive: true, mode: 0o700 });
fs.rmSync(path.join(sbDir, "watcher.sh"), { force: true });
// Retire pre-multi-session artifacts (single global state + empty liveness markers).
fs.rmSync(path.join(sbDir, "state.json"), { force: true });
fs.rmSync(path.join(sbDir, "sessions.d"), { recursive: true, force: true });
fs.copyFileSync(path.join(__dirname, "update.js"), updateDest);
fs.copyFileSync(path.join(__dirname, "lifecycle.js"), lifecycleDest);
// copyFileSync carries the repository's 0644 across, and this installer runs on every launch —
// without the chmod the copies would be re-opened to the whole machine twice an hour, undoing
// the backend's own pass. These are hook scripts Claude Code runs as this user: owner-only is
// all they ever need, and PRIVACY.md calls them trusted local code for exactly that reason.
for (const script of [updateDest, lifecycleDest]) { try { fs.chmodSync(script, 0o600); } catch {} }

const shellQuote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;
// Ownership is the exact scripts a hook command points at — the only two this installer has
// ever written — not the directory as a substring. "~/.claude/control-bar" is also a PREFIX of
// a user's own "~/.claude/control-bar-extra/custom.js", and a substring of any command that
// merely reads a file out of our directory; the substring check deleted both kinds of stranger.
// The bare spelling is anchored on the right for the same reason — without the boundary,
// "update.js" is a prefix of a neighbour's "update.js.bak". It cannot be dropped either: 0.0.1
// wrote its commands unquoted, and upgrades still have to recognise them. The shellQuote
// spelling is NOT redundant: with an apostrophe in the home path the escaped form is the only
// one the command contains — drop that branch and such a home never gets its hooks cleaned.
// (uninstall.js and bootstrap.py mirror this predicate; keep the three copies in step.)
const ownScripts = [updateDest, lifecycleDest];
const boundary = (ch) => ch === undefined || ch === " " || ch === "'" || ch === '"';
const pointsAt = (command, script) => {
  for (let at = command.indexOf(script); at !== -1; at = command.indexOf(script, at + 1)) {
    if (boundary(command[at + script.length])) return true;
  }
  return command.includes(shellQuote(script));
};
const isOurs = (command) => ownScripts.some((script) => pointsAt(command, script));
const cmd = (evt) =>
  `PATH="/opt/homebrew/bin:/usr/local/bin\${PATH:+:$PATH}" node ${shellQuote(updateDest)} ${evt}`;
const life = (evt) =>
  `PATH="/opt/homebrew/bin:/usr/local/bin\${PATH:+:$PATH}" node ${shellQuote(lifecycleDest)} ${evt}`;

// A fingerprint of the file as we found it. Compared again just before the rename, because
// settings.json is shared: Claude Code writes it, the user edits it, and a plain read-modify-write
// would silently drop whatever landed in between. The one-off .bak only ever holds the state at
// first install, so it cannot recover a change made months later.
const stamp = () => {
  try { const st = fs.statSync(settingsPath); return `${st.mtimeMs}:${st.size}`; } catch { return ""; }
};

// Where the bytes actually belong. settings.json is commonly a symlink into ~/dotfiles, and
// renaming over the link replaces the link itself with a regular file — the dotfiles original
// then silently stops receiving changes and the user's sync is broken without a single error
// message. realpath answers that for a live link; for a DANGLING one (dotfiles not cloned yet)
// it throws, and the old fallback to the link path performed the exact replacement this resolve
// exists to prevent — so the link is followed by hand instead.
const resolveSettingsPath = () => {
  try { return fs.realpathSync(settingsPath); } catch {}
  try {
    if (fs.lstatSync(settingsPath).isSymbolicLink()) {
      return path.resolve(path.dirname(settingsPath), fs.readlinkSync(settingsPath));
    }
  } catch {}
  return settingsPath;
};

// Temp file in the same directory, then rename. A truncating write that dies halfway — no space
// left, a killed process — leaves the user with an empty settings.json and no working session.
// rename() within one filesystem is atomic: a reader sees either the whole old file or the whole
// new one, never a half of either.
const writeSettingsAtomic = (text, readAt) => {
  if (stamp() !== readAt) {
    console.log("settings.json changed while we were working on it — leaving it alone.");
    console.log("Nothing was written. The next launch will try again against the current file.");
    return false;
  }
  let mode;
  try { mode = fs.statSync(settingsPath).mode; } catch {}
  const target = resolveSettingsPath();
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text, mode === undefined ? undefined : { mode });
  fs.renameSync(tmp, target);
  return true;
};

let settings = {};
const readAt = stamp();
if (fs.existsSync(settingsPath)) {
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch (err) {
    // Said out loud and left alone. An unhandled parse error killed the install with a stack
    // trace nobody sees (the app starts this without a terminal), so the symptom was an app
    // with no sessions in it and no explanation anywhere. Rewriting the file from {} instead
    // would be far worse: it would take the user's own settings with it.
    console.error("settings.json does not parse — hooks not installed:", err.message);
    console.error("Fix " + settingsPath + " and the next launch will install them.");
    process.exit(1);
  }
  const bak = settingsPath + ".bak-control-bar";
  if (!fs.existsSync(bak)) {
    // A backup of a secret is still the secret: owner bits only, and set AT creation —
    // copyFileSync inherits the source's mode, and a chmod after it leaves the file group-
    // readable (staff = every local account) for the window in between. Loud but non-fatal:
    // a machine that rejects the write must still get its hooks installed, and mcpbar.py's
    // per-refresh sweep in secure_root() revisits every .bak-control-bar* file after us.
    try {
      fs.writeFileSync(bak, fs.readFileSync(settingsPath),
        { mode: fs.statSync(settingsPath).mode & 0o700 });
    } catch (err) {
      console.error("could not write settings backup " + bak + ":", err.message);
    }
  }
}
// Compared against the re-serialised parse, not the raw file: the user's own formatting would
// otherwise read as a difference on every single launch.
const before = JSON.stringify(settings, null, 2) + "\n";
settings.hooks = settings.hooks || {};

const stripOurs = (arr) =>
  (arr || [])
    .map((entry) => ({
      ...entry,
      hooks: (entry.hooks || []).filter((h) => !isOurs(h.command || "")),
    }))
    .filter((entry) => (entry.hooks || []).length > 0);

const addUnmatched = (evt, command) => {
  settings.hooks[evt] = stripOurs(settings.hooks[evt]);
  settings.hooks[evt].push({ hooks: [{ type: "command", command }] });
};
const addMatched = (evt, command) => {
  settings.hooks[evt] = stripOurs(settings.hooks[evt]);
  settings.hooks[evt].push({ matcher: "*", hooks: [{ type: "command", command }] });
};

// Status hooks (drive the animation/label)
addUnmatched("UserPromptSubmit", cmd("prompt"));
addMatched("PreToolUse", cmd("pre"));
addMatched("PostToolUse", cmd("post"));
addUnmatched("Notification", cmd("notify"));
addMatched("PermissionRequest", cmd("permreq"));
addUnmatched("Stop", cmd("stop"));
// Lifecycle hooks (launch the app on open; the app quits itself when no longer needed)
addUnmatched("SessionStart", life("start"));
addUnmatched("SessionEnd", life("end"));

// Written only when something actually differs. The app runs this on every launch so it can
// reclaim the hooks the moment the plugin goes away; rewriting an unchanged settings.json each
// time would churn the file the user edits by hand and bump its mtime for every watcher on it.
const next = JSON.stringify(settings, null, 2) + "\n";
if (next === before) {
  console.log("Hooks already current in", settingsPath);
} else if (writeSettingsAtomic(next, readAt)) {
  fs.mkdirSync(sbDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(ownerPath, JSON.stringify({ channel: "app", pluginRoot: "", ts: Date.now() }), { mode: 0o600 });
  console.log("Installed control-bar hooks into", settingsPath);
  console.log("Scripts:", updateDest, "and", lifecycleDest);
  console.log("Backup (first run only):", settingsPath + ".bak-control-bar");
}

// claude-status-bar — the project this was forked from — installs its own hooks under
// ~/.claude/statusbar. They are NOT stripped here on purpose: it is a separate product, and
// silently disabling something the user installed deliberately is worse than the duplication.
// Said out loud instead, because the symptom (two menu bar icons animating in step) is
// otherwise a mystery.
const legacy = path.join(home, ".claude", "statusbar");
const stillThere = Object.values(settings.hooks || {}).some((entries) =>
  (entries || []).some((entry) => (entry.hooks || []).some((h) => (h.command || "").includes(legacy))));
if (stillThere) {
  console.log("\nNote: claude-status-bar hooks are also installed (" + legacy + ").");
  console.log("Both apps will react to the same events. Remove one, or run its uninstaller.");
}
