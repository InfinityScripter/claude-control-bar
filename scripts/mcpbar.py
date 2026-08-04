#!/usr/bin/env python3
"""Claude Control Bar — MCP-бэкенд: состояние серверов, инструменты, переключатели.

Работает только со стандартной библиотекой: скрипт вызывается из GUI-приложения,
где PATH урезан и никакого pyenv нет.

Разделение труда в приложении: сессии и их контекст ведут Node-хуки (state.d/),
MCP-картину ведёт этот скрипт (mcp.json), рисует всё Swift.

Команды:
    refresh          проверить всё заново и переписать mcp.json (медленно, ~7 сек)
    report           человекочитаемая карта
    line             компактный сегмент для statusLine
    toggle-server    выключить/включить сервер целиком
    toggle-tool      выключить/включить отдельный инструмент
    statusline       перехват лимитов: --install / --uninstall / без флага — статус
    doctor           проверить окружение и показать, что откуда берётся
"""

import glob
import json
import os
import re
import sys
import time

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
ROOT = os.path.join(CLAUDE, "control-bar")
STATE = os.path.join(ROOT, "mcp.json")
LIMITS = os.path.join(ROOT, "limits.json")
# Сессии ведут Node-хуки: один файл на сессию, тот же каталог читает приложение.
# Свой реестр сессий скрипт не держит намеренно — два источника правды разошлись бы.
SESSIONS = os.path.join(ROOT, "state.d")
LOCK = os.path.join(ROOT, "refresh.lock")

CONFIG = os.path.join(HOME, ".claude.json")
SETTINGS = os.path.join(CLAUDE, "settings.json")
NEEDS_AUTH = os.path.join(CLAUDE, "mcp-needs-auth-cache.json")
MCP_LOGS = os.path.join(HOME, "Library", "Caches", "claude-cli-nodejs", "*", "mcp-logs-*")
DESKTOP_SESSIONS = os.path.join(
    HOME, "Library", "Application Support", "Claude", "claude-code-sessions"
)
TRANSCRIPTS = os.path.join(CLAUDE, "projects", "*", "*.jsonl")

TTL = int(os.environ.get("CONTROL_BAR_TTL", "600"))
LOCK_TTL = 120

OK, FAILED, PENDING, AUTH, OFF = "ok", "failed", "pending", "auth", "off"


# ──────────────────────────────────────────────────────────── язык

LANGS = ("en", "ru")


def detect_lang():
    """Язык интерфейса. Приложение и отчёт должны говорить одинаково."""
    forced = os.environ.get("CONTROL_BAR_LANG", "").lower()[:2]
    if forced in LANGS:
        return forced
    for var in ("LC_ALL", "LC_MESSAGES", "LANG"):
        if os.environ.get(var, "").lower().startswith("ru"):
            return "ru"
    # GUI-процессу переменных локали не достаётся — спрашиваем систему напрямую.
    try:
        import plistlib

        prefs = os.path.join(HOME, "Library", "Preferences", ".GlobalPreferences.plist")
        with open(prefs, "rb") as fh:
            languages = plistlib.load(fh).get("AppleLanguages") or []
        if languages and str(languages[0]).lower().startswith("ru"):
            return "ru"
    except Exception:
        pass
    return "en"


LANG = detect_lang()

STRINGS = {
    "group.user": ("LOCAL CONFIG  ~/.claude.json", "ЛОКАЛЬНЫЙ КОНФИГ  ~/.claude.json"),
    "group.claude.ai": ("CLAUDE.AI CONNECTORS", "КОННЕКТОРЫ CLAUDE.AI"),
    "group.plugin": ("FROM PLUGINS", "ОТ ПЛАГИНОВ"),
    "group.project": ("PROJECT  .mcp.json", "ПРОЕКТНЫЕ  .mcp.json"),
    "head.auth": ("WAITING FOR AUTHORISATION", "ЖДУТ АВТОРИЗАЦИИ"),
    "head.sessions": ("SESSIONS", "СЕССИИ"),
    "head.limits": ("LIMITS", "ЛИМИТЫ"),
    "auth.hint": ("/mcp to authorise", "/mcp → авторизовать"),
    "server.off": ("disabled", "выключен"),
    "server.restart": ("on, from the next session", "включён, со следующей сессии"),
    "open.settings": ("Open settings.json", "Открыть settings.json"),
    "server.muted": ("({n} disabled)", "({n} выключено)"),
    "tools.none": ("— tools", "— инстр."),
    "session.context": ("context {pct}%", "контекст {pct}%"),
    "session.spent": ("{used} of {total}", "{used} из {total}"),
    "limits.five": ("5 hours", "5 часов"),
    "limits.seven": ("7 days", "7 дней"),
    "limits.age": ("data {n} min old, source: {src}", "данным {n} мин, источник: {src}"),
    "limits.none": ("not measured yet", "ещё не измерены"),
    "error.check": ("Check failed: {e}", "Ошибка проверки: {e}"),
    "summary": ("Total: {live}/{total} connected, {tools} {word}",
                "Итого: {live}/{total} на связи, {tools} {word}"),
    "summary.off": (", {n} disabled", ", {n} выключено"),
    "summary.auth": (", {n} unauthorised", ", {n} без авторизации"),
    "checked": ("Checked {n} s ago.", "Проверено {n} сек назад."),
    "err.nobinary": ("claude binary not found", "не нашла бинарь claude"),
    "err.timeout": ("claude mcp list timed out", "claude mcp list не ответил вовремя"),
    "err.empty": ("empty output", "пустой вывод"),
    "doc.binary": ("claude binary", "бинарь claude"),
    "doc.settings": ("settings", "настройки"),
    "doc.state": ("state", "состояние"),
    "doc.sessions": ("sessions registered", "сессий зарегистрировано"),
    "doc.off": ("servers disabled", "выключено серверов"),
    "doc.rules": ("tool rules", "правил на инструменты"),
    "doc.windows": ("model windows cached", "окон моделей в кеше"),
    "doc.missing": ("NOT FOUND", "НЕ НАЙДЕН"),
    "doc.nofile": ("no file", "нет файла"),
    "doc.nostate": ("not collected yet", "ещё не собрано"),
    "lang": ("interface language", "язык интерфейса"),
}


def t(key, **kw):
    text = STRINGS[key][0 if LANG == "en" else 1]
    return text.format(**kw) if kw else text


def plural_tools(count):
    if LANG == "en":
        return "tool" if count == 1 else "tools"
    tail, hundred = count % 10, count % 100
    if 11 <= hundred <= 14 or tail == 0 or tail >= 5:
        return "инструментов"
    return "инструмент" if tail == 1 else "инструмента"


# ──────────────────────────────────────────────────────────── общее

def read_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def write_json(path, data, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=indent)
        if indent:
            fh.write("\n")
    os.replace(tmp, path)


def write_settings(data):
    """settings.json человек правит руками — значит и мы пишем его для человека.

    Компактной записью первый же переключатель схлопывал файл пользователя в одну строку:
    ни прочитать, ни сравнить в git. Отступ тот же, что ставит сам Claude Code и hooks/install.js.
    """
    write_json(SETTINGS, data, indent=2)


def find_claude():
    for path in (
        os.path.join(HOME, ".local", "bin", "claude"),
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ):
        if os.access(path, os.X_OK):
            return path
    import shutil

    return shutil.which("claude")


# ──────────────────────────────────────────────────────────── состояние серверов

def parse_list_line(line):
    """`name: target - ✔ Connected` → запись о сервере.

    Имя режем по первому «двоеточие-пробел», а не по первому двоеточию: плагинные серверы
    называются plugin:figma:figma, и наивный split превращал их всех в «plugin».
    Статус берём по ПОСЛЕДНЕМУ « - »: у claude-mem команда запуска длиной 1400 символов
    и полна дефисов, по первому вхождению разбор бы развалился.
    """
    if ": " not in line or " - " not in line:
        return None
    name, rest = line.split(": ", 1)
    target, _, status = rest.rpartition(" - ")
    name, status = name.strip(), status.strip()
    if not name or not status:
        return None
    if "Connected" in status:
        state = OK
    elif "Pending" in status:
        state = PENDING
    else:
        state = FAILED
    return {"name": name, "target": target.strip(), "status": status, "state": state}


def run_health_check():
    """`claude mcp list` — единственный источник живого статуса. Флага --json у неё нет."""
    import subprocess

    claude = find_claude()
    if not claude:
        return [], t("err.nobinary")
    try:
        proc = subprocess.run(
            [claude, "mcp", "list"], capture_output=True, text=True, timeout=120
        )
    except subprocess.TimeoutExpired:
        return [], t("err.timeout")
    except Exception as exc:
        return [], str(exc)[:200]

    servers = [s for s in map(parse_list_line, proc.stdout.splitlines()) if s]
    if not servers:
        return [], (proc.stderr or proc.stdout or t("err.empty")).strip()[:200]
    return servers, None


# ──────────────────────────────────────────────────────────── число и имена инструментов

def counts_from_logs():
    """stdio-серверы печатают число инструментов в stderr при старте.

    Claude Code складывает stderr в ~/Library/Caches/claude-cli-nodejs/<cwd>/mcp-logs-<server>/,
    и переписывает на каждый `claude mcp list` — то есть refresh освежает их сам.
    Папки заведены на каждый cwd, поэтому берём запись с самым свежим mtime.
    В имени папки подчёркивания заменены дефисами: mcp-logs-my-server = my_server.
    """
    best = {}
    for folder in glob.glob(MCP_LOGS):
        server = os.path.basename(folder)[len("mcp-logs-") :]
        logs = sorted(glob.glob(folder + "/*.jsonl"), key=os.path.getmtime, reverse=True)
        for log in logs[:3]:
            count = None
            try:
                with open(log) as fh:
                    for line in fh:
                        found = re.search(r"(\d+)\s+tools available", line)
                        if found:
                            count = int(found.group(1))
            except OSError:
                continue
            if count is not None:
                mtime = os.path.getmtime(log)
                if server not in best or mtime > best[server][1]:
                    best[server] = (count, mtime)
                break
    return {k: v[0] for k, v in best.items()}


DESCRIPTIONS = os.path.join(ROOT, "descriptions.json")
DESCRIPTIONS_TTL = 24 * 3600
DESCRIPTIONS_FORMAT = 2


def describe_tool(tool):
    """Имя, описание и параметры — всё, что нужно карточке при наведении.

    Параметры лежат в inputSchema (это JSON Schema): properties плюс список required.
    Порядок properties оставляем как отдал сервер: он осмысленный, у большинства серверов
    обязательное идёт первым, и сортировка по алфавиту эту подсказку теряет.
    """
    schema = tool.get("inputSchema") or tool.get("input_schema") or {}
    required = set(schema.get("required") or [])
    params = [
        {
            "name": name,
            "type": (prop.get("type") if isinstance(prop, dict) else "") or "",
            "required": name in required,
            "description": ((prop.get("description") if isinstance(prop, dict) else "") or "").strip(),
        }
        for name, prop in (schema.get("properties") or {}).items()
    ]
    return {
        "name": tool.get("name", ""),
        "description": (tool.get("description") or "").strip(),
        "params": params,
    }


def ask_server_for_tools(name, config, timeout=20):
    """Спросить у сервера его инструменты по протоколу MCP (JSON-RPC поверх stdio).

    Ни логи, ни транскрипты описаний не содержат — их знает только сам сервер.
    Порядок обязательный: initialize → notifications/initialized → tools/list.
    Читаем построчно в отдельном потоке: иначе на таймауте всё виснет.
    """
    import queue
    import subprocess
    import threading

    command = config.get("command")
    if not command or config.get("type", "stdio") != "stdio":
        return None

    try:
        proc = subprocess.Popen(
            [command] + list(config.get("args") or []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1, env={**os.environ, **(config.get("env") or {})},
        )
    except Exception:
        return None

    lines = queue.Queue()

    def pump():
        try:
            for line in proc.stdout:
                lines.put(line)
        except Exception:
            pass
        lines.put(None)

    threading.Thread(target=pump, daemon=True).start()

    def send(payload):
        proc.stdin.write(json.dumps(payload) + "\n")
        proc.stdin.flush()

    def await_id(wanted, deadline):
        while time.time() < deadline:
            try:
                line = lines.get(timeout=max(0.1, deadline - time.time()))
            except Exception:
                return None
            if line is None:
                return None
            if not line.lstrip().startswith("{"):
                continue  # транспорт иногда пишет в stdout не-JSON
            message = read_json_line(line)
            if message and message.get("id") == wanted:
                return message
        return None

    deadline = time.time() + timeout
    tools = []
    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "claude-control-bar", "version": "1.0"}}})
        if not await_id(1, deadline):
            return None
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})

        cursor, request_id = None, 2
        while True:
            params = {"cursor": cursor} if cursor else {}
            send({"jsonrpc": "2.0", "id": request_id, "method": "tools/list", "params": params})
            answer = await_id(request_id, deadline)
            result = (answer or {}).get("result") or {}
            tools += [describe_tool(t) for t in result.get("tools") or []]
            cursor = result.get("nextCursor")
            request_id += 1
            if not cursor or time.time() > deadline:
                break
    except Exception:
        return None
    finally:
        try:
            proc.stdin.close()
            proc.terminate()
        except Exception:
            pass

    return tools or None


def refresh_descriptions(force=False):
    """Описания меняются редко, а опрос поднимает все серверы — держим сутки в кеше."""
    import threading

    cached = read_json(DESCRIPTIONS) or {}
    servers = (read_json(CONFIG) or {}).get("mcpServers") or {}
    fresh_until = time.time() - DESCRIPTIONS_TTL
    # Формат записи версионируем: в первой версии параметров инструментов не было,
    # и без этой проверки карточка при наведении оставалась бы пустой ещё сутки —
    # ровно до истечения TTL, уже собранного старым кодом.
    todo = [
        (name, config) for name, config in servers.items()
        if force
        or (cached.get(name, {}).get("ts") or 0) < fresh_until
        or cached.get(name, {}).get("v") != DESCRIPTIONS_FORMAT
    ]
    if not todo:
        return cached

    results = {}
    lock = threading.Lock()

    def work(name, config):
        tools = ask_server_for_tools(name, config)
        if tools:
            with lock:
                results[name] = {
                    "ts": int(time.time()), "v": DESCRIPTIONS_FORMAT, "tools": tools
                }

    threads = [threading.Thread(target=work, args=pair, daemon=True) for pair in todo]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    cached.update(results)
    write_json(DESCRIPTIONS, cached)
    return cached


def connectors_from_desktop():
    """Коннекторы claude.ai в stderr молчат — их схемы кеширует десктоп-приложение."""
    files = sorted(
        glob.glob(DESKTOP_SESSIONS + "/**/*.json", recursive=True),
        key=os.path.getmtime,
        reverse=True,
    )
    for path in files[:200]:
        remote = (read_json(path) or {}).get("remoteMcpServersConfig")
        if remote:
            return {
                s["name"]: [describe_tool(t) for t in (s.get("tools") or [])]
                for s in remote
            }
    return {}


def tool_names_from_transcripts():
    """Имена инструментов нужны для поштучных запретов — их даёт только транскрипт.

    Claude Code пишет записи deferred_tools_delta с полными именами вида mcp__wiki__GetPageById.
    Свежий по mtime файл может дельт не содержать (транскрипты субагентов), поэтому ищем перебором.
    """
    files = sorted(glob.glob(TRANSCRIPTS), key=os.path.getmtime, reverse=True)
    for path in files[:60]:
        names = []
        try:
            with open(path) as fh:
                for line in fh:
                    if '"deferred_tools_delta"' not in line:
                        continue
                    delta = (read_json_line(line) or {}).get("attachment") or {}
                    names += delta.get("addedNames", []) + delta.get("readdedNames", [])
                    for gone in delta.get("removedNames", []):
                        if gone in names:
                            names.remove(gone)
        except OSError:
            continue
        if not names:
            continue
        grouped = {}
        for full in names:
            parts = full.split("__", 2)
            if full.startswith("mcp__") and len(parts) == 3:
                grouped.setdefault(parts[1], []).append(parts[2])
        if grouped:
            return {k: sorted(v) for k, v in grouped.items()}
    return {}


def read_json_line(line):
    try:
        return json.loads(line)
    except Exception:
        return None


def classify(name, local_servers):
    if name.startswith("claude.ai "):
        return "claude.ai"
    if name.startswith("plugin:"):
        return "plugin"
    return "user" if name in local_servers else "project"


def short_name(name):
    """Имя без служебных приставок: claude.ai Figma → Figma, plugin:figma:figma → figma."""
    if name.startswith("claude.ai "):
        return name[len("claude.ai ") :]
    if name.startswith("plugin:"):
        return name.rsplit(":", 1)[-1]
    return name


def lookup_tools(index, name):
    """В транскрипте сервер зовётся иначе, чем в списке, — пробуем несколько написаний."""
    for candidate in (name, short_name(name), name.replace("_", "-")):
        hit = index.get(candidate.lower())
        if hit:
            return hit
    return []


def attach_tools(servers):
    """Проставить каждому серверу инструменты: имена, описания и счётчик.

    Источники по убыванию полноты: опрос самого сервера (даёт описания),
    кеш десктоп-приложения для коннекторов (тоже с описаниями),
    транскрипты (только имена — на них и падаем, если сервер не ответил).
    """
    counts = {k.replace("_", "-"): v for k, v in counts_from_logs().items()}
    connectors = connectors_from_desktop()
    asked = refresh_descriptions()
    index = {k.lower(): v for k, v in tool_names_from_transcripts().items()}

    for entry in servers:
        bare = short_name(entry["name"])
        described = []
        if entry["name"] in asked:
            described = asked[entry["name"]]["tools"]
        elif bare in connectors:
            described = connectors[bare]
        names = sorted(t["name"] for t in described) if described \
            else lookup_tools(index, entry["name"])

        entry["toolNames"] = names
        entry["toolDocs"] = {t["name"]: t["description"] for t in described if t.get("description")}
        entry["toolParams"] = {t["name"]: t["params"] for t in described if t.get("params")}
        entry["tools"] = counts.get(bare.replace("_", "-"))
        # Счётчика из логов нет (коннекторы и плагины его не печатают) — считаем по именам.
        if entry["tools"] is None and names:
            entry["tools"] = len(names)


# ──────────────────────────────────────────────────────────── запреты

def denied_servers():
    """`deniedMcpServers` в settings.json — единственный способ выключить сервер глобально.

    Проверено запуском: запись объектная, плоскую строку Claude Code молча игнорирует.
    """
    raw = (read_json(SETTINGS) or {}).get("deniedMcpServers") or []
    return [d["serverName"] for d in raw if isinstance(d, dict) and "serverName" in d]


def denied_tools():
    """`permissions.deny` не просто запрещает вызов, а вырезает инструмент из контекста.

    Проверено: одно правило mcp__docs__read_page уменьшило список с 26 инструментов до 25.
    """
    perms = (read_json(SETTINGS) or {}).get("permissions") or {}
    return [rule for rule in (perms.get("deny") or []) if rule.startswith("mcp__")]


def tool_denied(rules, server, tool):
    """Инструмент погашен правилом на весь сервер, точным именем или глобом."""
    full = f"mcp__{server}__{tool}"
    for rule in rules:
        if rule == f"mcp__{server}" or rule == full:
            return True
        if rule.endswith("*") and full.startswith(rule[:-1]):
            return True
    return False


def backup_settings():
    settings = read_json(SETTINGS)
    if settings is None:
        return None
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = f"{SETTINGS}.bak-{stamp}"
    if not os.path.exists(path):
        write_json(path, settings)
    # Переключатель дёргают часто — храним десяток последних снимков, остальное чистим.
    ours = sorted(glob.glob(f"{SETTINGS}.bak-2*"), reverse=True)
    for stale in ours[10:]:
        try:
            os.remove(stale)
        except OSError:
            pass
    return path


def patch_state_after_toggle():
    """Пересчитать в состоянии только то, что зависит от настроек.

    Полная проверка занимает семь секунд — для переключателя в меню это вечность.
    Здесь же переключатель обязан отзываться мгновенно, поэтому трогаем ровно
    признаки «выключен» и «погашенные инструменты», остальное оставляем как было.
    """
    data = load_state()
    if not data:
        return None
    off = set(denied_servers())
    rules = denied_tools()
    known = {s["name"] for s in data.get("servers", [])}
    local = set((read_json(CONFIG) or {}).get("mcpServers") or {})

    for name in off - known:
        data.setdefault("servers", []).append({
            "name": name, "target": "", "status": t("server.off"), "state": OFF,
            "source": classify(name, local), "tools": None, "toolNames": [], "toolDocs": {},
        })
    for entry in data.get("servers", []):
        entry["disabled"] = entry["name"] in off
        if entry["disabled"]:
            entry["state"] = OFF
        elif entry.get("state") == OFF:
            # Включили обратно: до следующей проверки честнее сказать «неизвестно», а не
            # рисовать зелёный кружок. Проверка приезжает следом — приложение заказывает её
            # сразу после переключения, а не ждёт своего десятиминутного таймера.
            entry["state"] = PENDING
            entry["status"] = t("server.restart")
        entry["deniedTools"] = [
            tool for tool in entry.get("toolNames", [])
            if tool_denied(rules, entry["name"], tool)
        ]
    data["denyRules"] = rules
    write_json(STATE, data)
    return data


def toggle_server(name, turn_off):
    settings = read_json(SETTINGS) or {}
    current = settings.get("deniedMcpServers") or []
    kept = [
        d for d in current
        if not (isinstance(d, dict) and d.get("serverName") == name)
    ]
    if turn_off:
        kept.append({"serverName": name})
    if kept == current:
        return False
    backup_settings()
    if kept:
        settings["deniedMcpServers"] = kept
    else:
        settings.pop("deniedMcpServers", None)
    write_settings(settings)
    return True


def toggle_tool(rule, turn_off):
    settings = read_json(SETTINGS) or {}
    perms = settings.setdefault("permissions", {})
    current = list(perms.get("deny") or [])
    kept = [r for r in current if r != rule]
    if turn_off:
        kept.append(rule)
    if kept == current:
        return False
    backup_settings()
    if kept:
        perms["deny"] = kept
    else:
        # Не оставлять за собой пустой ключ: настройки должны вернуться ровно к тому,
        # что было до первого переключения.
        perms.pop("deny", None)
        if not perms:
            settings.pop("permissions", None)
    write_settings(settings)
    return True


# ──────────────────────────────────────────────────────── перехват statusLine

STATUSLINE_INNER = os.path.join(ROOT, "statusline-inner-command")


def find_statusline_wrapper():
    """Обёртка лежит рядом с этим скриптом, но раскладка разная в двух каналах поставки.

    В плагине и в репозитории это hooks/statusline.sh; внутри собранного .app всё
    вспомогательное сложено плоско в Contents/Resources.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    parent = os.path.dirname(here)
    for candidate in (
        os.path.join(parent, "hooks", "statusline.sh"),
        os.path.join(parent, "statusline.sh"),
    ):
        if os.path.exists(candidate):
            return candidate
    return None


def statusline_state():
    current = ((read_json(SETTINGS) or {}).get("statusLine") or {}).get("command") or ""
    return current.strip(), "statusline.sh" in current


def statusline_install():
    """Обернуть уже настроенный statusLine, не потеряв его.

    Лимиты Claude Code не хранит на диске вовсе — они живут в памяти процесса и выходят
    наружу единственной дверью, payload'ом statusLine. Поэтому единственный бесплатный
    способ их увидеть — встать в эту дверь, ничего в ней не сломав.
    """
    wrapper = find_statusline_wrapper()
    if not wrapper:
        return "statusline.sh не найден рядом со скриптом"
    current, ours = statusline_state()
    if ours:
        return "уже установлен"

    settings = read_json(SETTINGS) or {}
    backup_settings()
    os.makedirs(ROOT, exist_ok=True)
    # Дословно, включая пустую строку: по ней же делается откат.
    tmp = STATUSLINE_INNER + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(current + "\n")
    os.replace(tmp, STATUSLINE_INNER)
    settings["statusLine"] = {"type": "command", "command": f'bash "{wrapper}"'}
    write_settings(settings)
    return f"установлен; прежняя команда сохранена: {current or '(её не было)'}"


def statusline_uninstall():
    current, ours = statusline_state()
    if not ours:
        return "не установлен — statusLine не наш, ничего не трогаю"
    saved = ""
    try:
        with open(STATUSLINE_INNER) as fh:
            saved = fh.read().strip()
    except OSError:
        pass
    settings = read_json(SETTINGS) or {}
    backup_settings()
    if saved:
        settings["statusLine"] = {"type": "command", "command": saved}
    else:
        settings.pop("statusLine", None)
    write_settings(settings)
    return f"возвращено: {saved or '(statusLine удалён)'}"


# ──────────────────────────────────────────────────────────── лимиты по OAuth

# Тот же эндпоинт, которым /usage в самом Claude Code рисует свои проценты. statusLine-перехват
# остаётся вторым источником, но работает он только пока в терминале открыт CLI с живым TUI —
# у пользователя десктопного приложения лимиты через него не обновляются вообще. Опрос эндпоинта
# от сессий не зависит.
#
# Токен — тот, что Claude Code сам положил в Keychain. Он не печатается, не логируется и не
# уходит никуда, кроме api.anthropic.com. Чаще раза в 3 минуты спрашивать нельзя (community-
# консенсус: агрессивный rate limit), приложение ходит раз в 5.
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
CREDENTIALS_FILE = os.path.join(CLAUDE, ".credentials.json")


def oauth_token():
    """Access token Claude Code: Keychain на macOS, файл на Linux/Windows. None — не настроен."""
    import subprocess

    raw = ""
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=30,
        ).stdout.strip()
    except Exception:
        pass
    if not raw:
        try:
            with open(CREDENTIALS_FILE) as fh:
                raw = fh.read()
        except OSError:
            return None
    try:
        creds = json.loads(raw).get("claudeAiOauth") or {}
    except ValueError:
        return None
    # expiresAt в миллисекундах; просроченный токен вернёт 401, но честнее не ходить вовсе —
    # CLI сам обновит запись при следующем запуске.
    expires = creds.get("expiresAt")
    if isinstance(expires, (int, float)) and expires / 1000 < time.time():
        return None
    return creds.get("accessToken") or None


def parse_reset(value):
    """resets_at приходит ISO-строкой с таймзоной; statusLine шлёт epoch. Наружу — epoch int."""
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        from datetime import datetime

        try:
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
        except ValueError:
            return None
    return None


def usage_record(payload, now=None):
    """Ответ эндпоинта → limits.json той же формы, что пишет statusline.py.

    Поле там называется utilization, в statusLine — used_percentage; наружу всегда
    used_percentage и всегда int: Swift читает `as? Int`, и дробное значение молча
    выключило бы секцию лимитов при здоровом на вид файле.
    """
    record = {"ts": int(now or time.time()), "source": "oauth"}
    for name, block in (payload or {}).items():
        if not isinstance(block, dict):
            continue
        used = block.get("utilization", block.get("used_percentage"))
        if used is None:
            continue
        record[name] = {
            "used_percentage": int(round(float(used))),
            "resets_at": parse_reset(block.get("resets_at")),
        }
    return record if len(record) > 2 else None


def fetch_limits():
    """Один опрос: токен → эндпоинт → limits.json. Молчалив при любом сбое — прошлые
    цифры в файле лучше, чем затёртые ошибкой."""
    token = oauth_token()
    if not token:
        return "нет токена: Claude Code не залогинен через браузерный OAuth"
    import urllib.request

    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
        # Без узнаваемого UA запросы попадают в агрессивно лимитируемую корзину.
        "User-Agent": "claude-control-bar (statusline companion)",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 — сеть, 401, JSON: исход один, файл не трогаем
        return f"опрос не удался: {type(exc).__name__}"
    record = usage_record(payload)
    if not record:
        return "ответ без единого окна лимитов"
    write_json(LIMITS, record)
    windows = ", ".join(f"{k} {v['used_percentage']}%" for k, v in record.items()
                        if isinstance(v, dict))
    return f"обновлено: {windows}"


# ──────────────────────────────────────────────────────────── контекстное окно

WINDOW_CACHE = os.path.join(ROOT, "model-windows.json")
DEFAULT_WINDOW = 200_000

# Записи, по которым считать контекст нельзя: служебные ответы и прерванные ходы.
SKIP_TEXTS = {
    "[Request interrupted by user]",
    "[Request interrupted by user for tool use]",
    "No response requested.",
}


def scrape_model_windows():
    """Размеры окон живут в реестре моделей внутри бинаря CLI.

    Выскребаем один раз и кешируем: тогда обновление Claude Code не сломает расчёт.
    """
    claude = find_claude()
    if not claude:
        return {}
    try:
        with open(os.path.realpath(claude), "rb") as fh:
            blob = fh.read().decode("latin-1")
    except OSError:
        return {}
    found = {}
    for match in re.finditer(r'\{id:"(claude-[a-z0-9.\-]+)",family:"', blob):
        segment = blob[match.start() : match.start() + 1200]
        window = re.search(r"context:\{[^}]*?window:([0-9e.+]+)", segment)
        if window:
            found[match.group(1)] = int(float(window.group(1)))
    return found


def model_windows():
    cached = read_json(WINDOW_CACHE) or {}
    # Наблюдения из statusLine (hooks/statusline.py) переживают пересборку таблицы: они точнее
    # выскребленного, потому что их назвала сама модель, которая только что ответила, и
    # добываются они дорого — только когда пользователь реально запустил эту модель в терминале.
    observed = cached.get("observed") or {}
    claude = find_claude()
    version = os.path.realpath(claude) if claude else ""
    if cached.get("version") == version and cached.get("models"):
        return cached["models"]
    # Таблица собирается на машине пользователя из его же установленного Claude Code.
    # Захардкоженного списка моделей здесь намеренно нет: он и устаревает с каждым
    # релизом, и не наше дело его публиковать. Пробелы закрывает правило ниже —
    # «наблюдение сильнее таблицы»: токенов больше окна, значит окно на самом деле больше.
    models = {**scrape_model_windows(), **observed}
    write_json(WINDOW_CACHE, {"version": version, "models": models, "observed": observed})
    return models


FAMILIES = ("opus", "sonnet", "haiku", "fable", "mythos")


def family_of(model_id):
    return next((part for part in model_id.split("-") if part in FAMILIES), "")


def window_for(model_id, windows):
    """Размер окна и признак «знаем точно». Логика повторяет hooks/update.js — держать вместе.

    Таблица неполна не по недосмотру: транскрипт пишет имя обслужившей модели, а его в
    локальном реестре может не быть вовсе. Замер на Claude Code 2.1.205 — реестр знает
    claude-opus-4-8 и алиас opus на него, транскрипт говорит claude-opus-5, и такого имени
    в бинаре нет ни одного. Падение на дефолт 200k давало 77% там, где честные 15%, поэтому
    незнакомое имя берёт самое широкое окно своей же семьи: внутри семьи окно от поколения
    к поколению не сужалось ни разу. Это всё ещё догадка — отсюда второе значение.
    """
    mid = (model_id or "").lower()
    if "[1m]" in mid:
        return 1_000_000, True
    base = re.sub(r"-\d{8}$", "", mid)
    if base in windows:
        return windows[base], True
    family = family_of(base)
    kin = [w for name, w in windows.items() if family_of(name) == family]
    if family and kin:
        return max(kin), False
    return DEFAULT_WINDOW, False


def tail_lines(path, nbytes=2_000_000):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        fh.seek(max(0, size - nbytes))
        chunk = fh.read()
    if size > nbytes:
        chunk = chunk.split(b"\n", 1)[-1]
    return chunk.split(b"\n")


def usable_assistant_record(record):
    if record.get("type") != "assistant" or record.get("isSidechain"):
        return False
    message = record.get("message") or {}
    if message.get("model") == "<synthetic>":
        return False
    blocks = message.get("content") or []
    if blocks and isinstance(blocks[0], dict):
        if blocks[0].get("text") in SKIP_TEXTS:
            return False
    return "input_tokens" in (message.get("usage") or {})


def context_of(transcript, windows):
    """Формула повторяет ту, что Claude Code отдаёт в statusLine.

    used% = clamp(round((input + cache_creation + cache_read) / window * 100), 0, 100).
    output_tokens в знаменатель НЕ входит. Сверено с живым payload: 55455 токенов → 28%.
    """
    try:
        lines = tail_lines(transcript)
    except OSError:
        return None
    for raw in reversed(lines):
        if b'"usage"' not in raw:
            continue
        record = read_json_line(raw)
        if not record or not usable_assistant_record(record):
            continue
        message = record["message"]
        usage = message["usage"]
        total = (
            usage["input_tokens"]
            + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0)
        )
        window, exact = window_for(message.get("model", ""), windows)
        assumed = not exact
        if total > window:
            # Наблюдение противоречит таблице: столько токенов в окно 200k физически
            # не влезло бы. Значит сессия идёт в миллионном окне, а таблица отстала.
            # Честнее показать пересчёт с пометкой, чем упереться в фальшивые 100%.
            window = 1_000_000
            assumed = True
        return {
            "pct": max(0, min(100, round(total / window * 100))),
            "tokens": total,
            "window": window,
            "model": message.get("model"),
            "assumed": assumed,
        }
    return None


def live_sessions():
    """Сессии ведут Node-хуки; здесь их файлы только читаются — для текстового отчёта.

    Заполненность контекста хук считает сам на каждом событии. У сессии, открытой ещё
    до установки, её может не быть — такую добираем по транскрипту.

    Мёртвые записи здесь НЕ удаляются, хотя раньше удалялись: чистка теперь одна, в
    приложении (оно же следит за живостью по pid). Два уборщика на один каталог
    отнимали бы файл друг у друга посреди чтения.
    """
    windows = None
    out = []
    for path in glob.glob(os.path.join(SESSIONS, "*.json")):
        info = read_json(path)
        if not info:
            continue
        pid = info.get("pid")
        try:
            os.kill(int(pid), 0)
        except (OSError, ValueError, TypeError):
            continue
        entry = {
            "id": (info.get("sessionId") or "")[:8],
            "project": info.get("project") or "",
            "entrypoint": info.get("entrypoint") or "",
            "ts": info.get("ts") or 0,
        }
        for key in ("pct", "tokens", "window", "model"):
            if info.get(key) is not None:
                entry[key] = info[key]
        transcript = info.get("transcript")
        if entry.get("pct") is None and transcript and os.path.exists(transcript):
            if windows is None:
                windows = model_windows()
            entry.update(context_of(transcript, windows) or {})
        out.append(entry)
    return sorted(out, key=lambda s: s.get("ts") or 0, reverse=True)


# ──────────────────────────────────────────────────────────── сборка состояния

def refresh():
    servers, error = run_health_check()
    previous = load_state() or {}

    # Проверка сорвалась (сеть, гонка двух запусков, занятый бинарь) — НЕ затирать
    # последнюю удачную картину пустотой: индикатор обнулялся бы на ровном месте.
    # Показываем прошлые данные и честно помечаем их устаревшими.
    if error and not servers and previous.get("servers"):
        stale = dict(previous)
        stale["error"] = error
        stale["stale_since"] = previous.get("checked_at", 0)
        write_json(STATE, stale)
        return stale

    local = set((read_json(CONFIG) or {}).get("mcpServers") or {})
    for entry in servers:
        entry["source"] = classify(entry["name"], local)

    # Строго после health-check: он переписывает stderr-логи, из которых берутся числа.
    attach_tools(servers)

    # Таблицу размеров окон держим свежей здесь, хотя сама она нужна не нам, а Node-хуку:
    # выскребается она из бинаря Claude Code (226 МБ) и в хуке, который срабатывает на
    # каждый вызов инструмента, такому месту не бывать. Кеш привязан к версии бинаря,
    # так что на деле это работа один раз за обновление Claude Code.
    model_windows()

    off = denied_servers()
    rules = denied_tools()
    known = {s["name"] for s in servers}
    # Выключенный сервер исчезает из вывода целиком, вместе со счётчиком инструментов.
    # Достаём его из прошлого состояния: иначе не видно ни как включить обратно,
    # ни сколько инструментов он вернёт в контекст.
    remembered = {s["name"]: s for s in previous.get("servers", [])}
    for name in off:
        if name in known:
            continue
        was = remembered.get(name, {})
        servers.append({
            "name": name, "target": was.get("target", ""), "status": t("server.off"),
            "state": OFF, "source": classify(name, local),
            "tools": was.get("tools"), "toolNames": was.get("toolNames", []),
        })
    for entry in servers:
        entry["disabled"] = entry["name"] in off
        if entry["disabled"]:
            entry["state"] = OFF
        entry["deniedTools"] = [
            t for t in entry.get("toolNames", []) if tool_denied(rules, entry["name"], t)
        ]

    # Кеш «нужна авторизация» не чистится сам: сервер мог с тех пор подняться,
    # и тогда он попадал в список дважды — и подключённым, и ждущим.
    listed = {s["name"] for s in servers}
    waiting = sorted(n for n in (read_json(NEEDS_AUTH) or {}) if n not in listed)

    data = {
        "checked_at": time.time(),
        "servers": servers,
        "auth": waiting,
        "sessions": live_sessions(),
        "limits": read_json(LIMITS) or {},
        "denyRules": rules,
    }
    if error:
        data["error"] = error
    write_json(STATE, data)
    return data


def load_state():
    return read_json(STATE)


def spawn_refresh():
    import subprocess

    try:
        if os.path.exists(LOCK) and time.time() - os.path.getmtime(LOCK) < LOCK_TTL:
            return
        os.makedirs(ROOT, exist_ok=True)
        with open(LOCK, "w") as fh:
            fh.write(str(os.getpid()))
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "refresh"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception:
        pass


# ──────────────────────────────────────────────────────────── вывод

def statusline_segment():
    """Сегмент для statusLine. Никогда не блокирует и никогда не бросает."""
    try:
        data = load_state()
        if not data or time.time() - data.get("checked_at", 0) > TTL:
            spawn_refresh()
        if not data:
            return ""
        servers = [s for s in data.get("servers", []) if not s.get("disabled")]
        live = sum(1 for s in servers if s["state"] == OK)
        broken = [s["name"].replace("claude.ai ", "") for s in servers if s["state"] != OK]
        pending = len(data.get("auth", []))
        if data.get("error") and not servers:
            return "\x1b[31m🔌 MCP ?\x1b[0m"
        color = "\x1b[31m" if broken else "\x1b[32m"
        text = f"{color}🔌 MCP {live}/{len(servers)}"
        if broken:
            text += " ✗ " + ",".join(broken[:2])
        text += "\x1b[0m"
        if pending:
            text += f" \x1b[33m⚠{pending}\x1b[0m"
        return text
    except Exception:
        return ""


GLYPH = {OK: "●", FAILED: "✗", PENDING: "⏸", AUTH: "◌", OFF: "○"}
COLOR = {OK: "32", FAILED: "31", PENDING: "33", AUTH: "33", OFF: "2"}
GROUPS = ["user", "claude.ai", "plugin", "project"]


def report(force=False):
    data = load_state()
    if force or not data or time.time() - data.get("checked_at", 0) > TTL:
        data = refresh()

    tty = sys.stdout.isatty()
    paint = (lambda text, code: f"\x1b[{code}m{text}\x1b[0m") if tty else (lambda text, _: text)

    servers = data.get("servers", [])
    pending = data.get("auth", [])
    width = max([len(s["name"]) for s in servers] + [len(a) for a in pending] + [10])
    out = []

    for key in GROUPS:
        group = sorted(
            (s for s in servers if s.get("source") == key), key=lambda x: x["name"]
        )
        if not group:
            continue
        out.append(paint(t("group." + key), "1"))
        for server in group:
            glyph = paint(GLYPH[server["state"]], COLOR[server["state"]])
            count = server.get("tools")
            tools = (f"{count} {plural_tools(count)}"
                     if count is not None else t("tools.none")).rjust(10)
            muted = len(server.get("deniedTools") or [])
            note = ""
            if server["state"] == OFF:
                note = "   " + t("server.off")
            elif server["state"] != OK:
                note = f"   {server['status']}"
            elif muted:
                note = "   " + t("server.muted", n=muted)
            out.append(
                f"  {glyph} {server['name']:<{width}}  {paint(tools, '2')}{note}".rstrip())
        out.append("")

    if pending:
        out.append(paint(t("head.auth"), "1"))
        for name in pending:
            mark = paint(GLYPH[AUTH], COLOR[AUTH])
            out.append(f"  {mark} {name:<{width}}   {t('auth.hint')}")
        out.append("")

    measured = [s for s in data.get("sessions", []) if s.get("pct") is not None]
    if measured:
        out.append(paint(t("head.sessions"), "1"))
        for session in measured:
            label = session["project"] or session["id"]
            spent = t("session.spent",
                      used=f"{session['tokens']:,}".replace(",", " "),
                      total=f"{session['window']:,}".replace(",", " "))
            context = t("session.context", pct=session["pct"])
            out.append(f"  {label:<{width}}  {context}  ({spent})")
        out.append("")

    limits = data.get("limits") or {}
    if limits.get("five_hour") or limits.get("seven_day"):
        out.append(paint(t("head.limits"), "1"))
        for key, label in (("five_hour", t("limits.five")), ("seven_day", t("limits.seven"))):
            block = limits.get(key)
            if block:
                out.append(f"  {label:<{width}}  {block['used_percentage']:>3}%")
        age = int(time.time() - (limits.get("ts") or 0)) // 60
        out.append(paint("  " + t("limits.age", n=age, src=limits.get("source", "?")), "2"))
        out.append("")

    if data.get("error"):
        out.append(paint(t("error.check", e=data["error"]), "31"))
        out.append("")

    visible = [s for s in servers if not s.get("disabled")]
    live = sum(1 for s in visible if s["state"] == OK)
    tools = sum(s.get("tools") or 0 for s in visible)
    summary = t("summary", live=live, total=len(visible),
                tools=tools, word=plural_tools(tools))
    disabled = len(servers) - len(visible)
    if disabled:
        summary += t("summary.off", n=disabled)
    if pending:
        summary += t("summary.auth", n=len(pending))
    out.append(paint(summary, "32" if live == len(visible) else "31"))
    out.append(paint(t("checked", n=int(time.time() - data.get("checked_at", 0))), "2"))
    return "\n".join(out)


def doctor():
    claude = find_claude()
    checks = [
        (t("doc.binary"), claude or t("doc.missing")),
        (t("doc.settings"), SETTINGS if os.path.exists(SETTINGS) else t("doc.nofile")),
        (t("doc.state"), STATE if os.path.exists(STATE) else t("doc.nostate")),
        (t("doc.sessions"), str(len(glob.glob(os.path.join(SESSIONS, "*.json"))))),
        (t("doc.off"), str(len(denied_servers()))),
        (t("doc.rules"), str(len(denied_tools()))),
        (t("doc.windows"), str(len(model_windows()))),
        (t("lang"), LANG),
    ]
    width = max(len(name) for name, _ in checks) + 2
    return "\n".join(f"{name:<{width}} {value}" for name, value in checks)


# ──────────────────────────────────────────────────────────── точка входа

def main(argv):
    command = argv[0] if argv else "report"
    rest = argv[1:]

    if command == "refresh":
        refresh()
    elif command == "line":
        sys.stdout.write(statusline_segment())
    elif command == "report":
        print(report(force="--force" in rest))
    elif command == "doctor":
        print(doctor())
    elif command == "limits":
        print(fetch_limits())
    elif command == "statusline":
        if "--install" in rest:
            print(statusline_install())
        elif "--uninstall" in rest:
            print(statusline_uninstall())
        else:
            current, ours = statusline_state()
            print(("перехват включён" if ours else "перехват выключен")
                  + f"\nтекущая команда: {current or '(statusLine не настроен)'}")
    elif command in ("toggle-server", "toggle-tool"):
        target = rest[0]
        turn_off = "--off" in rest
        changed = (toggle_server if command == "toggle-server" else toggle_tool)(target, turn_off)
        # Меню ждёт мгновенного отклика, поэтому по умолчанию только пересчёт признаков.
        # Полная проверка — по явному --refresh.
        refresh() if "--refresh" in rest else patch_state_after_toggle()
        print("changed" if changed else "unchanged")
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
