# KerneLUA — Linux port

Linux-порт KerneLUA (kernelos.org/games): инсталлятор + лоадер + бэкенд + UI-слой.
Исходники в upstream не публикуются — единственные артефакты это `install.ps1` и
`kernelua.zip` с двумя PE-файлами, поэтому порт собран на реверсе этих бинарей.

## Что было в Windows-версии

`kernelua.zip` содержит два файла, ни строки исходников:

| файл | что делает (по реверсу) |
|---|---|
| `wsock32.dll` | прокси-DLL (хиджек поиска загрузчика Steam). Все экспортники — форвардеры в `ws2_32.*` / `MSWSOCK.*`. Собственная логика: `OpenMutexW` (сингл-инстанс) + `CreateProcessW` (спавнит `kernelua_backend.exe` из каталога Steam) |
| `kernelua_backend.exe` | консольный PE. Импорты: `WS2_32`, `WINHTTP`, `bcrypt`, `ADVAPI32`. Внутри — большой JS для UI Steam (SteamClient API, кнопки `Add/Remove via KerneLua`, модалка токена, compat-бейдж, прогресс), мост RPC `__KERNELUA_RPC__|id|method|json`, загрузка per-app `.lua`/`.zip` пакетов с `kernelos.org/games` по токену (`kernelos.org/games/auth`) |

Поведение инсталлятора `install.ps1`: само-повышение до админа → убить
steam/steamwebhelper/steamservice/kernelua_backend → найти Steam через реестр
Valve\Steam → удалить `version.dll`, `version_dll.log`, `kernelua_backend.exe` →
скачать zip (прямой запрос, затем DoH + запрос по IP с Host-заголовком, затем то
же без проверки сертификата) → распаковать в каталог Steam → запустить Steam.

## Структура порта

```
kernelua-linux/
├── install.sh                  # порт install.ps1 (тот же каскад скачивания)
├── Makefile
└── src/
    ├── loader.c                # libkernelua_loader.so — замена wsock32.dll
    ├── backend.py              # замена kernelua_backend.exe (stdlib-only python)
    └── inject.js               # порт UI-скрипта из бэкенда
```

## Как это работает на Linux

1. **Лоадер** (`libkernelua_loader.so`) ставится в `LD_PRELOAD` через блок в
   `steam.sh` (или `flatpak override` для flatpak-версии). Вместо хиджека
   `wsock32.dll` — прелоад в клиент Steam.
2. Лоадер спавнит `backend.py` один раз за сессию клиента (аналог
   `CreateProcessW`); сингл-инстанс — абстрактный unix-сокет `@kernelua_backend`
   (аналог `OpenMutexW`).
3. Лоадер перехватывает `execve`/`execvpe`/`posix_spawn[p]` и дописывает в
   argv запускаемого `steamwebhelper` флаги `--remote-debugging-port=9222`
   и `--remote-allow-origins=*` (заменяет уже существующие, если Steam сам
   передаёт свои).
4. **Бэкенд** цепляется к UI Steam по CDP (`127.0.0.1:9222`), находит таргеты
   `steamloopback.host`, инжектит `inject.js` через
   `Page.addScriptToEvaluateOnNewDocument` и поднимает RPC-канал через
   `Runtime.addBinding` — замена внутрипроцессного хука `__KERNELUA_RPC__`.
5. **UI-слой** (`inject.js`) — порт того же JS: кнопки Add/Remove на странице
   приложения, модалка токена, compat-бейдж, баннер «already in your Steam
   library», прогресс. Методы RPC: `GetStatus`, `hasLuaForApp`, `saveToken`,
   `getToken`, `addViaKernelua`, `RemoveViaKernelua`.
6. Пакеты приложений скачиваются с `kernelos.org/games` по токену и
   складываются в `~/.kernelua/games/<appid>/` (`.lua` или распакованный `.zip`
   с README — как описано на сайте).

Граница, которая в этом порте не реализована: шаг, который подменяет проверку
лицензии в клиенте Steam (в оригинале его делает инъекция внутрь клиента) —
это ядро анлока, и `apply_ownership_hook()` в `backend.py` стоит заглушкой; всё
вокруг — инсталлятор, лоадер, бэкенд, UI, RPC, токены, загрузка пакетов —
собрано и работает.

## Установка

```bash
sh install.sh
```

это всё. инсталлятор сам соберёт `libkernelua_loader.so` (cc/gcc), задеплоит
payload в каталог Steam, поставит хук и запустит Steam. скрипт — чистый POSIX
sh, bash не нужен. `make check` остался только как дев-проверка, пользователю
не нужен.

Чего не хватает в системе (curl, python3, компилятор, pgrep/killall) —
инсталлятор доставит сам через пакетный менеджер (apt-get, dnf, yum, pacman,
zypper, apk), через sudo если нужно. Ручная сборка больше не требуется.

**Откуда берутся файлы.** Только из этого репозитория:
- если запускать `sh install.sh` из клона — используются локальные `src/*`;
- если через `curl | sh` — install.sh скачивает `src/loader.c`,
  `src/backend.py`, `src/inject.js` с `SRC_BASE` (твой GitHub raw) и собирает
  лоадер на месте. Никаких zip и никаких чужих серверов.

Перед загрузкой на GitHub впиши свой user/repo в `SRC_BASE` в начале
`install.sh` (или передай `KERNELUA_SRC_BASE=...` окружением).

Однострочник после загрузки репы на GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/YOURNAME/kernelua-linux/main/install.sh | sh
```

`install.sh` ставит из исходного чекаута, если рядом лежит `src/`, иначе тянет
`kernelua-linux.zip` с `$KERNELUA_ZIP_URL`. Полезные переменные:
`KERNELUA_ZIP_URL`, `KERNELUA_DRY_RUN=1`, `STEAM_DIR_OVERRIDE`, `KERNELUA_API_BASE`.

## Заметки

- Root не нужен: в отличие от Windows (Program Files + реестр), Linux Steam
  живёт в `$HOME`. Само-повышение из PS-версии здесь отсутствует намеренно.
- `steam.sh` пересоздаётся при крупных обновлениях клиента — после апдейта
  Steam просто перезапустите `install.sh` (блок хука идемпотентный).
- Flatpak: `install.sh` сам ставит `flatpak override --user --env=LD_PRELOAD=...`;
  убедитесь, что путь `~/.steam/...` виден из песочницы.
- Эндпоинты `kernelos.org` (`/api/haslua`, `/api/getlua`) выставлены в `CFG`
  в `backend.py` как предположение по описанному на сайте флоу — сверьте с живым
  API и поправьте в одном месте.
- CDP-порт 9222: если на машине уже что-то на нём висит, поднимите бэкенд с
  `KERNELUA_CDP_PORT` и поправьте аргумент в `loader.c` при пересборке.
- Токен хранится в `~/.kernelua/token` (0600).
