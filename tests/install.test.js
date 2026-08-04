const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

const installerPath = path.resolve(__dirname, "../hooks/install.js");
const uninstallerPath = path.resolve(__dirname, "../hooks/uninstall.js");
const staleNode = "/opt/homebrew/Cellar/node/26.5.0/bin/node";
const nodePathPrefix =
  'PATH="/opt/homebrew/bin:/usr/local/bin${PATH:+:$PATH}" node ';

const runScript = (scriptPath, home) => {
  const script = [
    `require("node:child_process").execSync = () => {};`,
    `Object.defineProperty(process, "execPath", { value: process.env.MOCK_EXEC_PATH });`,
    `require(process.env.SCRIPT_PATH);`,
  ].join("\n");

  execFileSync(process.execPath, ["-e", script], {
    env: {
      ...process.env,
      HOME: home,
      SCRIPT_PATH: scriptPath,
      MOCK_EXEC_PATH: staleNode,
    },
    stdio: "pipe",
  });
};

const runInstaller = (home) => runScript(installerPath, home);
const runUninstaller = (home) => runScript(uninstallerPath, home);

const readSettings = (home) => {
  const settingsPath = path.join(home, ".claude", "settings.json");
  return JSON.parse(fs.readFileSync(settingsPath, "utf8"));
};

const hookCommands = (settings) => {
  return Object.values(settings.hooks)
    .flat()
    .flatMap((entry) => entry.hooks || [])
    .map((hook) => hook.command || "");
};

const statusBarCommands = (settings) =>
  hookCommands(settings).filter((command) => command.startsWith(nodePathPrefix));

const shellQuote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;
const shellDoubleQuote = (value) =>
  value.replace(/["\\`$]/g, (character) => `\\${character}`);

test("installs portable, quoted hook commands and replaces stale hooks", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude $`\"' status bar test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  const claudeDir = path.join(home, ".claude");
  const settingsPath = path.join(claudeDir, "settings.json");
  const oldScript = path.join(claudeDir, "control-bar", "update.js");
  const unrelatedCommand = "echo keep-me";
  const original = {
    customSetting: true,
    hooks: {
      PreToolUse: [
        {
          matcher: "*",
          hooks: [
            { type: "command", command: `${staleNode} ${oldScript} pre` },
            { type: "command", command: unrelatedCommand },
            { type: "prompt" },
          ],
        },
      ],
      Notification: [{ matcher: "empty-entry" }],
    },
  };
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify(original, null, 2));
  const oldAgentPlist = path.join(
    home,
    "Library",
    "LaunchAgents",
    "com.local.claudestatusbar.watcher.plist",
  );
  fs.mkdirSync(path.dirname(oldAgentPlist), { recursive: true });
  fs.writeFileSync(oldAgentPlist, "obsolete");

  runInstaller(home);

  const settings = readSettings(home);
  const allCommands = hookCommands(settings);
  const commands = statusBarCommands(settings);
  const updatePath = path.join(claudeDir, "control-bar", "update.js");
  const lifecyclePath = path.join(claudeDir, "control-bar", "lifecycle.js");

  assert.equal(settings.customSetting, true);
  assert.equal(fs.existsSync(oldAgentPlist), false);
  assert.equal(commands.length, 8);
  assert.ok(commands.every((command) => command.startsWith(nodePathPrefix)));
  assert.ok(allCommands.every((command) => !command.includes(staleNode)));
  assert.ok(allCommands.every((command) => !command.includes(process.execPath)));
  assert.ok(commands.includes(`${nodePathPrefix}${shellQuote(updatePath)} pre`));
  assert.ok(commands.includes(`${nodePathPrefix}${shellQuote(lifecyclePath)} start`));

  const lifecycleEnd = commands.find((command) => command.endsWith(" end"));
  const fixtureBin = path.join(home, "minimal-bin");
  fs.mkdirSync(fixtureBin);
  fs.symlinkSync(process.execPath, path.join(fixtureBin, "node"));
  const statePath = path.join(
    claudeDir,
    "control-bar",
    "state.d",
    "quoted-path-test.json",
  );
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  fs.writeFileSync(statePath, "{}");
  const fixtureCommand = lifecycleEnd.replace(
    "/opt/homebrew/bin:/usr/local/bin",
    shellDoubleQuote(fixtureBin),
  );
  const noNodeEnvironment = {
    ...process.env,
    HOME: home,
    PATH: "",
  };
  assert.throws(() => {
    execFileSync("/bin/sh", ["-c", "command -v node"], {
      env: noNodeEnvironment,
      stdio: "pipe",
    });
  });
  execFileSync("/bin/sh", ["-c", fixtureCommand], {
    env: noNodeEnvironment,
    input: JSON.stringify({ session_id: "quoted-path-test" }),
    stdio: "pipe",
  });
  assert.equal(fs.existsSync(statePath), false);

  assert.equal(allCommands.filter((command) => command === unrelatedCommand).length, 1);
  assert.equal(
    settings.hooks.PreToolUse.flatMap((entry) => entry.hooks).filter(
      (hook) => hook.type === "prompt",
    ).length,
    1,
  );
  assert.deepEqual(
    JSON.parse(fs.readFileSync(`${settingsPath}.bak-control-bar`, "utf8")),
    original,
  );

  const firstInstall = settings;
  runInstaller(home);
  assert.deepEqual(readSettings(home), firstInstall);

  runUninstaller(home);
  const uninstalled = readSettings(home);
  assert.equal(statusBarCommands(uninstalled).length, 0);
  assert.equal(uninstalled.customSetting, true);
  assert.equal(
    uninstalled.hooks.PreToolUse.flatMap((entry) => entry.hooks).filter(
      (hook) => hook.command === unrelatedCommand,
    ).length,
    1,
  );
});

test("reinstalling is idempotent", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude status bar test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  runInstaller(home);
  const first = readSettings(home);
  runInstaller(home);
  const second = readSettings(home);

  assert.deepEqual(second, first);
  assert.equal(statusBarCommands(second).length, 8);
});

test("an empty inherited PATH never searches the working directory", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude status bar security test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  runInstaller(home);
  const lifecycleEnd = hookCommands(readSettings(home)).find(
    (command) => command.includes("lifecycle.js") && command.endsWith(" end"),
  );
  const hostileCwd = path.join(home, "hostile-project");
  const canaryPath = path.join(home, "cwd-node-ran");
  fs.mkdirSync(hostileCwd);
  fs.writeFileSync(
    path.join(hostileCwd, "node"),
    `#!/bin/sh\n: > ${shellQuote(canaryPath)}\nexit 0\n`,
  );
  fs.chmodSync(path.join(hostileCwd, "node"), 0o755);

  const missingFallbacks = [
    path.join(home, "missing-homebrew-bin"),
    path.join(home, "missing-local-bin"),
  ].join(":");
  const isolatedCommand = lifecycleEnd.replace(
    "/opt/homebrew/bin:/usr/local/bin",
    shellDoubleQuote(missingFallbacks),
  );

  assert.throws(
    () => {
      execFileSync("/bin/sh", ["-c", isolatedCommand], {
        cwd: hostileCwd,
        env: {
          ...process.env,
          HOME: home,
          PATH: "",
        },
        input: JSON.stringify({ session_id: "security-test" }),
        stdio: "pipe",
      });
    },
    (error) => error.status === 127,
  );
  assert.equal(fs.existsSync(canaryPath), false);
});
