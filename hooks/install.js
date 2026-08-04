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
const MARKER = sbDir; // every hook command we add points inside this dir
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

fs.mkdirSync(sbDir, { recursive: true });
fs.rmSync(path.join(sbDir, "watcher.sh"), { force: true });
// Retire pre-multi-session artifacts (single global state + empty liveness markers).
fs.rmSync(path.join(sbDir, "state.json"), { force: true });
fs.rmSync(path.join(sbDir, "sessions.d"), { recursive: true, force: true });
fs.copyFileSync(path.join(__dirname, "update.js"), updateDest);
fs.copyFileSync(path.join(__dirname, "lifecycle.js"), lifecycleDest);

const shellQuote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;
const quotedMarkerPrefix = shellQuote(MARKER).slice(0, -1);
const isOurs = (command) =>
  command.includes(MARKER) || command.includes(quotedMarkerPrefix);
const cmd = (evt) =>
  `PATH="/opt/homebrew/bin:/usr/local/bin\${PATH:+:$PATH}" node ${shellQuote(updateDest)} ${evt}`;
const life = (evt) =>
  `PATH="/opt/homebrew/bin:/usr/local/bin\${PATH:+:$PATH}" node ${shellQuote(lifecycleDest)} ${evt}`;

let settings = {};
if (fs.existsSync(settingsPath)) {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const bak = settingsPath + ".bak-control-bar";
  if (!fs.existsSync(bak)) fs.copyFileSync(settingsPath, bak);
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
} else {
  fs.writeFileSync(settingsPath, next);
  fs.mkdirSync(sbDir, { recursive: true });
  fs.writeFileSync(ownerPath, JSON.stringify({ channel: "app", pluginRoot: "", ts: Date.now() }));
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
