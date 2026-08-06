#!/usr/bin/env node
// SessionStart/SessionEnd hooks. Usage: node lifecycle.js <start|end>  (hook JSON, incl. session_id, on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "io.github.infinityscripter.claude-control-bar";
const EXEC = "ClaudeControlBar";
const dir = path.join(os.homedir(), ".claude", "control-bar");
const stateDir = path.join(dir, "state.d");
// One file per session, written by hooks/statusline.py: the context percentage Claude Code
// itself reported. It lives and dies with the session file, or context.d grows without bound.
const contextDir = path.join(dir, "context.d");
const event = process.argv[2];

// 0700/0600 everywhere below, not the umask default. A session file carries the working
// directory, the transcript path and the pid, and the home folder is group-readable by staff
// on macOS — which is every local account on the machine.
fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });

const running = () => { try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch { return false; } };
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// kill(pid, 0) probes existence without signalling: it throws ESRCH when the process is gone
// and EPERM when it exists but belongs to someone else (same user here, so it should not
// happen — treated as alive anyway, because deleting a live session's file is the worse error).
const alive = (pid) => {
  if (!(pid > 0)) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
};

const forget = (id) => {
  for (const d of [stateDir, contextDir]) {
    try { fs.rmSync(path.join(d, id + ".json"), { force: true }); } catch {}
  }
};

const reapDeadSessions = () => {
  let files = [];
  try { files = fs.readdirSync(stateDir); } catch { return; }
  for (const f of files.filter((n) => n.endsWith(".json"))) {
    const full = path.join(stateDir, f);
    let pid = 0;
    try { pid = JSON.parse(fs.readFileSync(full, "utf8")).pid || 0; } catch {}
    if (!alive(pid)) forget(f.slice(0, -5));
  }
};

const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  // The mode is set at creation rather than chmod'ed after: the temp file is written in full
  // before the rename, so a later chmod would leave it world-readable for that whole window.
  fs.writeFileSync(tmp, JSON.stringify(obj), { mode: 0o600 });
  fs.renameSync(tmp, file);
};

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

function run() {
  if (done) return; done = true;
  let id = "", cwd = "", transcript = "";
  // The transcript path is carried from the very first event so the next hook can measure the
  // context window without waiting for one that happens to include it.
  try { const j = JSON.parse(input); id = j.session_id; cwd = j.cwd || ""; transcript = j.transcript_path || ""; } catch {}
  id = safeId(id);
  const statePath = path.join(stateDir, id + ".json");

  if (event === "start") {
    // A new session voids a prior explicit Quit (see update.js's self-relaunch suppress).
    try { fs.rmSync(path.join(dir, "quit-intent"), { force: true }); } catch {}
    // Leftovers from a crash would inflate the count, so they go — but only the ones whose
    // process is actually gone. The app not running is no evidence a SESSION is dead: two
    // sessions opening at once both see it down, and the second one's blanket wipe took out
    // the first one's file before the app had ever read it. Liveness is the pid, nothing else.
    if (!running()) reapDeadSessions();
    // Seed an idle file: counts the session immediately, and clears any frozen state from a
    // resume (SessionStart fires on resume with no active turn).
    try {
      // started:false — a merely-opened conversation seeds this for launch + liveness but stays out of
      // the dropdown until it has real activity (update.js flips started:true on a prompt/tool).
      writeAtomic(statePath, { state: "idle", label: "", tool: "", project: cwd ? path.basename(cwd) : "", cwd, sessionId: id, transcript, entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || "", term_program: process.env.TERM_PROGRAM || "", pid: process.ppid, started: false, startedAt: 0, ts: Math.floor(Date.now() / 1000) });
    } catch {}
    cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  } else if (event === "end") {
    // Removing the file drops this session from the aggregate — this is also what recovers a
    // frozen animation on force-quit (SessionEnd fires, but no Stop). No state rewrite needed.
    forget(id);
  }
  process.exit(0);
}
