#!/usr/bin/env python3
"""SessionStart, plugin channel: claim the hooks, converge the app, launch it.

Claude Code plugins have no postinstall step, so the assembly happens here. Idempotent and
cheap: with the right version already installed and running, it does almost nothing. The
expensive part — compiling the app — runs only when the plugin version changed, i.e. after
an upgrade.
"""

import json
import os
import plistlib
import subprocess
import sys

PLUGIN_ROOT = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".claude", "control-bar")
PATHS = os.path.join(ROOT, "paths.json")
OWNER = os.path.join(ROOT, "owner.json")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")


def identity():
    """Read identity.env — the one place the product's names are declared."""
    values = {}
    try:
        with open(os.path.join(PLUGIN_ROOT, "identity.env")) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"')
    except OSError:
        pass
    return values


ID = identity()
BUNDLE_ID = ID.get("BUNDLE_ID", "io.github.infinityscripter.claude-control-bar")
EXEC = ID.get("EXEC", "ClaudeControlBar")
APP_NAME = ID.get("APP_NAME", "Claude Control Bar")
USER_APP = os.path.join(HOME, "Applications", APP_NAME + ".app")
SYSTEM_APP = os.path.join("/Applications", APP_NAME + ".app")


def read_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def plugin_version():
    manifest = read_json(os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json")) or {}
    return manifest.get("version", "0.0.0")


def bundle_version(app):
    """Version of the bundle at `app`, or None when it is missing or is not ours."""
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as fh:
            info = plistlib.load(fh)
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            return None
        return info.get("CFBundleShortVersionString")
    except Exception:
        return None


def running():
    return subprocess.run(["/usr/bin/pgrep", "-x", EXEC], capture_output=True).returncode == 0


def claim_hooks():
    """Declare the plugin the owner of the hooks and clear the app channel's duplicates.

    Both channels install the same eight hooks, and Claude Code merges plugin hooks with the
    ones in settings.json and runs every match — there is no deduplication anywhere. Someone
    with both installed pays two node processes per tool call, forever. The plugin wins because
    Claude Code removes its own hooks on `plugin uninstall`, while hooks written into
    settings.json outlive an uninstall the app may never get the chance to run.
    """
    write_json(OWNER, {"channel": "plugin", "pluginRoot": PLUGIN_ROOT,
                       "version": plugin_version()})
    # Cheap guard: only spawn node when settings.json actually mentions our directory.
    try:
        with open(SETTINGS) as fh:
            if ROOT not in fh.read():
                return
    except OSError:
        return
    uninstall = os.path.join(PLUGIN_ROOT, "hooks", "uninstall.js")
    node = next((p for p in ("/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node")
                 if os.access(p, os.X_OK)), None)
    if node and os.path.exists(uninstall):
        subprocess.run([node, uninstall, "--hooks-only"], capture_output=True, timeout=20)


def write_paths():
    """Where the app finds its MCP backend.

    Rewritten on every start because the plugin directory carries the version in its path, so
    it moves with every upgrade and a remembered path goes stale immediately.
    """
    write_json(PATHS, {
        # Always the system python: the script uses nothing outside the standard library, and
        # pyenv/nvm are not on a GUI process's PATH — pointing at one of those would break the
        # launch on exactly the machines that have them.
        "python": "/usr/bin/python3",
        "script": os.path.join(PLUGIN_ROOT, "scripts", "mcpbar.py"),
        "pluginRoot": PLUGIN_ROOT,
        "version": plugin_version(),
    })


def build(target):
    script = os.path.join(PLUGIN_ROOT, "build.sh")
    if not os.path.exists(script):
        return False
    result = subprocess.run(["/bin/bash", script], capture_output=True, text=True, timeout=300,
                            env={**os.environ, "CONTROL_BAR_APP": target})
    if result.returncode != 0:
        os.makedirs(ROOT, exist_ok=True)
        with open(os.path.join(ROOT, "problems.log"), "a") as fh:
            fh.write(f"build failed:\n{result.stderr[-2000:]}\n")
        return False
    return True


def main():
    # The hook gets its event on stdin. Nothing here needs it, but the pipe has to be drained.
    try:
        sys.stdin.read()
    except Exception:
        pass

    if sys.platform != "darwin":
        return 0

    write_paths()
    claim_hooks()

    # A brew/DMG install owns /Applications. Building over it would corrupt a bundle Homebrew
    # believes it manages, and both copies would sit in the menu bar at once. The plugin defers
    # to it and builds its own copy only when that slot is empty.
    if bundle_version(SYSTEM_APP):
        if not running():
            subprocess.Popen(["/usr/bin/open", "-g", "-b", BUNDLE_ID],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0

    if bundle_version(USER_APP) != plugin_version():
        # One build at a time. Claude Code runs every matching SessionStart hook in parallel,
        # so two terminals opened together both notice the version gap and both start a
        # multi-minute compile of the same plugin directory. The loser of this race skips:
        # the winner's result is the same bundle it would have produced.
        import fcntl
        os.makedirs(ROOT, exist_ok=True)
        lock = open(os.path.join(ROOT, "build.lock"), "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        try:
            if not build(USER_APP):
                return 0
            # The previous version is still resident; a fresh build has to replace it.
            subprocess.run(["/usr/bin/pkill", "-x", EXEC], capture_output=True)
        finally:
            lock.close()

    if not running():
        subprocess.Popen(["/usr/bin/open", "-g", "-b", BUNDLE_ID],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
