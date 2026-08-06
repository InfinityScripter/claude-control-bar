#!/usr/bin/env node
// Maps a Claude Code hook event to this session's file: ~/.claude/control-bar/state.d/<session_id>.json
// Usage: node update.js <prompt|pre|post|notify|permreq|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const dir = path.join(os.homedir(), ".claude", "control-bar");
const stateDir = path.join(dir, "state.d");
// Written by the app's Quit menu item; suppresses the relaunch below so Quit sticks.
// lifecycle.js removes it on the next SessionStart (a new session = fresh consent).
const quitMarker = path.join(dir, "quit-intent");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  TodoWrite: "Planning",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// --- context window ---------------------------------------------------------
// Claude Code hands the used-context percentage to statusLine and to nothing else, and the
// desktop app never runs statusLine (it drives the CLI headless, where there is no TUI to draw
// a status line into). So the number is recomputed here from the session transcript, with the
// same formula the CLI uses, and rides along in the session file the app already reads.

const windowCache = path.join(dir, "model-windows.json");
const contextDir = path.join(dir, "context.d");
const DEFAULT_WINDOW = 200000;
// How long a statusLine reading stays worth trusting. The status line redraws on every
// assistant message, so inside a live terminal session the record is never older than a turn;
// past this the session has almost certainly moved to the desktop app, which runs no status
// line at all — and a frozen figure from an hour ago is worse than a recomputed one.
const STATUSLINE_MAX_AGE = 900;
// Records that must not be measured: interrupted turns and Claude Code's own synthetic replies.
const SKIP_TEXTS = new Set([
  "[Request interrupted by user]",
  "[Request interrupted by user for tool use]",
  "No response requested.",
]);

const readJSON = (file) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };

// The model->window table is scraped out of the Claude Code binary by scripts/mcpbar.py and
// cached; this hook only reads it. Scraping 226 MB on every tool call is not an option.
const FAMILIES = ["opus", "sonnet", "haiku", "fable", "mythos"];
const familyOf = (id) => id.split("-").find((part) => FAMILIES.includes(part)) || "";

// Returns [window, exact]. The table is not a complete list of what a session can report:
// transcripts record the served model name, and that name may not exist in the local registry
// at all. Measured on Claude Code 2.1.205: the registry knows claude-opus-4-8 and maps the
// alias "opus" onto it, while transcripts say claude-opus-5 — a name absent from the binary.
// Falling straight through to the 200k default put a 154k-token session at 77% when the honest
// figure was 15%, so an unknown name borrows the widest window in its own family instead.
// Anthropic has never narrowed a family's window across generations, which is what makes the
// borrow safe; it is still a guess, so the caller marks it assumed.
function windowFor(model, models) {
  const id = String(model || "").toLowerCase();
  if (id.includes("[1m]")) return [1000000, true];
  const base = id.replace(/-\d{8}$/, "");
  if (models[base]) return [models[base], true];
  const family = familyOf(base);
  const kin = Object.keys(models).filter((k) => familyOf(k) === family).map((k) => models[k]);
  return family && kin.length ? [Math.max(...kin), false] : [DEFAULT_WINDOW, false];
}

// What Claude Code itself reported for this session, captured by hooks/statusline.py.
// Preferred over the recomputation below, because the recomputation has to GUESS the window
// size: it belongs to the session, not to the model, and the same claude-opus-5 answers with
// 200k in one place and 1M in another. Guessing wrong moves the percentage by a factor of five.
function contextFromStatusLine(sessionId, now) {
  const record = readJSON(path.join(contextDir, sessionId + ".json"));
  if (!record || typeof record.pct !== "number" || !(record.window > 0)) return null;
  if (!(now - (record.ts || 0) <= STATUSLINE_MAX_AGE)) return null;
  return {
    pct: record.pct, tokens: record.tokens, window: record.window,
    model: record.model || "", assumed: false,
  };
}

// used% = clamp(round((input + cache_creation + cache_read) / window * 100), 0, 100).
// output_tokens is NOT in the numerator — checked against a live statusLine payload.
function contextOf(transcript) {
  let fd;
  try {
    fd = fs.openSync(transcript, "r");
    const size = fs.fstatSync(fd).size;
    if (!size) return null;
    // Tail only: a long session's transcript runs to tens of megabytes, and the newest usage
    // record is always at the end. 2 MB is generous — one turn plus a large tool result.
    const span = Math.min(size, 2_000_000);
    const buf = Buffer.alloc(span);
    fs.readSync(fd, buf, 0, span, size - span);
    let text = buf.toString("utf8");
    // The read starts mid-line, and possibly mid-UTF-8-character; dropping the first partial
    // line discards both problems at once.
    if (size > span) text = text.slice(text.indexOf("\n") + 1);

    const models = (readJSON(windowCache) || {}).models || {};
    const lines = text.split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes('"usage"')) continue;
      let rec;
      try { rec = JSON.parse(lines[i]); } catch { continue; }
      if (!rec || rec.type !== "assistant" || rec.isSidechain) continue;
      const msg = rec.message || {};
      if (msg.model === "<synthetic>") continue;
      const blocks = msg.content;
      if (Array.isArray(blocks) && blocks[0] && SKIP_TEXTS.has(blocks[0].text)) continue;
      const usage = msg.usage || {};
      if (typeof usage.input_tokens !== "number") continue;

      const tokens = usage.input_tokens
        + (usage.cache_creation_input_tokens || 0)
        + (usage.cache_read_input_tokens || 0);
      let [window, exact] = windowFor(msg.model, models);
      let assumed = !exact;
      if (tokens > window) {
        // Observation beats the table: this many tokens could not physically fit a 200k window,
        // so the session runs in the million one and the scraped table is behind. Showing the
        // recomputed figure is more honest than pinning a fake 100%.
        window = 1000000;
        assumed = true;
      }
      return {
        pct: Math.max(0, Math.min(100, Math.round((tokens / window) * 100))),
        tokens, window, model: msg.model || "", assumed,
      };
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
  }
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // Off by default; CLAUDE_STATUSBAR_DEBUG=1 logs every hook invocation to hooks.log.
  if (process.env.CLAUDE_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      // Rotated at 1 MB, keeping one previous file. The line below carries an excerpt of the
      // event's message, so this is a file that can hold fragments of what was typed — letting
      // it grow without limit for the life of the install is not a debugging aid, it is a
      // transcript nobody asked for.
      const logPath = path.join(dir, "hooks.log");
      try {
        if (fs.statSync(logPath).size > 1_000_000) fs.renameSync(logPath, logPath + ".1");
      } catch {}
      // 0600: this file holds fragments of what was typed, and the home folder is readable by
      // group staff on macOS — every local account. The mode applies when the log is created.
      fs.appendFileSync(logPath,
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} msg=${JSON.stringify(p.message || "").slice(0, 160)} keys=${Object.keys(p).join(",")}\n`,
        { mode: 0o600 });
    } catch {}
  }

  // This session's own file is the unit of state AND the liveness marker. Writing it on any
  // event also tracks sessions that predate the hook install (never fired SessionStart).
  const sid = safeId(p.session_id);
  const statePath = path.join(stateDir, sid + ".json");

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  // The app reads <cwd>/.git/HEAD for the branch and disambiguates same-named projects by
  // parent folder; carried over from prev for events whose payload omits cwd.
  const cwd = p.cwd || prev.cwd || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "", startedAt = prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…"; startedAt = ts; break;
    case "pre": {
      const t = p.tool_name || "";
      state = "tool"; label = TOOL_LABELS[t] || "Using tool";
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      break;
    case "notify": {
      // Only a permission prompt drives the icon here (CLI path; desktop uses permreq). Ignore
      // every other Notification (esp. the idle_prompt "Claude is waiting for your input") so the
      // icon rests instead of parking on a confusing "Waiting for you".
      //
      // notification_type is the answer whenever it is present; the message text is a fallback
      // for payloads old enough to lack the field, and it matches whole words only — "allow" as
      // a SUBSTRING also lives inside "shallow", and one such notification parked the icon on
      // "Awaiting permission", a state with a two-hour timeout.
      const isPerm = p.notification_type
        ? p.notification_type === "permission_prompt"
        : /\b(permission|approve|allow)\b/i.test(p.message || "");
      if (!isPerm) return;
      state = "permission"; label = "Awaiting permission"; startedAt = 0;
      break;
    }
    case "permreq":
      // Desktop-app permission signal; not redundant with notify (that's CLI-only).
      state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop":
      state = "done"; label = "Done"; startedAt = 0; break;
    default:
      return;
  }

  // CLAUDE_CODE_ENTRYPOINT tags the surface running this session ("cli", "claude-desktop", …);
  // carried over from prev for the odd event where the env var isn't set.
  const entrypoint = process.env.CLAUDE_CODE_ENTRYPOINT || prev.entrypoint || "";
  // TERM_PROGRAM identifies the terminal app for a CLI session (Apple_Terminal, iTerm.app,
  // vscode, WezTerm, …); the app uses it to bring that terminal to the front on a row click.
  const termProgram = process.env.TERM_PROGRAM || prev.term_program || "";
  // process.ppid IS this session's `claude` process (verified: hooks are spawned directly by it,
  // stable for the session's life, on both CLI and desktop). The app uses kill(pid,0) for liveness.
  // started:true — any update.js event (prompt/tool/permission/stop) is real activity, so the session
  // graduates from "merely opened" to visible in the dropdown. Clicking a conversation never fires here.
  const transcript = p.transcript_path || prev.transcript || "";
  // Carried over from prev when this event's transcript is unreadable (a compaction rewrites the
  // file, and a read landing mid-rewrite finds no usage record) — a momentarily missing number
  // would otherwise blank the context bar and read as "context freed".
  const ctx = contextFromStatusLine(sid, ts)
    || (transcript && contextOf(transcript))
    || {
      pct: prev.pct, tokens: prev.tokens, window: prev.window, model: prev.model, assumed: prev.assumed,
    };
  const out = { state, label, tool: p.tool_name || "", project, cwd, sessionId: p.session_id || "", transcript, entrypoint, term_program: termProgram, pid: process.ppid, started: true, startedAt, ts, ...ctx };
  try {
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    const tmp = statePath + "." + process.pid + ".tmp";
    // Written with the mode set at creation: the file carries the working directory, the
    // transcript path and the pid, and the umask default of 0644 hands all three to any other
    // local account (the home folder is group-readable by staff on macOS).
    fs.writeFileSync(tmp, JSON.stringify(out), { mode: 0o600 });
    fs.renameSync(tmp, statePath);
  } catch {}

  // Self-heal: a session with live state but no app to show it relaunches the app. Covers
  // install-while-a-session-is-already-open (that session never fires SessionStart, the only
  // other opener) and an app killed/crashed mid-session. Skipped after an explicit menu Quit.
  try {
    if (!fs.existsSync(quitMarker)) {
      cp.execSync("pgrep -x ClaudeControlBar", { stdio: "ignore" });
    }
  } catch {
    try { cp.spawn("open", ["-g", "-b", "io.github.infinityscripter.claude-control-bar"], { stdio: "ignore", detached: true }).unref(); } catch {}
  }
});
