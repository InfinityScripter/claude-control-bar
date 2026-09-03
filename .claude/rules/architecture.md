---
description: Направление зависимостей между тремя слоями (Node-хуки, Python, Swift UI) и владельцы файлов состояния
paths:
  - "Sources/**"
  - "hooks/**"
  - "scripts/**"
alwaysApply: false
---

# Слои и владельцы файлов состояния

## Контекст

Проект состоит из трёх независимых слоёв: Node-хуки (`hooks/install.js`, `uninstall.js`, `update.js`, `lifecycle.js`), Python-скрипты (`hooks/bootstrap.py`, `hooks/statusline.py`, `scripts/mcpbar.py`) и Swift UI (`Sources/*.swift`). Между слоями нет прямых импортов — обмен данными идёт только через JSON-файлы в `~/.claude/control-bar/`. Единственный межпроцессный вызов — Swift спавнит `mcpbar.py` как `Process` в `runBackend()` (`Sources/main.swift`, комментарий «the script writes mcp.json and the model re-reads it») и не парсит его stdout: скрипт пишет `mcp.json`, модель Swift перечитывает файл. Если это направление нарушить, слои начинают требовать друг у друга знания о внутреннем устройстве — ровно то, чего дизайн избегает.

## Правила

- Обмен между Node-хуками, Python и Swift — только через JSON-файлы в `~/.claude/control-bar/`. Прямых импортов между слоями нет и быть не должно.
- Единственный разрешённый межпроцессный вызов — Swift спавнит `mcpbar.py` как процесс и не читает его stdout как источник данных; результат — только через файл `mcp.json`.
- Python не читает чужой `.mcp.json` проекта (`mcpbar.py:393-395`) — это конфиг Claude Code, а не файл состояния control-bar.
- Swift не пишет `mcp.json` и `limits.json` напрямую — эти файлы формирует только `mcpbar.py` (и `statusline.py` для `limits.json`). Исключение: Swift удаляет `state.d/*.json` мёртвых процессов в `evaluate()` (`main.swift`, `FileManager.removeItem` при `dead == true`) — это намеренная garbage collection, не запись состояния.
- `limits.json` — файл с двумя писателями (`capture_limits` в `hooks/statusline.py` и команда `limits` в `scripts/mcpbar.py`) и `model-windows.json` — тоже с двумя (`hooks/statusline.py` и `scripts/mcpbar.py`; `hooks/update.js` его только читает); формат между писателями согласован намеренно, оба должны сохранять совместимость при правке.
- `uiconfig.json` правит только пользователь вручную — в кодовой базе писателя нет, только чтение в `main.swift`. Не добавлять код, который пишет в этот файл.
- Хуки (Node, Python) хардкодят identity-значения (bundle id, exec, app name) намеренно, а не читают `identity.env` — после копирования хуков в целевой проект `identity.env` недоступен. Это гвардит CI (`ci.yml:62-95`), не забытая интеграция.
- Внутри Swift-слоя: `main.swift` — единственный владелец путей и жизненного цикла приложения. Модели (`MCPModel`, `Sessions`, `DesktopSessions`, `RunningProcesses`, `Changelog`) — чистые структуры/парсеры без побочных эффектов на файловую систему помимо своего файла. `MCPMenu` — вьюха поверх `MCPModel`, не источник данных.

## Контракты файлов состояния

| Файл | Канонический писатель |
|---|---|
| `state.d/<id>.json` | `hooks/update.js` (Swift только удаляет файлы мёртвых процессов в `evaluate()`, `main.swift`) |
| `mcp.json` | `scripts/mcpbar.py` (refresh) |
| `limits.json` | `capture_limits` в `hooks/statusline.py` и команда `limits` в `scripts/mcpbar.py` (двойной писатель, формат согласован) |
| `owner.json` | `hooks/install.js` |
| quit-intent | Swift: `quit()` и `restartIntoInstalledCopy()` в `main.swift` |
| `model-windows.json` | `hooks/statusline.py` (`learn_window`) и `scripts/mcpbar.py` (двойной писатель; `hooks/update.js` только читает) |
| `context.d/` | `hooks/statusline.py` |
| `paths.json` | `hooks/bootstrap.py` |
| `uiconfig.json` | нет писателя в коде — правит только пользователь; Swift читает в `main.swift` |

## Примеры

НЕПРАВИЛЬНО: Swift напрямую пишет запись в `mcp.json` после получения данных о сервере — теперь у файла два независимых писателя с несогласованным форматом, и `mcpbar.py` может затереть изменения Swift при следующем запуске.
ПРАВИЛЬНО: Swift спавнит `mcpbar.py` (`runBackend()` в `main.swift`) и ждёт, пока тот перезапишет `mcp.json`, затем перечитывает файл — единственный писатель, формат не расходится.

НЕПРАВИЛЬНО: `mcpbar.py` читает `.mcp.json` проекта, чтобы получить список серверов в обход штатного пути.
ПРАВИЛЬНО: `mcpbar.py` не трогает `.mcp.json` проекта (`mcpbar.py:393-395`) — это конфиг Claude Code, а не файл состояния control-bar; данные о серверах идут через собственный `mcp.json` слоя.
