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
// process" — the branch under test.
const run = (scriptPath, home, argv = [], stdin = "{}") =>
  execFileSync(
    process.execPath,
    ["-e", [
      `require("node:child_process").execSync = () => { throw new Error("pgrep: no match"); };`,
      `require("node:child_process").spawn = () => ({ unref() {} });`,
      `require(process.env.SCRIPT_PATH);`,
      // The scripts read their event from process.argv[2]. Under `node -e` the script path is
      // not in argv, so it is put back here — otherwise the event lands in argv[1] and every
      // hook silently takes its "unknown event" branch and writes nothing.
    ].join("\n"), scriptPath, ...argv],
    { env: { ...process.env, HOME: home, SCRIPT_PATH: scriptPath }, input: stdin, stdio: "pipe" }
  ).toString();

const settingsPath = (home) => path.join(home, ".claude", "settings.json");
const stateDir = (home) => path.join(home, ".claude", "control-bar", "state.d");

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
      // Sneak a write in between the installer's read and its rename.
      `const fs = require("node:fs");`,
      `const real = fs.copyFileSync;`,
      `fs.copyFileSync = (...a) => { real(...a); fs.writeFileSync(process.env.SETTINGS, JSON.stringify({ theirs: true }, null, 2) + "\\n"); };`,
      `require(process.env.SCRIPT_PATH);`,
    ].join("\n"), installerPath],
    { env: { ...process.env, HOME: home, SCRIPT_PATH: installerPath, SETTINGS: settingsPath(home) },
      input: "{}", stdio: "pipe" }
  ).toString();
  assert.match(out, /changed while we were working on it/);
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsPath(home), "utf8")), { theirs: true });
  assert.equal(fs.readdirSync(path.join(home, ".claude")).filter((f) => f.endsWith(".tmp")).length, 0);
});
