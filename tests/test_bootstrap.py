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


class QuitIntent(unittest.TestCase):
    """Явный Quit обязан пережить резюме сессии.

    SessionStart стреляет и на новую сессию, и на резюме (--resume/--continue, пробуждение,
    компакция). bootstrap.py бежит ПАРАЛЛЕЛЬНО lifecycle.js, поэтому не может полагаться на
    то, что тот уже удалил маркер: правило source→можно-ли-запускать у него своё, одинаковое
    с lifecycle. Без него приложение «возвращалось само» при открытии крышки ноутбука.
    """

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        tmp = self._dir.name
        self._saved = {k: getattr(bootstrap, k) for k in
                       ("ROOT", "QUIT_MARKER", "PATHS", "OWNER", "SETTINGS")}
        bootstrap.ROOT = tmp
        bootstrap.QUIT_MARKER = os.path.join(tmp, "quit-intent")
        bootstrap.PATHS = os.path.join(tmp, "paths.json")
        bootstrap.OWNER = os.path.join(tmp, "owner.json")
        bootstrap.SETTINGS = os.path.join(tmp, "settings.json")

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(bootstrap, k, v)
        self._dir.cleanup()

    def marker(self):
        with open(bootstrap.QUIT_MARKER, "w"):
            pass

    def test_резюме_с_маркером_не_запускает(self):
        self.marker()
        self.assertFalse(bootstrap.may_launch({"source": "resume"}))
        self.assertFalse(bootstrap.may_launch({"source": "compact"}))
        self.assertFalse(bootstrap.may_launch({"source": "fork"}))

    def test_новая_сессия_запускает_даже_с_маркером(self):
        self.marker()
        self.assertTrue(bootstrap.may_launch({"source": "startup"}))
        self.assertTrue(bootstrap.may_launch({"source": "clear"}))

    def test_резюме_без_маркера_запускает(self):
        self.assertTrue(bootstrap.may_launch({"source": "resume"}))

    def test_старый_клод_без_source_запускает(self):
        """Payload без source — старый Claude Code: считать его резюме значило бы, что один
        Quit оставляет приложение лежать навсегда."""
        self.marker()
        self.assertTrue(bootstrap.may_launch({}))
        self.assertTrue(bootstrap.may_launch(None))
        self.assertTrue(bootstrap.may_launch("мусор вместо словаря"))

    def _run_main(self, payload, system_version):
        """main() целиком: заглушки на границах — бандлы, pgrep, Popen, stdin."""
        import io
        launches = []
        saved = {
            "bundle_version": bootstrap.bundle_version,
            "running": bootstrap.running,
        }
        saved_popen, saved_stdin = bootstrap.subprocess.Popen, sys.stdin
        bootstrap.bundle_version = (
            lambda app: system_version if app == bootstrap.SYSTEM_APP
            else bootstrap.plugin_version())
        bootstrap.running = lambda: False
        bootstrap.subprocess.Popen = lambda *a, **kw: launches.append(a[0]) or None
        sys.stdin = io.StringIO(json.dumps(payload))
        try:
            rc = bootstrap.main()
        finally:
            for k, v in saved.items():
                setattr(bootstrap, k, v)
            bootstrap.subprocess.Popen = saved_popen
            sys.stdin = saved_stdin
        return rc, launches

    def test_main_не_поднимает_приложение_на_резюме_после_quit(self):
        self.marker()
        # Ветка «в /Applications стоит DMG-копия» — первый из двух пусков.
        rc, launches = self._run_main({"source": "resume"}, system_version="9.9.9")
        self.assertEqual(rc, 0)
        self.assertEqual(launches, [])
        # Ветка «своя сборка актуальна» — второй пуск.
        rc, launches = self._run_main({"source": "resume"}, system_version=None)
        self.assertEqual(rc, 0)
        self.assertEqual(launches, [])

    def test_main_поднимает_на_новой_сессии_несмотря_на_маркер(self):
        self.marker()
        rc, launches = self._run_main({"source": "startup"}, system_version="9.9.9")
        self.assertEqual(rc, 0)
        self.assertEqual(len(launches), 1)


if __name__ == "__main__":
    unittest.main()
