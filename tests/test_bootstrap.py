#!/usr/bin/env python3
"""Plugin bootstrap: определение своих хуков в settings.json.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks"))

import bootstrap  # noqa: E402


def settings_with(commands):
    return {"hooks": {"Stop": [{"hooks": [
        {"type": "command", "command": c} for c in commands
    ]}]}}


class AppHooksPresent(unittest.TestCase):
    """`ROOT in command` — подстрока без границы пути: чужой каталог control-bar-extra и
    команда, всего лишь читающая файл из нашего каталога, считались нашими хуками. Пока такая
    «наша» запись жива, plugin-канал не может забрать lease — и оба канала стреляют вечно."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self._saved = bootstrap.SETTINGS
        bootstrap.SETTINGS = os.path.join(self._dir.name, "settings.json")

    def tearDown(self):
        bootstrap.SETTINGS = self._saved
        self._dir.cleanup()

    def write(self, data):
        with open(bootstrap.SETTINGS, "w") as fh:
            json.dump(data, fh)

    def test_настоящие_хуки_видны(self):
        for script in ("update.js", "lifecycle.js"):
            self.write(settings_with(
                [f"PATH=\"…\" node '{os.path.join(bootstrap.ROOT, script)}' pre"]))
            self.assertTrue(bootstrap.app_hooks_present(), script)

    def test_старое_написание_без_кавычек_видно(self):
        self.write(settings_with([f"node {os.path.join(bootstrap.ROOT, 'update.js')} pre"]))
        self.assertTrue(bootstrap.app_hooks_present())

    def test_чужой_каталог_с_нашим_префиксом_не_наш(self):
        self.write(settings_with([f"node '{bootstrap.ROOT}-extra/custom.js' pre"]))
        self.assertFalse(bootstrap.app_hooks_present())

    def test_чтение_файла_из_нашего_каталога_не_наш_хук(self):
        self.write(settings_with([f"cat '{os.path.join(bootstrap.ROOT, 'mcp.json')}'"]))
        self.assertFalse(bootstrap.app_hooks_present())

    def test_сосед_с_именем_префиксом_не_наш(self):
        """update.js — сам по себе префикс имени update.js.bak: без правой границы
        совпадение по голому написанию считало соседа нашим хуком."""
        self.write(settings_with([f"cat '{os.path.join(bootstrap.ROOT, 'update.js.bak')}'"]))
        self.assertFalse(bootstrap.app_hooks_present())

    def test_домашний_каталог_с_апострофом_виден(self):
        """install.js квотирует апостроф как '\\'': голого пути в такой команде нет вовсе.
        Без кавычной ветки детектор его не видел — и plugin забирал lease, не сняв дубли."""
        saved_root = bootstrap.ROOT
        bootstrap.ROOT = "/Volumes/O'Brien/.claude/control-bar"
        try:
            script = os.path.join(bootstrap.ROOT, "update.js")
            command = f"PATH=\"…\" node {bootstrap.shell_quoted(script)} pre"
            self.assertNotIn(script, command)  # голое написание и правда отсутствует
            self.write(settings_with([command]))
            self.assertTrue(bootstrap.app_hooks_present())
        finally:
            bootstrap.ROOT = saved_root


if __name__ == "__main__":
    unittest.main()
