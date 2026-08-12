# Claude Control Bar

[English](README.md) | **Русский**

https://github.com/user-attachments/assets/39381f85-c8ce-4d32-8baa-dce67d39ee7e

Приложение для строки меню macOS для **Claude Code**: показывает, что Claude делает прямо сейчас, и позволяет управлять тем, с чем он работает, — ничего не открывая.

- **Сессии** — анимированная иконка, пока Claude думает, жёлтая точка, когда нужно ваше разрешение, живой таймер хода и заполненность контекстного окна по каждой сессии. Клик по сессии выводит вперёд терминал или редактор, где она живёт.
- **MCP** — каждый сервер и каждый инструмент со своим переключателем. Выключенный инструмент не просто блокируется — он целиком убирается из контекста Claude.
- **Лимиты** — 5-часовой и 7-дневный лимиты в виде полосок прямо в строке меню, время сброса — в меню.

## Установка

### Как плагин Claude Code (рекомендуется)

```bash
/plugin marketplace add InfinityScripter/claude-control-bar
```

```bash
/plugin install claude-control-bar
```

Приложение собирается из исходников на вашем Mac при следующем старте сессии, поэтому нужны Xcode Command Line Tools (`xcode-select --install`). Обновления приходят вместе с плагином.

### DMG

1. Скачайте `claude-control-bar.dmg` из [последнего релиза](../../releases/latest).
2. Перетащите **Claude Control Bar** в «Программы».
3. Запустите один раз — это установит хуки.

> [!IMPORTANT]
> DMG не нотаризован, поэтому macOS заблокирует первый запуск. Откройте **Системные настройки → Конфиденциальность и безопасность** и нажмите **Всё равно открыть**, либо выполните
> `xattr -dr com.apple.quarantine "/Applications/Claude Control Bar.app"`.

Выберите один канал установки — оба сразу дают дублирующиеся хуки (приложение само разрулит в пользу плагина, но лучше не надо).

## Использование

Приложение не нужно открывать: оно запускается само при старте сессии Claude Code и закрывается, когда сессий нет. Всё живёт в иконке строки меню — сессии, лимиты, переключатели MCP и настройки.

Переключение сервера или инструмента действует на **новые** сессии (Claude Code собирает список инструментов при старте сессии).

Лимиты берутся из ручки usage Anthropic (та же, что у команды `/usage`) с OAuth-токеном, который Claude Code хранит в Keychain. Токен остаётся локальным и отправляется только на `api.anthropic.com`; в настройках есть выключатель. Все создаваемые файлы и сетевые запросы перечислены в [PRIVACY.md](PRIVACY.md).

## Требования

- macOS 12+
- [Claude Code](https://claude.com/claude-code) (CLI или Desktop-приложение)
- Node.js и системный `/usr/bin/python3`
- Xcode Command Line Tools — только для плагина (он собирает приложение локально); для DMG не нужны

## Удаление

Плагин: `/plugin uninstall claude-control-bar`, затем перетащите `~/Applications/Claude Control Bar.app` в Корзину.

DMG:

```bash
node "/Applications/Claude Control Bar.app/Contents/Resources/uninstall.js"
```

Затем перетащите приложение в Корзину. Служебные файлы лежат в `~/.claude/control-bar/`.

## Проблемы

См. [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Благодарности и лицензия

Форк [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) Мика Цесанека, объединённый с [claude-mcp-bar](https://github.com/InfinityScripter/claude-mcp-bar). [Контрибьюторы →](ACKNOWLEDGEMENTS.md)

MIT — см. [LICENSE](LICENSE). Неофициальный проект, не связан с Anthropic и не одобрен ею; «Claude» — товарный знак Anthropic, используется номинативно.
