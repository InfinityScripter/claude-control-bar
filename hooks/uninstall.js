#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const home = os.homedir();
// Match the dir, not "update.js": the narrower marker used to orphan the lifecycle hooks.
const MARKER = path.join(home, ".claude", "control-bar");
const shellQuote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;
const quotedMarkerPrefix = shellQuote(MARKER).slice(0, -1);
const isOurs = (command) =>
  command.includes(MARKER) || command.includes(quotedMarkerPrefix);
const settingsPath = path.join(home, ".claude", "settings.json");

// --hooks-only strips the settings.json hooks and stops there. That is what the plugin channel
// needs when it claims the lease: the app itself must keep running and keep drawing, only its
// duplicate set of hooks has to go.
const hooksOnly = process.argv.includes("--hooks-only");

if (!hooksOnly) {
  // Tear down the desktop watcher LaunchAgent (best-effort; safe if absent).
  const AGENT_LABEL = "com.local.claudestatusbar.watcher";
  const agentPlist = path.join(home, "Library", "LaunchAgents", AGENT_LABEL + ".plist");
  try { cp.execSync(`launchctl bootout gui/${process.getuid()}/${AGENT_LABEL}`, { stdio: "ignore" }); } catch {}
  if (fs.existsSync(agentPlist)) { fs.rmSync(agentPlist); console.log("Removed desktop watcher LaunchAgent."); }
  try { cp.execSync("pkill -x ClaudeControlBar", { stdio: "ignore" }); } catch {}
}

if (!fs.existsSync(settingsPath)) { console.log("No settings.json; nothing to do."); process.exit(0); }

// Same contract as install.js: fingerprint before, verify before the rename, write through a
// temp file. Removing hooks is no less destructive than adding them — this path rewrites the
// whole of a file Claude Code and the user both own.
const stamp = () => {
  try { const st = fs.statSync(settingsPath); return `${st.mtimeMs}:${st.size}`; } catch { return ""; }
};
const writeSettingsAtomic = (text, readAt) => {
  if (stamp() !== readAt) {
    console.log("settings.json changed while we were working on it — nothing removed.");
    return false;
  }
  let mode;
  try { mode = fs.statSync(settingsPath).mode; } catch {}
  const tmp = `${settingsPath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text, mode === undefined ? undefined : { mode });
  fs.renameSync(tmp, settingsPath);
  return true;
};

const readAt = stamp();
const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
// Compared against the re-serialised parse so the user's own formatting is not mistaken for a
// change: the plugin runs this on every session start.
const before = JSON.stringify(settings, null, 2) + "\n";
for (const evt of Object.keys(settings.hooks || {})) {
  settings.hooks[evt] = (settings.hooks[evt] || [])
    .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !isOurs(h.command || "")) }))
    .filter((e) => (e.hooks || []).length > 0);
  if (settings.hooks[evt].length === 0) delete settings.hooks[evt];
}
const next = JSON.stringify(settings, null, 2) + "\n";
if (next === before) {
  if (!hooksOnly) console.log("No control-bar hooks in", settingsPath);
} else if (writeSettingsAtomic(next, readAt)) {
  console.log("Removed control-bar hooks from", settingsPath);
}
