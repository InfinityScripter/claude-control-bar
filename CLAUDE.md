# CLAUDE.md

macOS menu-bar приложение: статус сессий Claude Code, MCP-серверов и лимитов. Плагин Claude Code. Swift (universal binary) + Node-хуки + Python-скрипты.

## Ключевые команды

- Сборка: `./build.sh` (staging→swap, подпись, опц. нотаризация)
- Сборка DMG: `./build.sh --dmg`
- Python-тесты: `/usr/bin/python3 -m unittest discover -s tests -v`
- Node-тесты: `node --test tests/*.test.js`
- Swift model-check: компиляция `tests/model/main.swift` против модельных исходников (см. `.github/workflows/ci.yml`)

## Критические ограничения

- Версия обязана совпадать в `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` и `Info.plist` собранного `.app` — гвард в CI.
- Идентичность (bundle id, exec, app name) — только из `identity.env`, не хардкодить в других файлах.
- Внутренний таймаут сборки (240s) обязан оставаться меньше hook-таймаута SessionStart (300s).
- Архитектура и конвенции — в `.claude/rules/`, здесь не дублируются.
