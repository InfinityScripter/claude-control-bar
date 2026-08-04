#!/usr/bin/env python3
"""Тесты разбора и переключателей.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
Каждый случай здесь — реальная ошибка, на которую наступили при разработке.
"""

import json
import os
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
        self._settings, self._state = mcpbar.SETTINGS, mcpbar.STATE
        mcpbar.SETTINGS, mcpbar.STATE = self.settings, self.state

    def tearDown(self):
        mcpbar.SETTINGS, mcpbar.STATE = self._settings, self._state
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
