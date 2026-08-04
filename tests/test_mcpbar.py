#!/usr/bin/env python3
"""Тесты разбора и переключателей.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
Каждый случай здесь — реальная ошибка, на которую наступили при разработке.
"""

import glob
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mcpbar  # noqa: E402


class ParseListLine(unittest.TestCase):
    def test_обычный_сервер(self):
        got = mcpbar.parse_list_line("wiki: npx -y @modelcontextprotocol/server-wiki - ✔ Connected")
        self.assertEqual(got["name"], "wiki")
        self.assertEqual(got["state"], mcpbar.OK)

    def test_имя_с_двоеточиями_не_режется(self):
        """plugin:figma:figma по первому двоеточию превращался в «plugin»."""
        got = mcpbar.parse_list_line("plugin:figma:figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected")
        self.assertEqual(got["name"], "plugin:figma:figma")

    def test_имя_с_пробелом(self):
        got = mcpbar.parse_list_line("claude.ai Google Calendar: https://x/mcp/v1 - ✔ Connected")
        self.assertEqual(got["name"], "claude.ai Google Calendar")

    def test_команда_с_дефисами_не_ломает_статус(self):
        """У одного сервера команда запуска длиной 1400 символов и полна « - »."""
        command = "node -e const a=1-2; const b=3 - 4; process.exit(0)"
        got = mcpbar.parse_list_line(f"weird: {command} - ✘ Failed to connect")
        self.assertEqual(got["name"], "weird")
        self.assertEqual(got["state"], mcpbar.FAILED)
        self.assertEqual(got["status"], "✘ Failed to connect")

    def test_ожидает_одобрения(self):
        got = mcpbar.parse_list_line("proj: npx thing - ⏸ Pending approval")
        self.assertEqual(got["state"], mcpbar.PENDING)

    def test_мусорные_строки_отбрасываются(self):
        self.assertIsNone(mcpbar.parse_list_line("Checking MCP server health…"))
        self.assertIsNone(mcpbar.parse_list_line(""))


class Classify(unittest.TestCase):
    def test_разделение_по_источникам(self):
        local = {"wiki"}
        self.assertEqual(mcpbar.classify("wiki", local), "user")
        self.assertEqual(mcpbar.classify("claude.ai Figma", local), "claude.ai")
        self.assertEqual(mcpbar.classify("plugin:figma:figma", local), "plugin")
        self.assertEqual(mcpbar.classify("someproj", local), "project")

    def test_короткое_имя(self):
        self.assertEqual(mcpbar.short_name("claude.ai Figma"), "Figma")
        self.assertEqual(mcpbar.short_name("plugin:figma:figma"), "figma")
        self.assertEqual(mcpbar.short_name("wiki"), "wiki")


class ToolDenied(unittest.TestCase):
    def test_точное_имя(self):
        self.assertTrue(mcpbar.tool_denied(["mcp__wiki__DeletePage"], "wiki", "DeletePage"))
        self.assertFalse(mcpbar.tool_denied(["mcp__wiki__DeletePage"], "wiki", "GetPage"))

    def test_правило_на_весь_сервер(self):
        self.assertTrue(mcpbar.tool_denied(["mcp__wiki"], "wiki", "GetPage"))

    def test_глоб(self):
        rules = ["mcp__wiki__Delete*"]
        self.assertTrue(mcpbar.tool_denied(rules, "wiki", "DeleteGrid"))
        self.assertFalse(mcpbar.tool_denied(rules, "wiki", "CreateGrid"))

    def test_чужой_сервер_не_задет(self):
        self.assertFalse(mcpbar.tool_denied(["mcp__wiki"], "yt", "GetPage"))


class Language(unittest.TestCase):
    def setUp(self):
        self._lang = mcpbar.LANG

    def tearDown(self):
        mcpbar.LANG = self._lang

    def test_русские_окончания(self):
        mcpbar.LANG = "ru"
        cases = {1: "инструмент", 2: "инструмента", 5: "инструментов",
                 11: "инструментов", 21: "инструмент", 104: "инструмента",
                 301: "инструмент", 0: "инструментов"}
        for number, expected in cases.items():
            with self.subTest(number=number):
                self.assertEqual(mcpbar.plural_tools(number), expected)

    def test_английские_окончания(self):
        mcpbar.LANG = "en"
        self.assertEqual(mcpbar.plural_tools(1), "tool")
        for number in (0, 2, 5, 11, 301):
            self.assertEqual(mcpbar.plural_tools(number), "tools")

    def test_переключение_языка(self):
        mcpbar.LANG = "en"
        self.assertEqual(mcpbar.t("server.off"), "disabled")
        mcpbar.LANG = "ru"
        self.assertEqual(mcpbar.t("server.off"), "выключен")

    def test_подстановка_значений(self):
        mcpbar.LANG = "ru"
        self.assertEqual(mcpbar.t("server.muted", n=3), "(3 выключено)")

    def test_все_ключи_переведены_на_оба_языка(self):
        for key, value in mcpbar.STRINGS.items():
            with self.subTest(key=key):
                self.assertEqual(len(value), 2, f"{key}: нужны обе формы")
                self.assertTrue(all(v.strip() for v in value), f"{key}: пустой перевод")

    def test_принудительный_язык_из_окружения(self):
        real = os.environ.get("CONTROL_BAR_LANG")
        try:
            os.environ["CONTROL_BAR_LANG"] = "ru"
            self.assertEqual(mcpbar.detect_lang(), "ru")
            os.environ["CONTROL_BAR_LANG"] = "en"
            self.assertEqual(mcpbar.detect_lang(), "en")
        finally:
            if real is None:
                os.environ.pop("CONTROL_BAR_LANG", None)
            else:
                os.environ["CONTROL_BAR_LANG"] = real


class PatchStateAfterToggle(unittest.TestCase):
    """Переключатель обязан отвечать мгновенно, значит правит состояние, а не пересобирает."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self._dir.name, "settings.json")
        self.state = os.path.join(self._dir.name, "state.json")
        with open(self.settings, "w") as fh:
            json.dump({}, fh)
        with open(self.state, "w") as fh:
            json.dump({"checked_at": 1, "servers": [
                {"name": "wiki", "state": "ok", "status": "✔ Connected", "source": "user",
                 "tools": 31, "toolNames": ["GetPage", "DeletePage"], "toolDocs": {}},
            ]}, fh)
        self._saved = (mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT)
        mcpbar.SETTINGS, mcpbar.STATE = self.settings, self.state
        # ROOT — тоже подмена: settings_lock() кладёт файл блокировки в ROOT, и без этого
        # тест писал в настоящий ~/.claude/control-bar.
        mcpbar.ROOT = os.path.join(self._dir.name, "control-bar")

    def tearDown(self):
        mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT = self._saved
        self._dir.cleanup()

    def read_state(self):
        with open(self.state) as fh:
            return json.load(fh)

    def test_выключенный_сервер_помечается(self):
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.patch_state_after_toggle()
        wiki = self.read_state()["servers"][0]
        self.assertTrue(wiki["disabled"])
        self.assertEqual(wiki["state"], "off")

    def test_счётчик_инструментов_не_теряется(self):
        """Иначе не видно, сколько контекста вернёт обратное включение."""
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.patch_state_after_toggle()
        self.assertEqual(self.read_state()["servers"][0]["tools"], 31)

    def test_включение_честно_говорит_что_нужна_новая_сессия(self):
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.patch_state_after_toggle()
        mcpbar.toggle_server("wiki", turn_off=False)
        mcpbar.patch_state_after_toggle()
        wiki = self.read_state()["servers"][0]
        self.assertFalse(wiki["disabled"])
        self.assertEqual(wiki["state"], "pending")

    def test_погашенный_инструмент_виден_в_состоянии(self):
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True)
        mcpbar.patch_state_after_toggle()
        self.assertEqual(self.read_state()["servers"][0]["deniedTools"], ["DeletePage"])

    def test_неизвестный_выключенный_сервер_появляется_строкой(self):
        """Иначе его нечем было бы включить обратно: из списка он исчезает целиком."""
        mcpbar.toggle_server("призрак", turn_off=True)
        mcpbar.patch_state_after_toggle()
        names = [s["name"] for s in self.read_state()["servers"]]
        self.assertIn("призрак", names)


class ContextWindow(unittest.TestCase):
    def test_подбор_окна(self):
        windows = {"claude-opus-5": 1_000_000, "claude-sonnet-4-5": 200_000}
        self.assertEqual(mcpbar.window_for("claude-opus-5", windows), (1_000_000, True))
        self.assertEqual(mcpbar.window_for("claude-sonnet-4-5-20260101", windows), (200_000, True))
        self.assertEqual(
            mcpbar.window_for("что-то-незнакомое", windows),
            (mcpbar.DEFAULT_WINDOW, False))

    def test_суффикс_1m(self):
        self.assertEqual(mcpbar.window_for("claude-sonnet-4-5[1m]", {}), (1_000_000, True))

    def test_модель_которой_нет_в_реестре_берёт_окно_своей_семьи(self):
        """Живой случай: транскрипт пишет claude-opus-5, а в бинаре есть только claude-opus-4-8.

        На дефолте 200k сессия со 154 тысячами токенов показывала 77% вместо 15%.
        """
        windows = {
            "claude-opus-4-5": 200_000, "claude-opus-4-8": 1_000_000,
            "claude-haiku-4-5": 200_000,
        }
        self.assertEqual(mcpbar.window_for("claude-opus-5", windows), (1_000_000, False))
        self.assertEqual(mcpbar.window_for("claude-haiku-9", windows), (200_000, False))

    def test_чужая_семья_окно_не_одалживает(self):
        """Иначе haiku унаследовал бы миллион от opus и показывал бы 3% вместо 100%."""
        windows = {"claude-opus-4-8": 1_000_000}
        self.assertEqual(
            mcpbar.window_for("claude-haiku-7", windows),
            (mcpbar.DEFAULT_WINDOW, False))

    def test_служебные_записи_пропускаются(self):
        """Без этого фильтра индикатор показывал 0% на прерванном ходе."""
        synthetic = {"type": "assistant", "message": {
            "model": "<synthetic>", "usage": {"input_tokens": 10}}}
        interrupted = {"type": "assistant", "message": {
            "model": "claude-opus-5", "usage": {"input_tokens": 10},
            "content": [{"text": "[Request interrupted by user]"}]}}
        sidechain = {"type": "assistant", "isSidechain": True, "message": {
            "model": "claude-opus-5", "usage": {"input_tokens": 10}}}
        good = {"type": "assistant", "message": {
            "model": "claude-opus-5", "usage": {"input_tokens": 10},
            "content": [{"text": "нормальный ответ"}]}}
        self.assertFalse(mcpbar.usable_assistant_record(synthetic))
        self.assertFalse(mcpbar.usable_assistant_record(interrupted))
        self.assertFalse(mcpbar.usable_assistant_record(sidechain))
        self.assertTrue(mcpbar.usable_assistant_record(good))

    def test_таблица_собирается_локально_и_не_зашита_в_код(self):
        """Список моделей не наш, чтобы его публиковать: он читается из установленного CLI."""
        self.assertFalse(hasattr(mcpbar, "FALLBACK_WINDOWS"))
        self.assertIsInstance(mcpbar.model_windows(), dict)

    def test_неизвестная_модель_получает_умолчание(self):
        self.assertEqual(
            mcpbar.window_for("совсем-новая-модель", {}), (mcpbar.DEFAULT_WINDOW, False))

    def test_наблюдение_перебивает_устаревшую_таблицу(self):
        """413 тысяч токенов в окно 200k не влезли бы — значит таблица отстала."""
        transcript = os.path.join(self.tmp, "big.jsonl")
        record = {"type": "assistant", "message": {
            "model": "неизвестная-модель",
            "content": [{"text": "ok"}],
            "usage": {"input_tokens": 413862, "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": 0}}}
        with open(transcript, "w") as fh:
            fh.write(json.dumps(record) + "\n")
        got = mcpbar.context_of(transcript, {})
        self.assertTrue(got["assumed"])
        self.assertEqual(got["window"], 1_000_000)
        self.assertEqual(got["pct"], 41)

    def test_процент_считается_как_в_cli(self):
        """output_tokens в знаменатель не входит — сверено с живым payload statusLine."""
        transcript = os.path.join(self.tmp, "t.jsonl")
        record = {"type": "assistant", "message": {
            "model": "claude-sonnet-4-5",
            "content": [{"text": "ok"}],
            "usage": {"input_tokens": 55455, "cache_creation_input_tokens": 0,
                      "cache_read_input_tokens": 0, "output_tokens": 9999}}}
        with open(transcript, "w") as fh:
            fh.write(json.dumps(record) + "\n")
        got = mcpbar.context_of(transcript, {"claude-sonnet-4-5": 200_000})
        self.assertEqual(got["pct"], 28)
        self.assertEqual(got["tokens"], 55455)

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.tmp = self._dir.name

    def tearDown(self):
        self._dir.cleanup()


class Toggles(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self._dir.name, "settings.json")
        with open(self.settings, "w") as fh:
            json.dump({"alwaysThinkingEnabled": True}, fh)
        self._real = mcpbar.SETTINGS
        mcpbar.SETTINGS = self.settings

    def tearDown(self):
        mcpbar.SETTINGS = self._real
        self._dir.cleanup()

    def read(self):
        with open(self.settings) as fh:
            return json.load(fh)

    def test_сервер_выключается_объектом_а_не_строкой(self):
        """Плоскую строку Claude Code молча игнорирует — проверено на живом бинаре."""
        mcpbar.toggle_server("wiki", turn_off=True)
        self.assertEqual(self.read()["deniedMcpServers"], [{"serverName": "wiki"}])

    def test_цикл_не_оставляет_следов(self):
        before = self.read()
        mcpbar.toggle_server("wiki", turn_off=True)
        mcpbar.toggle_server("wiki", turn_off=False)
        self.assertEqual(self.read(), before)

    def test_инструмент_не_оставляет_пустой_ключ(self):
        before = self.read()
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True)
        self.assertEqual(self.read()["permissions"]["deny"], ["mcp__wiki__DeletePage"])
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=False)
        self.assertEqual(self.read(), before)

    def test_повторное_выключение_ничего_не_меняет(self):
        self.assertTrue(mcpbar.toggle_server("wiki", turn_off=True))
        self.assertFalse(mcpbar.toggle_server("wiki", turn_off=True))

    def test_чужие_настройки_сохраняются(self):
        mcpbar.toggle_server("wiki", turn_off=True)
        self.assertTrue(self.read()["alwaysThinkingEnabled"])

    def test_чужие_правила_запрета_сохраняются(self):
        with open(self.settings, "w") as fh:
            json.dump({"permissions": {"deny": ["WebSearch"], "allow": ["Bash"]}}, fh)
        mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True)
        after = self.read()["permissions"]
        self.assertIn("WebSearch", after["deny"])
        self.assertEqual(after["allow"], ["Bash"])


class ConcurrentToggles(unittest.TestCase):
    """Гонка настоящими процессами, не имитацией: каждый клик в приложении — отдельный
    процесс на глобальной очереди. До файловой блокировки два одновременных переключения
    теряли одно из двух изменений в 43 прогонах из 50."""

    def test_параллельные_переключения_не_теряют_друг_друга(self):
        import subprocess

        home = tempfile.mkdtemp()
        os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
        settings = os.path.join(home, ".claude", "settings.json")
        with open(settings, "w") as fh:
            json.dump({"hooks": {"keep": "me"}}, fh)
        script = ("import sys; sys.path.insert(0, %r); import mcpbar; "
                  "mcpbar.toggle_server(sys.argv[1], turn_off=True)"
                  % os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
        procs = [
            subprocess.Popen([sys.executable, "-c", script, f"srv{i}"],
                             env={**os.environ, "HOME": home})
            for i in range(12)
        ]
        for p in procs:
            self.assertEqual(p.wait(timeout=60), 0)
        with open(settings) as fh:
            after = json.load(fh)
        denied = {d["serverName"] for d in after.get("deniedMcpServers", [])}
        self.assertEqual(denied, {f"srv{i}" for i in range(12)})
        self.assertEqual(after.get("hooks"), {"keep": "me"})

    def test_права_файла_переживают_переключатель(self):
        import subprocess

        home = tempfile.mkdtemp()
        os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
        settings = os.path.join(home, ".claude", "settings.json")
        with open(settings, "w") as fh:
            json.dump({}, fh)
        os.chmod(settings, 0o600)
        script = ("import sys; sys.path.insert(0, %r); import mcpbar; "
                  "mcpbar.toggle_server('x', turn_off=True)"
                  % os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
        subprocess.run([sys.executable, "-c", script], env={**os.environ, "HOME": home}, check=True)
        # Временный файл рождается с umask 0644; без явного chmod он подменял собой
        # файл 0600 — и env-значения MCP-серверов становились читаемы всем локальным.
        self.assertEqual(os.stat(settings).st_mode & 0o777, 0o600)


class StatusLineObject(unittest.TestCase):
    """Установка перехвата обязана пережить ВСЕ поля statusLine, не только command:
    padding, refreshInterval и hideVimModeIndicator — поддерживаемые настройки Claude Code,
    и первая версия install молча их съедала, а uninstall не возвращал."""

    ORIGINAL = {
        "type": "command", "command": "printf old",
        "padding": 2, "refreshInterval": 5, "hideVimModeIndicator": True,
    }

    def setUp(self):
        self.home = tempfile.mkdtemp()
        claude = os.path.join(self.home, ".claude")
        os.makedirs(os.path.join(claude, "control-bar"), exist_ok=True)
        self.settings = os.path.join(claude, "settings.json")
        with open(self.settings, "w") as fh:
            json.dump({"statusLine": dict(self.ORIGINAL)}, fh)
        self.patched = {
            "SETTINGS": self.settings,
            "ROOT": os.path.join(claude, "control-bar"),
            "STATUSLINE_INNER": os.path.join(claude, "control-bar", "statusline-inner-command"),
            "STATUSLINE_SAVED": os.path.join(claude, "control-bar", "statusline-saved.json"),
        }
        self.saved = {k: getattr(mcpbar, k) for k in self.patched}
        for k, v in self.patched.items():
            setattr(mcpbar, k, v)
        # Обёртка ищется рядом со скриптом; в тестовом прогоне она есть в репозитории.

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(mcpbar, k, v)

    def read(self):
        with open(self.settings) as fh:
            return json.load(fh)

    def test_установка_сохраняет_дополнительные_поля_живыми(self):
        mcpbar.statusline_install()
        after = self.read()["statusLine"]
        self.assertIn("statusline.sh", after["command"])
        self.assertEqual(after["padding"], 2)
        self.assertEqual(after["refreshInterval"], 5)
        self.assertTrue(after["hideVimModeIndicator"])

    def test_откат_возвращает_объект_целиком(self):
        mcpbar.statusline_install()
        mcpbar.statusline_uninstall()
        self.assertEqual(self.read()["statusLine"], self.ORIGINAL)

    def test_откат_без_исходного_statusline_убирает_ключ(self):
        with open(self.settings, "w") as fh:
            json.dump({}, fh)
        mcpbar.statusline_install()
        mcpbar.statusline_uninstall()
        self.assertNotIn("statusLine", self.read())


class ProjectServers(unittest.TestCase):
    """Серверы local- и project-scope видны только из каталога проекта, поэтому общий
    `claude mcp list` (его cwd закреплён на корне) их не показывает — они добираются
    из конфигурации по каталогам живых сессий."""

    def test_каталог_с_серверами_обоих_scope_попадает_в_список(self):
        cwd = tempfile.mkdtemp()
        with open(os.path.join(cwd, ".mcp.json"), "w") as fh:
            json.dump({"mcpServers": {"repo-tool": {"command": "./run.sh"}}}, fh)
        self.assertEqual(mcpbar.project_cwds([cwd], {}), [cwd])

        other = tempfile.mkdtemp()
        config = {"projects": {other: {"mcpServers": {"mine": {"command": "echo"}}}}}
        self.assertEqual(mcpbar.project_cwds([other], config), [other])

    def test_проект_без_конфигурации_даёт_пусто(self):
        """Пустой список значит «не звать сюда claude mcp list» — а это полминуты."""
        self.assertEqual(mcpbar.project_cwds([tempfile.mkdtemp()], {}), [])

    def test_команда_из_mcp_json_не_запускается(self):
        """Главное правило: .mcp.json лежит в репозитории, который мог написать кто угодно.

        Раньше эта конфигурация читалась и её команда уходила в Popen — достаточно было
        склонировать чужой репозиторий и открыть его. Теперь скрипт только смотрит, есть ли
        в каталоге серверы, и дальше спрашивает `claude mcp list`: что из .mcp.json поднимать,
        а что держать в «⏸ Pending approval», решает Claude Code, у которого одобрение и есть.
        """
        cwd = tempfile.mkdtemp()
        marker = os.path.join(cwd, "executed")
        with open(os.path.join(cwd, ".mcp.json"), "w") as fh:
            json.dump({"mcpServers": {
                "evil": {"command": "/usr/bin/touch", "args": [marker]},
            }}, fh)
        self.assertEqual(mcpbar.project_cwds([cwd], {}), [cwd])
        self.assertFalse(os.path.exists(marker), "команда из .mcp.json была выполнена")

    def test_ожидающий_одобрения_сервер_разбирается_как_pending(self):
        """Строка, которой Claude Code отвечает про неодобренный сервер, — наш признак."""
        got = mcpbar.parse_list_line("repo-tool: npx thing - ⏸ Pending approval")
        self.assertEqual(got["state"], mcpbar.PENDING)


class SettingsSafety(unittest.TestCase):
    """settings.json принадлежит человеку: в нём его правила и env MCP-серверов с токенами.

    Каждый случай здесь — способ, которым переключатель мог этот файл испортить.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.settings = os.path.join(self._dir.name, "settings.json")
        self._saved = (mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT)
        mcpbar.SETTINGS = self.settings
        mcpbar.STATE = os.path.join(self._dir.name, "state.json")
        # ROOT тоже: без него settings_lock() лезет за файлом блокировки в настоящий
        # ~/.claude/control-bar — тест перестаёт быть герметичным и падает в песочнице.
        mcpbar.ROOT = os.path.join(self._dir.name, "control-bar")

    def tearDown(self):
        mcpbar.SETTINGS, mcpbar.STATE, mcpbar.ROOT = self._saved
        self._dir.cleanup()

    def write(self, text, mode=0o600):
        with open(self.settings, "w") as fh:
            fh.write(text)
        os.chmod(self.settings, mode)

    def read(self):
        with open(self.settings) as fh:
            return fh.read()

    def backups(self):
        return sorted(glob.glob(f"{self.settings}.bak-*"))

    def test_бэкап_не_шире_исходника(self):
        """0600 у настроек — не украшение: в них лежат env MCP-серверов с токенами.

        Резервная копия создавалась заново, копировать режим было неоткуда, и при обычном
        umask 022 она рождалась 0644 — секреты становились читаемы всем на машине.
        """
        self.write(json.dumps({"env": {"TOKEN": "s3cr3t"}}), mode=0o600)
        path = mcpbar.backup_settings()
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_битый_json_не_затирается_переключателем(self):
        """Человек редактирует файл руками; между двумя нажатиями он бывает невалиден.

        read_json() глушила любую ошибку и возвращала None, а вызывающий писал `or {}` —
        то есть «файла нет». Один клик заменял все настройки одним правилом deny, и
        резервной копии тоже не оставалось: backup_settings() на нечитаемом файле выходила.
        """
        broken = '{ "permissions": { "deny": ["Bash(rm:*)"] }, "apiKeyHelper": "x"\n'
        self.write(broken)
        self.assertFalse(mcpbar.toggle_server("wiki", turn_off=True))
        self.assertEqual(self.read(), broken)

    def test_битый_json_не_затирается_переключателем_инструмента(self):
        broken = '{ oops\n'
        self.write(broken)
        self.assertFalse(mcpbar.toggle_tool("mcp__wiki__DeletePage", turn_off=True))
        self.assertEqual(self.read(), broken)

    def test_чужая_запись_между_чтением_и_заменой_не_теряется(self):
        """Блокировка держит только процессы панели. Claude Code и редактор её не берут.

        Чужая правка имитируется из backup_settings() — она и правда вызывается между
        чтением настроек и их заменой, так что окно тут настоящее, а не выдуманное.
        """
        self.write(json.dumps({"mine": 1}))
        original = mcpbar.backup_settings

        def someone_else_writes_first():
            result = original()
            with open(self.settings, "w") as fh:
                json.dump({"mine": 1, "theirs": 2}, fh)
            return result

        mcpbar.backup_settings = someone_else_writes_first
        try:
            self.assertFalse(mcpbar.toggle_server("wiki", turn_off=True))
        finally:
            mcpbar.backup_settings = original
        with open(self.settings) as fh:
            self.assertEqual(json.load(fh), {"mine": 1, "theirs": 2})

    def test_symlink_на_dotfiles_остаётся_symlink(self):
        """Настройки часто симлинк в ~/dotfiles. os.replace заменял саму ссылку обычным
        файлом: оригинал в dotfiles оставался старым, а синхронизация тихо умирала."""
        target = os.path.join(self._dir.name, "dotfiles-settings.json")
        with open(target, "w") as fh:
            json.dump({"mine": 1}, fh)
        os.symlink(target, self.settings)
        self.assertTrue(mcpbar.toggle_server("wiki", turn_off=True))
        self.assertTrue(os.path.islink(self.settings), "симлинк заменён обычным файлом")
        with open(target) as fh:
            self.assertIn("deniedMcpServers", json.load(fh))


class ReportGlyphs(unittest.TestCase):
    def test_каждое_состояние_имеет_значок_и_цвет(self):
        """`/mcp-health` печатает GLYPH[state] по жёсткому индексу: состояние без значка
        роняет всю команду KeyError'ом. Первым таким стал unknown у HTTP-сервера проекта."""
        for state in (mcpbar.OK, mcpbar.FAILED, mcpbar.PENDING, mcpbar.AUTH,
                      mcpbar.OFF, mcpbar.UNKNOWN):
            self.assertIn(state, mcpbar.GLYPH)
            self.assertIn(state, mcpbar.COLOR)

    def test_каждое_состояние_из_разбора_печатается(self):
        """Разбор — единственное место, где состояния рождаются; печатать надо все."""
        for line in (
            "a: cmd - ✔ Connected",
            "b: cmd - ✘ Failed to connect",
            "c: cmd - ⏸ Pending approval",
            "d: https://x/mcp (HTTP) - ✔ Connected",
        ):
            got = mcpbar.parse_list_line(line)
            self.assertIsNotNone(got, line)
            self.assertIn(got["state"], mcpbar.GLYPH)


class UsageEndpoint(unittest.TestCase):
    """Разбор ответа api/oauth/usage. Сеть в тестах не участвует — только чистые функции."""

    def test_ответ_эндпоинта_превращается_в_формат_statusline(self):
        record = mcpbar.usage_record({
            "five_hour": {"utilization": 23.4, "resets_at": "2026-08-04T18:00:00+00:00"},
            "seven_day": {"utilization": 79.0, "resets_at": "2026-08-05T12:00:00Z"},
        }, now=1_785_850_000)
        self.assertEqual(record["source"], "oauth")
        # int, не float: Swift читает used_percentage как `as? Int`, дробное значение
        # молча выключает секцию лимитов при здоровом на вид файле.
        self.assertEqual(record["five_hour"]["used_percentage"], 23)
        self.assertEqual(record["seven_day"]["used_percentage"], 79)
        # ISO с таймзоной → epoch, обе нотации зоны.
        self.assertEqual(record["five_hour"]["resets_at"], 1_785_866_400)
        self.assertEqual(record["seven_day"]["resets_at"], 1_785_931_200)

    def test_неизвестные_окна_проходят_как_есть(self):
        record = mcpbar.usage_record({
            "five_hour": {"utilization": 1, "resets_at": None},
            "seven_day_opus": {"utilization": 55, "resets_at": None},
        }, now=1)
        self.assertIn("seven_day_opus", record)

    def test_пустой_ответ_не_рождает_запись(self):
        self.assertIsNone(mcpbar.usage_record({}, now=1))
        self.assertIsNone(mcpbar.usage_record({"error": "x"}, now=1))
        self.assertIsNone(mcpbar.usage_record(None, now=1))

    def test_epoch_в_resets_at_проходит_без_изменений(self):
        # statusLine шлёт epoch — общий разборщик обязан понимать обе формы.
        self.assertEqual(mcpbar.parse_reset(1_785_866_400), 1_785_866_400)
        self.assertIsNone(mcpbar.parse_reset("not-a-date"))
        self.assertIsNone(mcpbar.parse_reset(None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
