#!/usr/bin/env python3
"""Перехват payload'а statusLine.

Запуск: /usr/bin/python3 -m unittest discover -s tests -v
Каждый случай — реальная ошибка, а не проверка формы кода.
"""

import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

HOOKS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks")
sys.path.insert(0, HOOKS)


class Capture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["CONTROL_BAR_ROOT"] = self.tmp
        # ROOT считается на импорте — перезагружаем, чтобы модуль увидел песочницу.
        import statusline

        self.statusline = importlib.reload(statusline)

    def limits(self):
        with open(os.path.join(self.tmp, "limits.json")) as fh:
            return json.load(fh)

    def windows(self):
        with open(os.path.join(self.tmp, "model-windows.json")) as fh:
            return json.load(fh)

    def test_проценты_округляются_до_целого(self):
        """Swift читает это через `as? Int`, и для 4.2 он возвращает nil.

        Лимиты тогда молча исчезают из меню, а файл на диске выглядит совершенно здоровым.
        """
        self.statusline.capture_limits({"rate_limits": {
            "five_hour": {"used_percentage": 4.2, "resets_at": 111},
            "seven_day": {"used_percentage": 68.9, "resets_at": 222},
        }})
        got = self.limits()
        self.assertIsInstance(got["five_hour"]["used_percentage"], int)
        self.assertEqual(got["five_hour"]["used_percentage"], 4)
        self.assertEqual(got["seven_day"]["used_percentage"], 69)

    def test_незнакомые_окна_лимитов_тоже_сохраняются(self):
        """В 2.1.205 есть ещё seven_day_opus и seven_day_sonnet; тариф может добавить свои."""
        self.statusline.capture_limits({"rate_limits": {
            "five_hour": {"used_percentage": 1},
            "seven_day_opus": {"used_percentage": 50},
        }})
        self.assertIn("seven_day_opus", self.limits())

    def test_без_лимитов_файл_не_трогается(self):
        """Блок приходит только подписчикам и только после первого ответа API.

        Пустая запись на ранней отрисовке затёрла бы последние удачные цифры, и раздел
        «Лимиты» мигал бы между числом и пустотой.
        """
        self.statusline.capture_limits({"rate_limits": {
            "five_hour": {"used_percentage": 7}}})
        self.statusline.capture_limits({})
        self.statusline.capture_limits({"rate_limits": {}})
        self.assertEqual(self.limits()["five_hour"]["used_percentage"], 7)

    def test_окно_модели_запоминается_из_payload(self):
        """Реестр моделей внутри бинаря неполон: claude-opus-5 в нём нет вовсе.

        Payload называет размер окна прямо — наблюдение точнее и выскребленного, и догадки.
        """
        self.statusline.learn_window({
            "model": {"id": "claude-opus-5"},
            "context_window": {"context_window_size": 1000000},
        })
        cache = self.windows()
        self.assertEqual(cache["observed"]["claude-opus-5"], 1000000)
        self.assertEqual(cache["models"]["claude-opus-5"], 1000000)

    def test_наблюдение_перебивает_выскребленную_таблицу(self):
        with open(os.path.join(self.tmp, "model-windows.json"), "w") as fh:
            json.dump({"models": {"claude-opus-5": 200000}}, fh)
        self.statusline.learn_window({
            "model": {"id": "claude-opus-5"},
            "context_window": {"context_window_size": 1000000},
        })
        self.assertEqual(self.windows()["models"]["claude-opus-5"], 1000000)

    def test_мусорный_payload_не_роняет(self):
        """Скрипт уходит в фон от строки состояния: падать ему некуда и незачем."""
        for junk in ({}, {"rate_limits": "нет"}, {"model": None}, {"context_window": []}):
            self.statusline.capture_limits(junk)
            self.statusline.learn_window(junk)


    def test_повторение_той_же_картины_не_переписывает_файл(self):
        """statusLine с refreshInterval перерисовывается каждую секунду, цифры движутся
        минутами — идентичная запись на каждой перерисовке была бы чистым дёрганьем диска."""
        payload = {"rate_limits": {"five_hour": {"used_percentage": 12, "resets_at": 1}}}
        self.statusline.capture_limits(payload)
        path = os.path.join(self.tmp, "limits.json")
        first = os.stat(path).st_mtime_ns
        self.statusline.capture_limits(payload)
        self.assertEqual(os.stat(path).st_mtime_ns, first)
        # Изменившееся значение пишется сразу, минуты не ждёт.
        self.statusline.capture_limits(
            {"rate_limits": {"five_hour": {"used_percentage": 13, "resets_at": 1}}})
        self.assertEqual(self.limits()["five_hour"]["used_percentage"], 13)


class Wrapper(unittest.TestCase):
    """Обёртка обязана отдать вложенной команде ровно те байты, что пришли ей."""

    def test_вложенная_команда_получает_тот_же_payload(self):
        tmp = tempfile.mkdtemp()
        inner = os.path.join(tmp, "inner.sh")
        with open(inner, "w") as fh:
            fh.write("#!/bin/bash\nwc -c\n")
        os.chmod(inner, 0o755)
        with open(os.path.join(tmp, "statusline-inner-command"), "w") as fh:
            fh.write(f'bash "{inner}"\n')

        payload = json.dumps({"model": {"id": "claude-opus-5"}, "hint": "хвост\n"})
        result = subprocess.run(
            ["bash", os.path.join(HOOKS, "statusline.sh")],
            input=payload, capture_output=True, text=True,
            env={**os.environ, "CONTROL_BAR_ROOT": tmp}, timeout=30,
        )
        # $(cat) срезал бы хвостовой перевод строки, и вложенный скрипт получил бы не тот вход.
        self.assertEqual(result.stdout.strip(), str(len(payload.encode())))

    def test_обёртка_не_зовёт_саму_себя(self):
        """Sidecar-файл — обычный текст, который можно поправить руками.

        Без этой защиты обёртка, прописанная сама в себя, форкается до отказа машины.
        """
        tmp = tempfile.mkdtemp()
        with open(os.path.join(tmp, "statusline-inner-command"), "w") as fh:
            fh.write(f'bash "{os.path.join(HOOKS, "statusline.sh")}"\n')
        result = subprocess.run(
            ["bash", os.path.join(HOOKS, "statusline.sh")],
            input="{}", capture_output=True, text=True,
            env={**os.environ, "CONTROL_BAR_ROOT": tmp}, timeout=30,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
