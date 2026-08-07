// Behaviour introduced by merging claude-mcp-bar in. Every case here is a defect that was
// either shipped once or caught with a measurement — not a shape check on the code.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

const installerPath = path.resolve(__dirname, "../hooks/install.js");
const lifecyclePath = path.resolve(__dirname, "../hooks/lifecycle.js");
const updatePath = path.resolve(__dirname, "../hooks/update.js");

const sandbox = () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "ccb-"));
  fs.mkdirSync(path.join(home, ".claude", "control-bar", "state.d"), { recursive: true });
  return home;
};

// child_process is stubbed out: the real scripts pgrep and spawn `open`, and a test must not
// launch a menu bar app or kill the one the developer is using. execSync THROWS, because the
// only thing these scripts run through it is `pgrep -x`, and that is how pgrep reports "no such
// process" — the branch under test. spawn records every call into spawnLog(home) instead of
// merely silencing it, so a test can also assert the app was NOT launched.
const run = (scriptPath, home, argv = [], stdin = "{}") =>
  execFileSync(
    process.execPath,
    ["-e", [
      `require("node:child_process").execSync = () => { throw new Error("pgrep: no match"); };`,
      `require("node:child_process").spawn = (cmd, args) => {`,
      `  require("node:fs").appendFileSync(process.env.SPAWN_LOG, cmd + " " + args.join(" ") + "\\n");`,
      `  return { unref() {} };`,
      `};`,
      `require(process.env.SCRIPT_PATH);`,
      // The scripts read their event from process.argv[2]. Under `node -e` the script path is
      // not in argv, so it is put back here — otherwise the event lands in argv[1] and every
      // hook silently takes its "unknown event" branch and writes nothing.
    ].join("\n"), scriptPath, ...argv],
    { env: { ...process.env, HOME: home, SCRIPT_PATH: scriptPath,
             SPAWN_LOG: path.join(home, "spawn-calls.txt") },
      input: stdin, stdio: "pipe" }
  ).toString();

const settingsPath = (home) => path.join(home, ".claude", "settings.json");
const stateDir = (home) => path.join(home, ".claude", "control-bar", "state.d");
const spawnLog = (home) => path.join(home, "spawn-calls.txt");

test("the app channel stands down while the plugin owns the hooks", () => {
  const home = sandbox();
  const pluginRoot = path.join(home, "plugin");
  fs.mkdirSync(pluginRoot);
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "owner.json"),
    JSON.stringify({ channel: "plugin", pluginRoot }));

  const out = run(installerPath, home);
  assert.match(out, /Plugin channel owns the hooks/);
  // Claude Code merges plugin hooks with settings.json hooks and runs every match; installing
  // both sets means two node processes per tool call, forever.
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")).hooks, {});
});

test("the lease is reclaimed once the plugin directory is gone", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "owner.json"),
    JSON.stringify({ channel: "plugin", pluginRoot: path.join(home, "uninstalled-plugin") }));

  run(installerPath, home);
  const commands = Object.values(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")).hooks)
    .flat().flatMap((e) => e.hooks || []).map((h) => h.command);
  assert.equal(commands.length, 8, "all eight hooks reinstated");
});

test("a second install run leaves settings.json byte-identical", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }));
  run(installerPath, home);
  const first = fs.readFileSync(settingsPath(home));
  const out = run(installerPath, home);
  // The app runs the installer on every launch so it can reclaim the hooks when the plugin
  // goes away. Rewriting an unchanged file each time churns something the user edits by hand.
  assert.match(out, /already current/);
  assert.deepEqual(fs.readFileSync(settingsPath(home)), first);
});

test("a session start reaps only sessions whose process is gone", () => {
  const home = sandbox();
  const live = { sessionId: "live", pid: process.pid, ts: 1 };
  const dead = { sessionId: "dead", pid: 999999, ts: 1 };
  fs.writeFileSync(path.join(stateDir(home), "live.json"), JSON.stringify(live));
  fs.writeFileSync(path.join(stateDir(home), "dead.json"), JSON.stringify(dead));

  run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "new", cwd: home }));

  const left = fs.readdirSync(stateDir(home)).sort();
  // This used to clear the whole directory whenever the app was not running. Two sessions
  // opening at once both see it down, and the second wiped the first one's file.
  assert.deepEqual(left, ["live.json", "new.json"]);
});

test("a session file is readable by its owner and nobody else", () => {
  const home = sandbox();
  // The sandbox pre-creates state.d with the umask default; removed so the hook creates it and
  // the mode under test is the one the hook asks for.
  fs.rmSync(stateDir(home), { recursive: true, force: true });

  run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s0", cwd: home }));

  // The file names the working directory, the transcript and the pid, and a macOS home folder is
  // group-readable by staff — which is every local account on the machine.
  assert.equal(fs.statSync(path.join(stateDir(home), "s0.json")).mode & 0o777, 0o600);
  assert.equal(fs.statSync(stateDir(home)).mode & 0o777, 0o700);
});

test("context is measured from the transcript with the CLI's own formula", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, [
    JSON.stringify({ type: "assistant", message: { model: "claude-opus-4-8", content: [{ text: "hi" }],
      usage: { input_tokens: 1000, cache_creation_input_tokens: 4000, cache_read_input_tokens: 95000,
               output_tokens: 50000 } } }),
    // Appended after the real turn and must not be measured — an interrupted turn once showed 0%.
    JSON.stringify({ type: "assistant", message: { model: "claude-opus-4-8",
      content: [{ text: "[Request interrupted by user]" }], usage: { input_tokens: 5 } } }),
  ].join("\n"));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-8": 1000000 } }));

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s1", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s1.json"), "utf8"));
  // 1000 + 4000 + 95000 = 100000 of 1000000. output_tokens is NOT in the numerator.
  assert.equal(state.tokens, 100000);
  assert.equal(state.pct, 10);
  assert.equal(state.assumed, false);
});

test("a model absent from the registry borrows its family's widest window", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-5", content: [{ text: "hi" }],
    usage: { input_tokens: 154452 } } }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-5": 200000, "claude-opus-4-8": 1000000 } }));

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s2", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s2.json"), "utf8"));
  // Measured on Claude Code 2.1.205: transcripts say claude-opus-5, a name the binary's model
  // registry does not contain at all. Falling through to the 200k default put this very session
  // at 77% when the honest figure is 15%.
  assert.equal(state.window, 1000000);
  assert.equal(state.pct, 15);
  assert.equal(state.assumed, true, "an inferred window is marked, not passed off as measured");
});

// The window a session runs in is a property of the SESSION, not of the model: the same
// claude-opus-5 answers with 200k in one place and 1M in another. Recomputing from the
// transcript has to guess which, and a wrong guess moves the percentage by a factor of five.
// Claude Code states both the size and the finished percentage in the statusLine payload.
const writeContextSidecar = (home, sid, record) => {
  const dir = path.join(home, ".claude", "control-bar", "context.d");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify(record));
};

test("Claude Code's own context figure beats the transcript recomputation", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-5", content: [{ text: "hi" }],
    usage: { input_tokens: 192782 } } }));
  // The scraped table is behind and says 200k — recomputing here yields 96%.
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-5": 200000 } }));
  writeContextSidecar(home, "s4", {
    pct: 19, tokens: 192782, window: 1000000, model: "claude-opus-5",
    ts: Math.floor(Date.now() / 1000),
  });

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s4", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s4.json"), "utf8"));
  assert.equal(state.pct, 19);
  assert.equal(state.window, 1000000);
  assert.equal(state.assumed, false, "a figure Claude Code stated is measured, not inferred");
});

test("a statusLine reading old enough to be stale loses to the transcript", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-4-8", content: [{ text: "hi" }],
    usage: { input_tokens: 100000 } } }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-8": 1000000 } }));
  // The desktop app never runs a status line, so a session that moved from the terminal to the
  // app would otherwise keep showing whatever the terminal last saw, forever.
  writeContextSidecar(home, "s5", {
    pct: 3, tokens: 6000, window: 200000, model: "claude-opus-4-8",
    ts: Math.floor(Date.now() / 1000) - 3600,
  });

  run(updatePath, home, ["prompt"],
      JSON.stringify({ session_id: "s5", cwd: home, transcript_path: transcript }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s5.json"), "utf8"));
  assert.equal(state.pct, 10);
  assert.equal(state.tokens, 100000);
});

test("ending a session takes its context record with it", () => {
  const home = sandbox();
  fs.writeFileSync(path.join(stateDir(home), "s6.json"), JSON.stringify({ sessionId: "s6" }));
  writeContextSidecar(home, "s6", { pct: 1, tokens: 1, window: 200000, model: "m", ts: 1 });

  run(lifecyclePath, home, ["end"], JSON.stringify({ session_id: "s6" }));

  const sidecar = path.join(home, ".claude", "control-bar", "context.d", "s6.json");
  assert.equal(fs.existsSync(sidecar), false, "otherwise context.d grows for the life of the install");
});

test("an unreadable transcript keeps the last known context instead of blanking it", () => {
  const home = sandbox();
  fs.writeFileSync(path.join(stateDir(home), "s3.json"), JSON.stringify({
    sessionId: "s3", pid: process.pid, pct: 42, tokens: 84000, window: 200000,
    model: "claude-opus-4-5", transcript: path.join(home, "gone.jsonl"), ts: 1,
  }));

  run(updatePath, home, ["post"], JSON.stringify({ session_id: "s3", cwd: home }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s3.json"), "utf8"));
  // A compaction rewrites the transcript; a read landing mid-rewrite finds no usage record.
  // Blanking the number there reads as "context freed", which is the opposite of the truth.
  assert.equal(state.pct, 42);
  assert.equal(state.tokens, 84000);
});

test("a notification is a permission prompt by its type, not by substrings of its text", () => {
  const home = sandbox();
  // "Shallow" contains "allow"; with the substring check this ordinary notification parked
  // the icon on "Awaiting permission" — a state with a two-hour timeout.
  run(updatePath, home, ["notify"], JSON.stringify({
    session_id: "typed-shallow", notification_type: "idle_prompt", message: "Shallow clone finished",
  }));
  assert.equal(fs.existsSync(path.join(stateDir(home), "typed-shallow.json")), false);

  run(updatePath, home, ["notify"], JSON.stringify({
    session_id: "typed-perm", notification_type: "permission_prompt", message: "whatever the text says",
  }));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "typed-perm.json"), "utf8"));
  assert.equal(state.state, "permission");
});

test("the legacy notification-text fallback matches whole words only", () => {
  const home = sandbox();
  // Payloads old enough to lack notification_type still classify by text — on word
  // boundaries: shallow/fallow/permissionless must not read as permission prompts.
  for (const [sid, message] of [
    ["legacy-shallow", "Shallow clone finished"],
    ["legacy-fallow", "Field left fallow"],
    ["legacy-permless", "Running in permissionless mode"],
  ]) {
    run(updatePath, home, ["notify"], JSON.stringify({ session_id: sid, message }));
    assert.equal(fs.existsSync(path.join(stateDir(home), `${sid}.json`)), false,
      `${sid} misread as a permission prompt`);
  }

  run(updatePath, home, ["notify"], JSON.stringify({
    session_id: "legacy-perm", message: "Claude needs your permission to use Bash",
  }));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "legacy-perm.json"), "utf8"));
  assert.equal(state.state, "permission");
});

// settings.json is shared with Claude Code and edited by hand. Both cases below are about not
// destroying someone else's work in it.

test("the first-run backup carries owner-only bits, whatever the original had", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }, null, 2) + "\n");
  // The umask default. A backup born with it held the full settings.json snapshot readable
  // by group staff — every local account — and nothing ever revisited it.
  fs.chmodSync(settingsPath(home), 0o644);
  run(installerPath, home);
  assert.equal(fs.statSync(settingsPath(home) + ".bak-control-bar").mode & 0o777, 0o600);
});

test("a settings write leaves no temp file and keeps the file's mode", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }, null, 2) + "\n");
  fs.chmodSync(settingsPath(home), 0o600);
  run(installerPath, home);
  const dir = path.join(home, ".claude");
  assert.equal(fs.readdirSync(dir).filter((f) => f.endsWith(".tmp")).length, 0);
  assert.equal(fs.statSync(settingsPath(home)).mode & 0o777, 0o600);
  assert.ok(fs.readFileSync(settingsPath(home), "utf8").includes("control-bar"));
});

test("a settings file changed underneath us is left alone rather than clobbered", () => {
  const home = sandbox();
  fs.writeFileSync(settingsPath(home), JSON.stringify({ hooks: {} }, null, 2) + "\n");
  // The installer reads settings.json, then checks the fingerprint again before renaming. A
  // writer that lands in between must not be overwritten — its change would vanish silently and
  // the .bak, taken once at first install, could not bring it back.
  const out = execFileSync(
    process.execPath,
    ["-e", [
      `require("node:child_process").execSync = () => { throw new Error("pgrep: no match"); };`,
      `require("node:child_process").spawn = () => ({ unref() {} });`,
      // Sneak a write in between the installer's read and its rename. The first-run backup
      // write is the hook: it happens after the parse and before the fingerprint re-check.
      `const fs = require("node:fs");`,
      `const real = fs.writeFileSync;`,
      `fs.writeFileSync = (p, ...rest) => {`,
      `  real(p, ...rest);`,
      `  if (String(p).endsWith(".bak-control-bar")) {`,
      `    real(process.env.SETTINGS, JSON.stringify({ theirs: true }, null, 2) + "\\n");`,
      `  }`,
      `};`,
      `require(process.env.SCRIPT_PATH);`,
    ].join("\n"), installerPath],
    { env: { ...process.env, HOME: home, SCRIPT_PATH: installerPath, SETTINGS: settingsPath(home) },
      input: "{}", stdio: "pipe" }
  ).toString();
  assert.match(out, /changed while we were working on it/);
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")), { theirs: true });
  assert.equal(fs.readdirSync(path.join(home, ".claude")).filter((f) => f.endsWith(".tmp")).length, 0);
});

// A row click resolves the app to focus from TERM_PROGRAM — but Cursor, Windsurf and VS Code
// all report TERM_PROGRAM="vscode" (forks inherit it), so a session living in Cursor's terminal
// opened Visual Studio Code, and the extension panel (no TERM_PROGRAM at all) opened nothing.
// LaunchServices stamps every process launched from an app bundle with __CFBundleIdentifier;
// that names the host exactly, and `open -b` takes it verbatim — no name mapping to maintain.
//
// process.env is spread into the child at call time, so tests flip the variable in OUR env and
// restore it — the runner itself may legitimately carry one (tests launched from an IDE do).
const withBundleEnv = (value, fn) => {
  const saved = process.env.__CFBundleIdentifier;
  if (value === undefined) delete process.env.__CFBundleIdentifier;
  else process.env.__CFBundleIdentifier = value;
  try { return fn(); } finally {
    if (saved === undefined) delete process.env.__CFBundleIdentifier;
    else process.env.__CFBundleIdentifier = saved;
  }
};

test("the session file records the bundle id of the app hosting the session", () => {
  const home = sandbox();
  withBundleEnv("com.todesktop.230313mzl4w4u92", () =>
    run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s8", cwd: home })));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s8.json"), "utf8"));
  assert.equal(state.term_bundle, "com.todesktop.230313mzl4w4u92");
});

test("the seeded session carries the host bundle id from the first moment", () => {
  const home = sandbox();
  withBundleEnv("com.googlecode.iterm2", () =>
    run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "n1", cwd: home })));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "n1.json"), "utf8"));
  assert.equal(state.term_bundle, "com.googlecode.iterm2");
});

test("an event arriving without the env var keeps the bundle id already on file", () => {
  const home = sandbox();
  fs.writeFileSync(path.join(stateDir(home), "s7.json"), JSON.stringify(
    { sessionId: "s7", pid: process.pid, term_bundle: "com.todesktop.230313mzl4w4u92", ts: 1 }));
  withBundleEnv(undefined, () =>
    run(updatePath, home, ["prompt"], JSON.stringify({ session_id: "s7", cwd: home })));
  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "s7.json"), "utf8"));
  assert.equal(state.term_bundle, "com.todesktop.230313mzl4w4u92");
});

// An explicit menu Quit writes ~/.claude/control-bar/quit-intent. SessionStart fires for
// brand-new sessions AND for resumes (--resume/--continue, wake after sleep, compaction) —
// and both lifecycle.js and bootstrap.py launch the app from it. Only a genuinely new session
// is fresh consent: voiding the Quit because a laptop lid opened is exactly the reported
// "I quit it and it came back on its own".

const quitMarker = (home) => path.join(home, ".claude", "control-bar", "quit-intent");

test("an explicit Quit survives a session resume", () => {
  // All three resume-shaped sources: the list must stay in step with bootstrap.py's, and a
  // value dropped from lifecycle.js alone would otherwise stay green here.
  for (const source of ["resume", "compact", "fork"]) {
    const home = sandbox();
    fs.writeFileSync(quitMarker(home), "");
    run(lifecyclePath, home, ["start"],
      JSON.stringify({ session_id: "r1", cwd: home, source }));
    assert.ok(fs.existsSync(quitMarker(home)), `the marker must outlive a ${source}`);
    assert.ok(!fs.existsSync(spawnLog(home)), `a ${source} must not bring a quit app back`);
    // The seed still lands: it is what clears a state frozen mid-turn, resume included.
    const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "r1.json"), "utf8"));
    assert.equal(state.state, "idle");
  }
});

test("a genuinely new session voids the Quit and brings the app back", () => {
  const home = sandbox();
  fs.writeFileSync(quitMarker(home), "");
  run(lifecyclePath, home, ["start"],
    JSON.stringify({ session_id: "n2", cwd: home, source: "startup" }));
  assert.ok(!fs.existsSync(quitMarker(home)), "a new session is fresh consent");
  assert.ok(fs.existsSync(spawnLog(home)), "and the app comes up for it");
});

test("a resume with no Quit on file still self-heals the app", () => {
  const home = sandbox();
  run(lifecyclePath, home, ["start"],
    JSON.stringify({ session_id: "r3", cwd: home, source: "resume" }));
  assert.ok(fs.existsSync(spawnLog(home)),
    "no marker means nothing to honor — a crashed app relaunches");
});

test("a payload without source keeps the pre-source behavior", () => {
  const home = sandbox();
  fs.writeFileSync(quitMarker(home), "");
  run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "n4", cwd: home }));
  // An old Claude Code sends no source; treating that as a resume would leave the app
  // permanently down after one Quit.
  assert.ok(!fs.existsSync(quitMarker(home)));
  assert.ok(fs.existsSync(spawnLog(home)));
});

// The js→swift seam. These files are parsed by Session.init in Sources/Sessions.swift — a
// second, independent implementation of the same schema. This pin holds the writer's half of
// the contract; the reader's half is the seam fixture below, which the swift model checks
// parse with the real Session initializer.

test("the state file a hook event writes carries exactly the keys the swift reader parses", () => {
  const home = sandbox();
  const transcript = path.join(home, "t.jsonl");
  // With a measurable transcript the context block is present too — the fullest shape.
  fs.writeFileSync(transcript, JSON.stringify({ type: "assistant", message: {
    model: "claude-opus-4-8", content: [{ text: "hi" }], usage: { input_tokens: 1000 } } }));
  fs.writeFileSync(path.join(home, ".claude", "control-bar", "model-windows.json"),
    JSON.stringify({ models: { "claude-opus-4-8": 200000 } }));

  run(updatePath, home, ["pre"], JSON.stringify({
    session_id: "pin1", cwd: home, transcript_path: transcript, tool_name: "Bash",
  }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "pin1.json"), "utf8"));
  assert.deepEqual(Object.keys(state).sort(), [
    "assumed", "cwd", "entrypoint", "label", "model", "pct", "pid", "project", "sessionId",
    "started", "startedAt", "state", "term_bundle", "term_program", "tokens", "tool",
    "transcript", "ts", "window",
  ]);
  assert.equal(typeof state.state, "string");
  assert.equal(typeof state.pid, "number");
  assert.equal(typeof state.ts, "number");
  assert.equal(typeof state.started, "boolean");
  assert.equal(typeof state.pct, "number");

  // The reader's half of this seam: the swift model checks parse THIS file with the real
  // Session initializer. Written by the real update.js — not a hand fixture — so a key
  // rename on either side now fails a suite. Run the node suite before the swift one.
  const seamDir = path.resolve(__dirname, "..", "build", "seam");
  fs.mkdirSync(seamDir, { recursive: true });
  fs.copyFileSync(path.join(stateDir(home), "pin1.json"), path.join(seamDir, "session.json"));
});

test("the seeded session file carries exactly the keys the swift reader parses", () => {
  const home = sandbox();
  run(lifecyclePath, home, ["start"], JSON.stringify({ session_id: "pin2", cwd: home }));

  const state = JSON.parse(fs.readFileSync(path.join(stateDir(home), "pin2.json"), "utf8"));
  assert.deepEqual(Object.keys(state).sort(), [
    "cwd", "entrypoint", "label", "pid", "project", "sessionId", "started", "startedAt",
    "state", "term_bundle", "term_program", "tool", "transcript", "ts",
  ]);
  assert.equal(state.started, false, "a merely-opened session stays out of the dropdown");
  assert.equal(state.state, "idle");
});
