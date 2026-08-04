#!/usr/bin/env python3
"""Reads one statusLine payload from stdin and keeps two facts out of it.

Runs detached in the background from statusline.sh, so it must never print and never raise
in a way that reaches the terminal: whatever it does, the user's status line has already
been drawn by then.

1. Rate limits (5h / 7d). Claude Code holds these in memory and hands them to statusLine
   alone — no file, no CLI flag. They are per account, not per session, so one terminal
   session keeps the figure fresh for every window the app shows.

2. The real context window of the model that just answered. The scraped model table is
   incomplete by nature (a transcript records the served model name, which may not exist in
   the local registry at all — claude-opus-5 does not), and this payload states the size
   outright. An observed size beats a scraped one and beats a guess, so it is remembered.
"""

import json
import os
import sys
import time

ROOT = os.environ.get("CONTROL_BAR_ROOT") or os.path.expanduser("~/.claude/control-bar")
LIMITS = os.path.join(ROOT, "limits.json")
WINDOWS = os.path.join(ROOT, "model-windows.json")


def read_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def atomic_write(path, data):
    # 0700/0600, а не umask: здесь лежат проценты лимитов аккаунта и таблица окон, а домашний
    # каталог на macOS открыт группе staff — то есть каждому локальному пользователю машины.
    # Дескриптор открывается сразу с правами: chmod после записи оставил бы окно, в котором
    # файл читаем всем.
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def capture_limits(payload):
    """rate_limits -> limits.json, in the shape mcpbar.py and the app already read."""
    limits = payload.get("rate_limits")
    # The block ships only to subscribers, and only after the first API response of a session.
    # Writing an empty record on the early redraws would wipe the last good figures with
    # nothing, and the menu would flap between "68%" and no limits section at all.
    if not isinstance(limits, dict) or not limits:
        return
    record = {"ts": int(time.time()), "source": "statusline"}
    # Iterated rather than named: 2.1.205 also emits seven_day_opus, seven_day_sonnet and
    # seven_day_overage_included, and a plan that gains another window should not need a patch.
    for name, block in limits.items():
        if not isinstance(block, dict) or block.get("used_percentage") is None:
            continue
        record[name] = {
            # int(round(...)) is load-bearing. The payload reports fractional percentages, and
            # the app reads this with `as? Int` — which returns nil for 4.2, so the limits
            # silently disappear from the menu bar while the file looks perfectly healthy.
            "used_percentage": int(round(float(block["used_percentage"]))),
            "resets_at": block.get("resets_at"),
        }
    if len(record) <= 2:
        return
    # Unchanged values are not rewritten while the file is fresh. The status line can redraw
    # every second with refreshInterval set, and the figures move on the scale of minutes —
    # rewriting an identical record each redraw is pure disk churn. The timestamp is allowed
    # to age up to a minute, so "measured N min ago" stays honest without a write per redraw.
    previous = read_json(LIMITS) or {}
    same = all(previous.get(k) == v for k, v in record.items() if k not in ("ts", "source"))
    if same and record["ts"] - (previous.get("ts") or 0) < 60:
        return
    atomic_write(LIMITS, record)


def learn_window(payload):
    """Remember the context window this model actually has.

    Kept under its own key so a rescrape of the Claude Code binary (which happens on every
    upgrade) merges observations back in rather than dropping them.
    """
    window = payload.get("context_window") or {}
    size = window.get("context_window_size")
    model = ((payload.get("model") or {}).get("id") or "").lower()
    if not model or not isinstance(size, (int, float)) or size <= 0:
        return
    cache = read_json(WINDOWS) or {}
    observed = cache.get("observed") or {}
    if observed.get(model) == int(size):
        return
    observed[model] = int(size)
    cache["observed"] = observed
    # Observation wins over the scraped table: it came from the model that just answered.
    cache["models"] = {**(cache.get("models") or {}), **observed}
    atomic_write(WINDOWS, cache)


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0
    for step in (capture_limits, learn_window):
        try:
            step(payload)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
