# Easy VLESS — техническая документация

Для разработчиков и опытных пользователей. Как пользоваться Easy VLESS — в [README](../README.md); здесь — устройство, конфигурация, installer, ручная и офлайн-установка, пакеты, тесты и сборка.

## Содержание

- [Устройство](#устройство)
- [Конфигурация UCI](#конфигурация-uci)
- [Проверки серверов и очередь операций](#проверки-серверов-и-очередь-операций)
- [Подписки: результат обновления и стратегия запроса](#подписки-результат-обновления-и-стратегия-запроса)
- [Мастер настройки](#мастер-настройки)
- [Маршрутизация и диагностика (0.9)](#маршрутизация-и-диагностика-09)
- [Недоверенные данные и блокировки (1.0)](#недоверенные-данные-и-блокировки-10)
- [Структура репозитория](#структура-репозитория)
- [Файлы релиза и SHA256SUMS](#файлы-релиза-и-sha256sums)
- [Системные требования подробно](#системные-требования-подробно)
- [Архитектуры](#архитектуры)
- [Installer](#installer)
- [HTTPS без TLS-библиотеки](#https-без-tls-библиотеки)
- [Ручная установка](#ручная-установка)
- [dnsmasq](#dnsmasq)
- [Пакеты и зависимости](#пакеты-и-зависимости)
- [Переводы интерфейса](#переводы-интерфейса)
- [Подготовленные ресурсы](#подготовленные-ресурсы)
- [Тесты](#тесты)
- [Сборка](#сборка)

## Устройство

Easy VLESS — это shell/Lua-слой PassWall2, сокращённый до VLESS-клиента на sing-box, и собственный интерфейс LuCI.

| Компонент | Файлы на роутере | Роль |
|---|---|---|
| служба | `/etc/init.d/easy_vless` → `/usr/share/easy_vless/app.sh` | запуск/остановка, генерация конфигурации, DNS (dnsmasq), ip rule/route |
| nftables | `/usr/share/easy_vless/nftables.sh` | таблица `inet easy_vless` (fw4 include): TPROXY/REDIRECT, наборы адресов, DNS redirect |
| конфигурация sing-box | `/usr/lib/lua/luci/easy_vless/util_sing-box.lua` (пакет `easy-vless-sing-box`) | outbounds VLESS, группы urltest, маршрутизация по правилам, DNS |
| подписки | `/usr/share/easy_vless/subscribe.lua` | загрузка, разбор форматов, импорт VLESS-узлов, HAPP/HWID |
| проверки | `/usr/share/easy_vless/test.sh`, `clash_api.lua` | Server Test / URL Test во временном экземпляре sing-box, очередь проверок; результаты групп через Clash API |
| интерфейс | `/www/luci-static/resources/view/easy_vless/*.js`, `easy_vless/common.js` | страницы LuCI (JavaScript) |
| rpcd-плагин | `/usr/libexec/rpcd/luci.easy_vless` | ubus-объект `luci.easy_vless`: status, check, start, stop, import, subscribe, urltest_node, test, groups, group_test, resources, wizard_state, wizard |
| ресурсы | `/usr/share/easy_vless/resources/` | манифест и списки доменов готовых правил |

Рабочие файлы запущенной службы (конфигурация sing-box, журналы) лежат в `/tmp/etc/easy_vless/`. Запуск всегда начинается с `sing-box check`: неверная конфигурация не запускается и сетевые настройки не меняет. Трафик самого sing-box к серверу помечается `routing_mark` и в TPROXY не возвращается.

## Конфигурация UCI

`/etc/config/easy_vless` (схема PassWall2; значения по умолчанию — `files/0_default_config`):

| Секция | Назначение |
|---|---|
| `global` | `enabled` (главный переключатель), `node` (что запускается: сервер, группа или `main_router`), `client_proxy`, `localhost_proxy`, DNS (`direct_dns_*`, `remote_dns_*`, `remote_fakedns`, `dns_redirect`, `dns_hosts`), журнал, `clash_api_port`, `wizard_completed` |
| `global_forwarding` | порты (`tcp_redir_ports`, `udp_redir_ports`, `*_no_redir_ports`), `tcp_proxy_way`, `ipv6_tproxy`, `accept_icmp` |
| `global_delay` | `start_delay` |
| `nodes`, `protocol=vless` | VLESS-сервер (`address`, `port`, `uuid`, `transport`, `tls`, `reality`, …); узлы подписок — `add_mode=2`, `group=<имя подписки>` |
| `nodes`, `protocol=_urltest` | группа URL-теста (`urltest_node` — список серверов, `urltest_url`, `urltest_interval`, `urltest_tolerance`) |
| `nodes 'main_router'`, `protocol=_shunt` | «По правилам»: `default_node` — цель «По умолчанию», `option <id правила>` — цель правила |
| `shunt_rules` | правило: только условия (`domain_resource`, `domain_list`, `ip_list`, `network`, `port`, `source`, `sourcePort`, `protocol`, `inbound`); порядок секций = приоритет |
| `subscribe_list` | подписка (`remark`, `url`, `user_agent`, `hwid`, `auto_update`, `access_mode`, …) |

Цели: `_direct` (напрямую), `_blackhole` (блокировка), `_default` (только в правилах: как «По умолчанию»), id сервера или группы. HWID подписок хранится отдельно, в `/etc/easy_vless/hwid` (сохраняется при sysupgrade).

## Проверки серверов и очередь операций

Все операции, которые создают конфигурацию sing-box или запускают/останавливают процессы, — запуск и остановка службы (`app.sh start/stop`), проверка конфигурации (`app.sh check`) и каждый Server Test / URL Test (`test.sh url_test_node`) — выполняются по одной под блокировкой `/var/lock/easy_vless_op.lock` (`op_lock` в `utils.sh`, ожидание до 90 с). Процесс, ждущий блокировку, создаёт маркер `/var/lock/easy_vless_op.lock.wait.<pid>`.

Сохранение настроек службу не перезапускает: с 1.0 пакет не регистрирует триггер ucitrack (до 0.9 каждый `uci commit` из LuCI, в том числе обычное «Сохранить», перезапускал работающую службу в фоне — без проверки конфигурации и без результата). Перезапуск — всегда явное действие: «Сохранить и запустить», «Применить», «Выбрать» в «Списке узлов», обновление подписки, восстановление копии. Запрос на перезапуск, пришедший во время другого перезапуска (`/etc/init.d/easy_vless restart`), не теряется: он оставляет отметку `/var/lock/easy_vless_restart_again`, и работающий перезапуск повторяется один раз, если конфигурация за это время изменилась.

Server Test и URL Test идут через очередь роутера (rpcd `test`, `test.sh`):

| Действие | Что делает |
|---|---|
| `add` (kind `server`/`url`, nodes) | ставит проверки в очередь; проверка сервера, который уже в очереди или проверяется, второй раз не добавляется; при необходимости запускает обработчик `test.sh run_queue` |
| `state` | очередь, текущая проверка, прогресс (`total`/`done`) и последний результат каждого сервера |
| `cancel` | очищает очередь; текущая проверка завершается |
| `clear` | удаляет результаты сервера (сервер изменён) |

Обработчик выполняет проверки строго по одной — одновременно работает не больше одного временного экземпляра sing-box. Перед каждой проверкой он пропускает вперёд ожидающие запуск, остановку или проверку конфигурации (маркеры `op_lock`). Очистка процессов при остановке службы не трогает `test.sh`. Состояние хранится в tmpfs `/var/run/easy_vless_test/` (`r/<узел>.<kind>.json` — результат с временем, адресом и портом сервера; `queue`, `current`, `runner.pid`, `total`, `done`) и сбрасывается перезагрузкой; во flash ничего не пишется. Если обработчик завершился аварийно, `state` очищает очередь — «Проверка…» не зависает. Результат, сделанный для другого адреса или порта, LuCI не показывает; после сохранения сервера его результаты удаляются. Обновление подписки сохраняет идентификатор узла, который остался тем же сервером (см. [раздел 0.9](#маршрутизация-и-диагностика-09)); у нового узла идентификатор новый, и результат удалённого узла переходит к единственному новому узлу с тем же адресом и портом без своего результата (при нескольких — с тем же именем), иначе удаляется.

LuCI опрашивает `state` раз в 1,5 с, пока идут проверки. Сортировка «Списка узлов» (`compareNodes` в `common.js`) использует последний завершённый Server Test: сначала работающие по задержке, затем с ошибкой, затем непроверенные; равные значения — по имени, затем по порядку UCI. Синхронный `urltest_node` сохранён (им пользуются тесты), его результат тоже записывается.

## Подписки: результат обновления и стратегия запроса

`subscribe.lua start <id|all> manual` (rpcd `subscribe update`, отдельным процессом) записывает результат каждой подписки в `/var/run/easy_vless_sub/<id>.json`: `time`, `status` (`ok`, `unchanged`, `no_nodes`, `empty`, `download`, `tls`, `skipped`, `error`), `found` (поддерживаемые узлы в ответе), `before`/`after` (узлы подписки в списке), `format`, `http_code`, `curl_code`, `request` (`curl`, `HAPP`, `custom`), `fallback`. rpcd `subscribe state` отдаёт `busy` (блокировка `/var/lock/easy_vless_subscribe.lock` или уже запущенный `subscribe.lua start`, который ещё не взял блокировку) и эти результаты; `subscribe update` при `busy` отказывает. Успешное обновление записывает `update_time` в секцию подписки. Если в ответе нет поддерживаемых узлов (ошибка загрузки, пустой ответ, HTML, только неподдерживаемые типы), узлы подписки не удаляются.

Стратегия запроса (`user_agent` подписки):

| Значение | Запросы |
|---|---|
| не задано / `curl` | один запрос с User-Agent curl (как до 0.8.0) |
| `HAPP` | один запрос с `User-Agent: HAPP` |
| другой текст | один запрос с этим User-Agent |
| `auto` (новые подписки) | запрос curl; только при ответе HTTP 4xx или без поддерживаемого узла — ещё один запрос с `User-Agent: HAPP`, не больше одного за обновление. Ошибки сети, TLS и 5xx запроса как HAPP не вызывают |

Временные ошибки (таймаут, 5xx) curl повторяет сам (`--retry 3`), как и до 0.8.0.

`hwid = 1` добавляет к каждому запросу `X-HWID` (из `/etc/easy_vless/hwid`, создаётся один раз и сохраняется при sysupgrade), `X-Device-OS: OpenWrt`, `X-Ver-OS` и `X-Device-Model`. Сертификат сервера подписки всегда проверяется.

## Мастер настройки

Мастер (`view/easy_vless/wizard.js`) не хранит собственной конфигурации: ссылка `vless://` импортируется rpcd `import`; ссылка `http(s)://` становится обычной секцией `subscribe_list` (User-Agent `auto`, HWID по выбору), которая обновляется rpcd `subscribe update`; если роутер не нашёл в ней ни одного VLESS-сервера, секция удаляется. Серверы подписки — обычные узлы с `add_mode = 2` и `group` = имя подписки. Проверки идут через очередь `test`, маршрутизация — через готовые правила манифеста и цели `main_router`, применение — `wizard backup`, `uci commit`, `check`, `start`, `wizard finish`; при ошибке `wizard restore` возвращает сохранённую копию `/etc/config/easy_vless`. Отмена удаляет только сервер или подписку, добавленные в этом запуске мастера и нигде не используемые.

## Маршрутизация и диагностика (0.9)

Устройство функций, добавленных в 0.9; как ими пользоваться — в [README](../README.md).

**Выбранный узел и «Выбрать» в «Списке узлов».** Цели правил хранятся в `main_router.<id правила>` как идентификаторы узлов: мастер и «Добавить готовое правило» подставляют туда сервер, выбранный на тот момент. Поэтому «Выбрать» (`ev.setActiveTarget` в `common.js`) при основном узле «По правилам» переносит на новый узел все записи `main_router`, указывавшие на прежний выбранный узел (цели правил и «По умолчанию»), а не только `default_node`. Выбранный узел (`ev.selectedNode`) — это `default_node`, если он сервер или группа, иначе цель первого по порядку правила, указывающая на сервер или группу. Прежним выбранным узлом считается ещё и узел первого готового правила с целью `@active` (`rule_templates` в `manifest.json`: PROXY, QUIC, UDP; правило находится по имени, как в «Добавить готовое правило»), указывающего на сервер или группу. После мастера оба узла совпадают, но расходятся, если раньше менялся только `default_node` («Выбрать» в 0.8, «По умолчанию» на «Главной»): сравнение с одним `ev.selectedNode` (0.9.0) в такой конфигурации продолжало переносить только «По умолчанию». Записи с другой целью («Напрямую», «Блокировать», «Цель по умолчанию», третий сервер, в том числе в пользовательских правилах) не меняются.

**Узлы подписок** (`luci/easy_vless/nodes.lua`, используется `subscribe.lua`). Идентичность узла — адрес, порт, UUID, транспорт, SNI и путь/host транспорта; имя, порядок в списке и идентификатор секции в неё не входят. Ключ узла — 16 шестнадцатеричных цифр от этих полей (UUID по ключу не восстановить).

| Случай | Что происходит при обновлении |
|---|---|
| узел удалён пользователем | ключ и имя записаны в `subscribe_list.excluded_node` (список UCI, до 500 записей); узел с таким ключом не импортируется, счётчик `excluded` в результате обновления |
| узел есть в ответе и уже был | секция пересоздаётся с тем же идентификатором: основной узел, цели правил и группы URL-теста продолжают на него указывать (`updated` / `unchanged`) |
| узла раньше не было | новая секция (`new`) |
| узла нет в новом ответе | секция удаляется (`removed`); ссылки переносятся прежним подбором `select_node` |
| обновление не удалось | узлы и `excluded_node` не меняются |

Удаление сервера, «Удалить все узлы» и восстановление удалённых узлов выполняет `subscribe.lua` (rpcd `nodes`: `delete`, `delete_all_plan`, `delete_all`, `restore`) под той же блокировкой, что и обновление подписок; во время обновления запрос отклоняется. `excluded_node` хранится в секции подписки: переживает перезагрузку и sysupgrade, исчезает вместе с подпиской; заново добавленная подписка начинает без исключений. «Удалить все узлы» удаляет серверы, но не подписки и не правила: группа URL-теста без серверов удаляется, «По умолчанию» становится «Напрямую», цель правила — «Цель по умолчанию», основной узел-сервер сбрасывается с выключением главного переключателя; удалённые так узлы подписок не помечаются исключёнными и вернутся при следующем обновлении.

**Route Explain** (`luci/easy_vless/explain.lua`, rpcd `diag explain`). Не отдельный движок: вычисляются правила `route.rules` и `dns.rules` той конфигурации sing-box, которую создал `util_sing-box.lua`, — работающей, а при остановленной службе той, что создаёт `app.sh check` из сохранённых настроек. Рядом с конфигурацией генератор пишет файл `<config>.meta` (номер правила → секция `shunt_rules`, тег выхода → узел). Семантика — sing-box 1.12: правило подходит, когда подходят все его группы условий; внутри группы назначения записи домена, IP и rule-set — альтернативы; побеждает первое подошедшее правило, иначе `route.final`. Результат трёхзначный: то, что нельзя вычислить (geodata rule-set в `.srs`, регулярное выражение вне поддерживаемого подмножества, IP-условие для домена с неизвестным адресом, условие источника без адреса источника), возвращается как «неизвестно» с причиной, а ответ помечается как неокончательный. Перехват на уровне firewall (порты, локальные адреса, IPv6, адрес FakeDNS) оценивается отдельно по настройкам.

**Диагностика** (`luci/easy_vless/diagnose.lua`, `diag.lua`; rpcd `diag forwarding | dns | connection`). `diag.lua` только собирает состояние (`nft list table inet easy_vless`, `ip rule`, таблица 998, ответы `nslookup`, `app.sh status`, `app.sh env_check`, последний Server Test выбранного узла, `curl` к тестовому адресу), а `diagnose.lua` превращает его в проверки со статусом `ok | warn | fail | off | info` и кодом причины; текст по коду формирует LuCI. Панель «Соединение» — агрегатор этих же проверок; часть, которую не удалось собрать, показывается как «не проверено» и не влияет на остальные. Что роутер увидеть не может (шифрованный DNS на устройстве), сообщается как `info`, а не как результат.

**Блокировки.** Диагностика только читает: не запускает sing-box, сама не берёт `easy_vless_op.lock` и не ждёт её. Согласованную копию конфигурации выдаёт `app.sh diag_config` под `op_lock` с ожиданием 15 с (`EV_DIAG_LOCK_WAIT`); пока блокировку держит запуск или остановка, ответ — `busy`. `diag.lua`, `backup.lua` и `update.sh` исключены из очистки процессов в `app.sh stop`.

**Проверки правил** (`easy_vless/rulecheck.js`, «Правила»). Сообщается только доказуемое по настройкам: правило целиком перекрыто более ранним, стоит после правила без условий, совпадает с ним, противоречивые условия (QUIC по TCP, TLS/HTTP по UDP), цель или ресурс отсутствуют. Обычное пересечение правил не считается ошибкой.

**Резервная копия и импорт** (`luci/easy_vless/transfer.lua`, `backup.lua`; rpcd `transfer`). Два формата: `easy-vless-backup` — всё состояние (файл UCI как есть, HWID, список прямых IP, SHA-256 содержимого), восстановление заменяет конфигурацию целиком; `easy-vless-export` — серверы, правила или подписки, импорт только добавляет записи. Файл полностью проверяется до изменений (`restore_check` / `import_check`), применяется отдельным запросом; перед восстановлением текущая конфигурация копируется в `/etc/easy_vless/restore-backup` (`rollback`). Из файла импорта берутся только известные параметры; запись с некорректным значением пропускается целиком.

**Обновление** (`update.sh`, rpcd `update`). Устанавливается только по подтверждению пользователя. `check` сравнивает установленную версию с релизом, на который указывает `releases/latest` (ответ кэшируется на сутки в tmpfs; автоматическую проверку отключает `global.update_check = 0`). `install <tag>`: загрузка `SHA256SUMS`, `install.sh` и трёх пакетов по HTTPS; каждый файл должен быть указан в `SHA256SUMS` ровно один раз и совпадать, версия пакетов — соответствовать тегу, `install.sh` — быть установщиком этого релиза; `install.sh --check --local`; копия конфигурации в `/etc/easy_vless/update-backup`; загрузка и проверка пакетов установленной версии для отката; `install.sh --local --no-start`; проверка версий пакетов, конфигурации и `app.sh check`; перезапуск службы. При сбое установки или проверки возвращаются прежние пакеты и конфигурация. `SHA256SUMS` берётся из того же релиза: это проверка целостности и принадлежности файлов релизу, а не подпись автора.

## Недоверенные данные и блокировки (1.0)

**Значения конфигурации — данные, а не код.** Имя узла приходит из подписки, запись — из импортируемого файла, настройка — из восстановленной копии. По пути к sing-box они проходят через shell:

| Место | Что сделано |
|---|---|
| `app_acl.lua` → файлы `acl/<id>/var` и `acl/acl_node_<flag>` | значения очищаются (`"`, `$`, `` ` ``, `\` и управляющие символы убираются; аргумент запуска — одно слово); `nftables.sh` читает файл через `.`, а не через `eval $(cat …)` |
| `utils.sh` `eval_set_val` | присваивает `имя=значение`, значение не вычисляется (`app.sh check` передаёт настройки как есть) |
| `utils.sh` `lua_api_arg` | настройка передаётся в Lua через окружение, а не подставляется в исходный текст (`parseDNS`, `get_domain_from_url`, `is_ip`, `resource_file`) |
| `api.lua` `curl_base`, `subscribe.lua` `curl` | URL подписки и User-Agent — аргументы в одинарных кавычках (`api.shellquote`) |
| `util_sing-box.lua` | строки `dns_hosts` разбираются в Lua; код `geosite:` / `geoip:` проверяется (`valid_geo_code`), команда `geoview` собирается из аргументов в кавычках |
| `app.sh` `start_crontab` | в crontab попадают только числа (`cron_num`) |
| `subscribe.lua` `nodeFilter` | из строковых полей узла убираются управляющие символы, из имени — `<` и `>`; порт — целое 1…65535, иначе узел отбрасывается с причиной в журнале |
| `transfer.lua` | в импортируемых правилах проверяются коды geodata и строки списка IP |
| rpcd-плагин | идентификатор секции из запроса — только `[A-Za-z0-9_]` (`valid_id`) |

**Текст в LuCI — текст, а не HTML.** `E(tag, attrs, data)` в LuCI вставляет строку через `innerHTML`; так же вставляются заголовок модального окна, название опции формы и текст ячейки таблицы. Поэтому `common.js` даёт `ev.E` (строка становится текстовым узлом), а каждая страница начинает с `const E = ev.E;`; там, где HTML вставляет сам LuCI, значение экранируется `ev.esc()`. HTML с разметкой остаётся только в описаниях опций формы (переводы с `<code>`, `<b>`).

**Блокировки с владельцем.** `/var/lock/easy_vless_subscribe.lock` и `/var/lock/easy_vless_update.lock/pid` хранят PID процесса. Блокировка, владелец которой завершился (сбой, `kill`), считается устаревшей: `subscribe.lua` забирает её, rpcd и `backup.lua` удаляют, `init.d restart` её не ждёт. Любое действие `subscribe.lua` выполняется под `xpcall` и освобождает блокировку при любой ошибке. Состояние обновления `running` без работающего обновления `update.sh state` превращает в `interrupted`.

## Структура репозитория

| Путь | Содержимое |
|---|---|
| `Makefile` | OpenWrt-пакеты `easy-vless`, `easy-vless-sing-box`, `easy-vless-xray`, `easy-vless-geodata`, `luci-app-easy-vless` |
| `root/` | файлы пакета `easy-vless` и backend-пакетов (служба, скрипты, Lua, ресурсы) |
| `files/` | конфигурация по умолчанию |
| `luci/` | интерфейс: JavaScript-страницы, меню, ACL, rpcd-плагин, переводы (`luci/po`) |
| `scripts/` | `install.sh` (installer, публикуется в релизе), `po2lmo.py`, `i18n-sync.py` |
| `reference/domains/` | исходные списки доменов готовых правил |
| `tests/` | статические проверки, тесты подписок, CI-сценарии (`tests/ci`) |
| `docs/` | эта документация и скриншоты README |
| `.github/workflows/build.yml` | CI: проверки, сборка, тесты, черновик релиза |

## Файлы релиза и SHA256SUMS

Релиз `v1.0.0` на странице [Releases](https://github.com/quargelk/easy-vless/releases):

| Файл | Назначение |
|---|---|
| `easy-vless_1.0.0-r1_all.ipk` | core runtime и подготовленные ресурсы |
| `easy-vless-sing-box_1.0.0-r1_all.ipk` | интеграция с sing-box |
| `luci-app-easy-vless_1.0.0-r1_all.ipk` | интерфейс LuCI и его переводы |
| `install.sh` | installer |
| `SHA256SUMS` | SHA-256 файлов релиза |

`sing-box-tiny` и `dnsmasq-full` в релиз не входят: они ставятся из официального репозитория OpenWrt для архитектуры роутера.

Проверка контрольных сумм (файлы в одной директории): `sha256sum -c SHA256SUMS`, все строки должны закончиться на `OK`. `install.sh` сам проверяет каждый `.ipk` по `SHA256SUMS` того же релиза — и при загрузке с GitHub, и с `--local`. Файл, которого нет в `SHA256SUMS`, пустой, неполный или изменённый, не устанавливается.

## Системные требования подробно

`install.sh` проверяет требования до любых изменений. При несоответствии установка останавливается и показывает фактическое и требуемое значение.

- **RAM** — `MemTotal` из `/proc/meminfo` (или лимит памяти cgroup, если он меньше). Ядро показывает меньше установленной памяти: у роутера с 256 MB это примерно 225–250 MB. Поэтому как 256 MB принимается `MemTotal` от 200 MB; роутер со 128 MB (около 120 MB) отклоняется.
- **Flash / storage** — общий объём носителя, а не размер раздела и не свободное место:
  - для NAND/NOR — размер чипа из сообщения драйвера в журнале ядра (`spi-nand … 128 MiB`, `nand: 128 MiB`, `spi-nor … (16384 Kbytes)`);
  - если сообщения там уже нет — из резерва UBI под bad blocks (20 блоков на каждые 1024 блока чипа);
  - для x86 и роутеров с eMMC — размер диска.

  Если известна только разметка MTD (нижняя граница), installer предупреждает и решает по свободному месту. Образ x86, записанный на диск 1:1 (120.5 MiB), меньше 128 MB: диск нужно увеличить.
- **Свободное место** — реальный worst-case конкретной установки:
  - installer разрешает по репозиторию роутера все пакеты, которые поставит (`sing-box-tiny`, `dnsmasq-full`, зависимости), и суммирует их `Installed-Size`;
  - добавляет размер пакетов Easy VLESS и резерв 2 MB;
  - на UBIFS/JFFS2, которые сжимают файлы, считается 75 % этого объёма (на настоящем UBIFS worst-case установка TR3000 заняла 44 %);
  - загрузки идут в `/tmp` (RAM), там installer тоже проверяет место.

  Пример — новый Cudy TR3000 v1 (24.10.3, UBI 64 MiB, `aarch64_cortex-a53`): 43 новых пакета, 39.5 MB без сжатия (из них `sing-box-tiny` — 27.8 MB), на UBIFS реально 17.6 MB; installer требует 31.6 MB при 38.0 MB свободных. При обновлении, когда `sing-box-tiny` и зависимости уже стоят, нужно около 2.5 MB.

Не устанавливайте одновременно `sing-box` и `sing-box-tiny`: они предоставляют один и тот же virtual package `sing-box`.

## Архитектуры

Пакеты Easy VLESS — один набор с `Architecture: all` (shell, Lua, JavaScript, без бинарных файлов). Архитектурно-зависимые пакеты (`sing-box-tiny`, `dnsmasq-full`, `curl`, `ip-full`, модули ядра `kmod-nft-*`) `opkg` берёт из официального репозитория самого роутера. Поэтому поддерживается любая архитектура, для которой в OpenWrt 24.10 есть `sing-box-tiny` >= 1.12.

Автоматические тесты работают на настоящих образах OpenWrt (rootfs) со своими userland, репозиториями и `uname -m`: x86-64 нативно, остальные — через QEMU user emulation.

| OpenWrt | Target | Architecture |
|---|---|---|
| 24.10.3 | x86/64 | `x86_64` |
| 24.10.8 | x86/64 | `x86_64` |
| 24.10.3 | armsr/armv8 | `aarch64_generic` |
| 24.10.3 | armsr/armv7 | `arm_cortex-a15_neon-vfpv4` |
| 24.10.3 | mvebu/cortexa9 | `arm_cortex-a9_vfpv3-d16` |
| 24.10.3 | malta/be | `mips_24kc` (big-endian) |

Ограничение эмуляции: QEMU user emulation не поддерживает netlink netfilter (nftables) и `setsockopt(SO_MARK)`, поэтому запуск службы и успешный Server Test проверяются только на x86-64; на ARM/MIPS эти проверки помечаются SKIP с причиной из журнала. Размер flash и сжатие UBIFS проверяются отдельно на настоящем UBI/UBIFS (nandsim NAND 128 MiB с разметкой TR3000 v1).

## Installer

```sh
wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v1.0.0/install.sh
sh /tmp/install.sh --check
sh /tmp/install.sh
```

По шагам (при любой ошибке installer останавливается; до шага 6 на роутере ничего не меняется, кроме списков пакетов и, если нужно, времени по NTP):

1. проверяет root, версию OpenWrt (24.10.x), target и архитектуру (`/etc/openwrt_release` против `uname -m`), RAM, flash, утилиты, системное время, HTTPS, DNS, что репозитории в `/etc/opkg/distfeeds.conf` относятся к этой версии, target и архитектуре, `opkg`, fw4/nftables, что PassWall2 не запущен;
2. `opkg update`: репозитории core, kmods, base, packages, luci обязаны работать, сбой остальных даёт предупреждение;
3. оставляет установленный `sing-box`/`sing-box-tiny` >= 1.12.0 или готовит установку `sing-box-tiny`;
4. если `dnsmasq` без nftset, предлагает замену на `dnsmasq-full` (см. [dnsmasq](#dnsmasq));
5. скачивает `SHA256SUMS` и пакеты Easy VLESS (или берёт их из `--local`), проверяет SHA256, разрешает все устанавливаемые пакеты, проверяет их архитектуру и место на overlay и в `/tmp`;
6. ставит `sing-box-tiny`, при необходимости заменяет `dnsmasq`, затем `easy-vless`, `easy-vless-sing-box`, `luci-app-easy-vless`;
7. включает автозапуск; перезапускает службу, только если главный переключатель уже включён;
8. показывает итоговое состояние.

Конфигурация `/etc/config/easy_vless` и HWID (`/etc/easy_vless/hwid`) сохраняются при обновлении и повторном запуске.

| Параметр | Назначение |
|---|---|
| `--check` | только проверки, ничего не устанавливать |
| `--local <dir>` | взять `.ipk` и `SHA256SUMS` из директории (без обращения к GitHub) |
| `--base-url <url>` | скачивать файлы релиза с HTTPS-зеркала вместо GitHub (только `https://`) |
| `--replace-dnsmasq` | разрешить замену `dnsmasq` на `dnsmasq-full` |
| `--yes`, `-y` | ответить «да» на вопрос о замене `dnsmasq` |
| `--no-start` | не перезапускать службу в конце |
| `--bootstrap-opkg` | установить `opkg`, если его нет (только OpenWrt 24.10.x) |
| `--force` | продолжить на другой версии OpenWrt, при неизвестной архитектуре или чужих репозиториях (не тестируется); требования к RAM, flash и месту не отменяет |
| `-h`, `--help` | справка |

## HTTPS без TLS-библиотеки

Если на роутере нет TLS-библиотеки или `ca-bundle`, HTTPS невозможен, а по HTTP installer ничего не скачивает. Нужные пакеты переносятся с компьютера. Доверие к ним не зависит ни от компьютера, ни от канала: installer проверяет подпись индекса `Packages` ключами OpenWrt, уже имеющимися на роутере (`/etc/opkg/keys`, `usign`), а каждый пакет — по SHA256 из этого индекса.

1. На компьютере скачайте из каталога `base` своей версии и архитектуры файлы `Packages` и `Packages.sig`, например `https://downloads.openwrt.org/releases/24.10.3/packages/aarch64_cortex-a53/base/Packages` и `.../Packages.sig`.
2. Там же скачайте пакеты `libustream-mbedtls20201210` и `ca-bundle` (имена файлов — в поле `Filename:` в `Packages`). Если на роутере нет и `opkg`, добавьте пакет `opkg`.
3. Положите их в одну директорию вместе с файлами релиза Easy VLESS и скопируйте на роутер (Dropbear не поддерживает SFTP, поэтому `scp` нужен ключ `-O`):

   ```sh
   scp -O -r easy-vless root@192.168.1.1:/tmp/
   ```

4. На роутере запустите installer с этой директорией (с `--bootstrap-opkg`, если `opkg` нет):

   ```sh
   sh /tmp/easy-vless/install.sh --local /tmp/easy-vless
   ```

Installer проверит подпись и SHA256, установит TLS-библиотеку и `ca-bundle`, повторит проверку HTTPS и продолжит. `opkg update` всё равно требует HTTPS к `downloads.openwrt.org`, поэтому время и DNS должны быть в порядке.

## Ручная установка

Скачайте файлы релиза в одну директорию и проверьте контрольные суммы (перед этим проверьте время и HTTPS):

```sh
mkdir -p /tmp/easy-vless && cd /tmp/easy-vless
for f in SHA256SUMS easy-vless_1.0.0-r1_all.ipk easy-vless-sing-box_1.0.0-r1_all.ipk luci-app-easy-vless_1.0.0-r1_all.ipk install.sh; do
	wget "https://github.com/quargelk/easy-vless/releases/download/v1.0.0/$f"
done
sha256sum -c SHA256SUMS
```

Установка пакетов:

```sh
opkg update
opkg install sing-box-tiny
opkg install ./easy-vless_1.0.0-r1_all.ipk
opkg install ./easy-vless-sing-box_1.0.0-r1_all.ipk
opkg install ./luci-app-easy-vless_1.0.0-r1_all.ipk
/etc/init.d/easy_vless enable
```

Если `dnsmasq` без nftset, замените его на `dnsmasq-full` (см. [dnsmasq](#dnsmasq)). Проще и безопаснее продолжить installer'ом из этой же директории: `sh install.sh --local /tmp/easy-vless`.

### Bootstrap opkg

Если `opkg` на роутере нет, сначала поставьте его вручную. Пример для **OpenWrt 24.10.3 / aarch64_cortex-a53**, в отдельной пустой директории:

```sh
mkdir -p /tmp/opkg-bootstrap && cd /tmp/opkg-bootstrap
wget https://archive.openwrt.org/releases/24.10.3/packages/aarch64_cortex-a53/base/opkg_2024.10.16~38eccbb1-r1_aarch64_cortex-a53.ipk
sha256sum opkg_*.ipk     # должно быть 26cc7fd1d8457c616ac81133e7950b96f36740edd7a3be7c95f0164681197240
tar -xvzf opkg_*.ipk
tar -xzf data.tar.gz -C /
cd / && rm -rf /tmp/opkg-bootstrap
```

Контрольная сумма взята из индекса `Packages` того же каталога (поле `SHA256sum:` для `Package: opkg`); при расхождении ничего не распаковывайте. Для других версий и архитектур возьмите имя файла и SHA256 из `https://archive.openwrt.org/releases/<версия>/packages/<архитектура>/base/Packages`. В пакет не входят `/etc/opkg/distfeeds.conf`, ключи подписи (`openwrt-keyring`) и `usign`; без них `opkg update` не проверит подпись.

`install.sh --bootstrap-opkg` делает то же автоматически: берёт пакет для версии и архитектуры роутера, проверяет SHA256 и подпись индекса, пути внутри пакета, сохраняет изменённый `/etc/opkg.conf`, при необходимости доустанавливает `usign` и `openwrt-keyring` и регистрирует всё в базе `opkg`.

## dnsmasq

Easy VLESS нужен `dnsmasq` с поддержкой nftset. Проверка фактической сборки:

```sh
dnsmasq --version | grep 'Compile time options'
```

`nftset` — поддержка есть; `no-nftset` — нужен `dnsmasq-full`, без него Easy VLESS не запускается и пишет об этом в журнал. (`dnsmasq --help` для проверки не подходит: опция `--nftset` есть в справке любой сборки.)

`install.sh` заменяет `dnsmasq` только после подтверждения (или с `--replace-dnsmasq`): `dnsmasq-full` и копия текущего `dnsmasq` скачиваются и проверяются заранее, `/etc/config/dhcp` сохраняется и восстанавливается, а при ошибке или прерывании (Ctrl-C, обрыв SSH) прежний `dnsmasq` возвращается автоматически. На время перезапуска DHCP/DNS кратко недоступны.

Ручная замена (зависимости ставятся до удаления `dnsmasq`, пока DNS ещё работает):

```sh
opkg update
cd /tmp && opkg download dnsmasq-full
opkg install $(opkg info dnsmasq-full | sed -n 's/^Depends: //p' | tr ',' '\n' | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]].*$//' | grep -v -e '^$' -e '^libc$')
cp -p /etc/config/dhcp /etc/config/dhcp.bak
opkg remove dnsmasq
opkg install /tmp/dnsmasq-full_*.ipk
cp -p /etc/config/dhcp.bak /etc/config/dhcp
/etc/init.d/dnsmasq restart
```

## Пакеты и зависимости

| Пакет | В релизе | Обязателен | Назначение |
|---|:---:|:---:|---|
| `easy-vless` | да | да | core runtime, скрипты, подготовленные ресурсы |
| `easy-vless-sing-box` | да | да | sing-box backend, URL Test, клиент Clash API |
| `luci-app-easy-vless` | да | да | интерфейс LuCI, переводы, rpcd-плагин |
| `sing-box-tiny` | нет (официальный репозиторий) | да | sing-box >= 1.12.0 |
| `dnsmasq-full` | нет (официальный репозиторий) | да | dnsmasq с nftset |
| `easy-vless-xray` | нет | нет | дополнительный Xray backend |
| `easy-vless-geodata` | нет | нет | geoip/geosite для условий правил |

Зависимости из метаданных пакетов `opkg` ставит сам:

- `easy-vless`: `coreutils`, `coreutils-base64`, `coreutils-nohup`, `coreutils-timeout`, `curl`, `ip-full`, `libuci-lua`, `lua`, `luci-compat`, `luci-lib-jsonc`, `resolveip`, `nftables`, `kmod-nft-socket`, `kmod-nft-tproxy`, `kmod-nft-nat`, `openssl-util`, `lyaml`;
- `easy-vless-sing-box`: `easy-vless` и virtual package `sing-box` (его предоставляет `sing-box-tiny` или `sing-box`);
- `luci-app-easy-vless`: `easy-vless`, `luci-base`, `rpcd`.

sing-box вынесен в `easy-vless-sing-box`, чтобы на роутер с маленькой flash ставился только один backend. `dnsmasq-full` нельзя указать зависимостью: он заменяет стандартный `dnsmasq`, а `opkg` не умеет делать такую замену через Depends.

Дополнительные пакеты собираются тем же workflow, но в релиз не публикуются (артефакт `easy-vless-optional` GitHub Actions или [сборка](#сборка)):

- `easy-vless-xray` зависит от `xray-core`; отдельного интерфейса для Xray нет;
- `easy-vless-geodata` — meta package: `geoview`, `v2ray-geoip`, `v2ray-geosite`. Нужен только для условий `geoip:` / `geosite:`; готовые правила RUSSIA/PROXY работают без него. `geoview` есть только в стороннем репозитории [openwrt-passwall-packages](https://github.com/xiaorouji/openwrt-passwall-packages).

## Переводы интерфейса

Тексты интерфейса написаны на английском внутри `_()` в JavaScript-страницах; они же служат ключами перевода. Русский каталог — `luci/po/ru/easy-vless.po`, шаблон — `luci/po/templates/easy-vless.pot`. При сборке пакет `luci-app-easy-vless` компилирует каталог в `/usr/lib/lua/luci/i18n/easy-vless.ru.lmo`; LuCI загружает его вместе со своими каталогами для выбранного языка.

LuCI загружает `base.ru.lmo` вместе с нашим каталогом, и для совпадающего ключа показывается перевод LuCI. Поэтому общие слова («Save», «Enabled», «Finish» …) переведены так же, как в LuCI, а слова, которые LuCI переводит с другим смыслом (`OK`, `Up`, `Down`, `Target`), используются только с контекстом перевода — вторым аргументом `_()`: `_('Up', 'move row')` (в каталоге — `msgctxt`). `i18n-sync.py` не пропускает эти слова без контекста, а e2e-тест в CI ставит `luci-i18n-base-ru` и сверяет каждую строку каталога с тем, что реально отдаёт LuCI.

- `python3 scripts/i18n-sync.py` — обновить шаблон и каталоги после изменения текстов (новые строки получают пустой перевод, удалённые убираются);
- `python3 scripts/i18n-sync.py --check` — проверить, что шаблон актуален, всё переведено, а плейсхолдеры (`%s`, `%d`) и HTML-теги в переводе те же (входит в static checks);
- `scripts/po2lmo.py` — компилятор каталога; его результат побайтно совпадает с `po2lmo` из `luci-base` (проверено на официальных `base.ru.lmo` и `firewall.ru.lmo` OpenWrt 24.10.3).

## Подготовленные ресурсы

Поставляются вместе с `easy-vless`:

```text
/usr/share/easy_vless/resources/manifest.json
/usr/share/easy_vless/resources/domains/proxy.txt
/usr/share/easy_vless/resources/domains/russia.txt
```

Исходные списки лежат в [`reference/domains/`](../reference/domains/); файлы в пакете побайтно совпадают с ними (SHA-256 из `tests/resources.sha256`).

## Тесты

| Тест | Где | Что проверяет |
|---|---|---|
| [`tests/static-checks.sh`](../tests/static-checks.sh) | CI job `checks`, локально | синтаксис shell/Lua/JS/JSON, переводы, ресурсы, screenshots, ссылки README, метаданные пакетов, поиск локальных путей и секретов |
| [`tests/dnsmasq-nftset-test.sh`](../tests/dnsmasq-nftset-test.sh) | static checks | определение nftset по `dnsmasq --version` |
| [`tests/subscription-formats-test.sh`](../tests/subscription-formats-test.sh) | CI, в OpenWrt | форматы подписок; удаление и восстановление узлов; враждебная подписка (перевод строки и команда в имени, неверный порт); блокировка, оставшаяся от завершившегося процесса |
| [`tests/ci/openwrt-runtime-tests.sh`](../tests/ci/openwrt-runtime-tests.sh) | CI, каждая архитектура | установка собранных пакетов installer'ом в контейнере OpenWrt, затем тесты подписок |
| [`tests/ci/installer-tests.sh`](../tests/ci/installer-tests.sh), [`tests/ci/installer-scenarios.sh`](../tests/ci/installer-scenarios.sh) | CI, каждая архитектура | сценарии installer'а: требования, время, HTTPS, архитектуры и репозитории, SHA256, офлайн-установка, откат `dnsmasq`, bootstrap `opkg`, обновление с прошлых версий, удаление |
| [`tests/ci/ubifs-tests.sh`](../tests/ci/ubifs-tests.sh) | CI job `ubifs` | настоящий UBI/UBIFS (nandsim) с разметкой TR3000 v1 |
| [`tests/node-list-sort-test.js`](../tests/node-list-sort-test.js) | static checks | состояние проверок и сортировка «Списка узлов» (`common.js`, без браузера) |
| [`tests/use-server-test.js`](../tests/use-server-test.js) | static checks | «Выбрать» в «Списке узлов»: цели правил и «По умолчанию», разошедшиеся цели, чужие цели не меняются |
| [`tests/nodes-test.lua`](../tests/nodes-test.lua) | static checks | идентичность узлов подписок, удалённые пользователем узлы, слияние обновления, «Удалить все узлы» |
| [`tests/explain-test.lua`](../tests/explain-test.lua), [`tests/diagnose-test.lua`](../tests/diagnose-test.lua), [`tests/diagnostics-view-test.js`](../tests/diagnostics-view-test.js) | static checks | Route Explain (выбор правила, цель, DNS, «неизвестно»), диагностика перенаправления, DNS и панель соединения на образцах состояния; текст для каждого кода результата |
| [`tests/rule-check-test.js`](../tests/rule-check-test.js) | static checks | проверки правил в «Правилах» |
| [`tests/transfer-test.lua`](../tests/transfer-test.lua), [`tests/maintenance-view-test.js`](../tests/maintenance-view-test.js) | static checks | резервная копия и импорт: проверка файла до применения, причины отказа |
| [`tests/update-test.sh`](../tests/update-test.sh) | static checks | обновление с подставными `curl` и `opkg`: целостность, совместимость, сбой установки и откат, блокировка живого и завершившегося процесса, прерванное обновление |
| [`tests/shell-safety-test.sh`](../tests/shell-safety-test.sh) | static checks | настоящие `app_acl.lua` и `eval_set_val` на враждебных значениях (имя узла, настройки DNS): ни одна команда из значения не выполняется |
| [`tests/html-safety-test.js`](../tests/html-safety-test.js) | static checks | `ev.E` и `ev.esc`, диалоги `common.js` с враждебным именем, использование `ev.E` на каждой странице |
| [`tests/ci/v09-backend-tests.sh`](../tests/ci/v09-backend-tests.sh) | CI, каждая архитектура | 0.9 через ubus в контейнере OpenWrt: Route Explain на настоящей конфигурации, диагностика, её одновременная работа с запуском, остановкой, проверкой и обновлением подписки, удаление узлов, резервная копия и импорт; проверка, Route Explain и настоящий запуск с враждебными настройками и враждебным именем узла |
| [`tests/ci/workflow-events.py`](../tests/ci/workflow-events.py) | CI job `checks` | какие jobs запускаются для pull request, push в main, тега |
| [`tests/ci/wizard-tests.sh`](../tests/ci/wizard-tests.sh), [`tests/ci/wizard-backend-tests.sh`](../tests/ci/wizard-backend-tests.sh), [`tests/ci/sub-server.py`](../tests/ci/sub-server.py) | CI, каждая архитектура | мастер настройки через ubus с настоящим VLESS-сервером; очередь проверок (Test All, повторное нажатие, отмена, аварийное завершение, остановка и проверка конфигурации во время проверок); `uci commit` из LuCI не перезапускает службу, запрос на перезапуск во время перезапуска не теряется; подписки на тестовом HTTP-сервере: форматы, ошибки с сохранением узлов, User-Agent / HAPP / HWID и число запросов, повторное обновление |
| [`tests/ci/luci_wizard_e2e.py`](../tests/ci/luci_wizard_e2e.py) | CI, x86-64 | настоящий LuCI в headless Chromium: мастер от начала до конца (ссылка VLESS и ссылка на подписку), ошибки, восстановление, «Список узлов» (задержка, сортировка, фильтры, Test All, повторные нажатия, обновление подписки), ширина 375 px, русский каталог рядом с каталогом LuCI |
| [`tests/tr3000-slice-smoke.sh`](../tests/tr3000-slice-smoke.sh) | вручную на роутере | запуск/остановка службы, nftables, ip rule; с таймером отката |

Локально: `bash tests/static-checks.sh`.

## Сборка

Эталонная сборка — GitHub Actions ([`.github/workflows/build.yml`](../.github/workflows/build.yml)) в официальном OpenWrt 24.10.3 SDK для mediatek/filogic. Ручная сборка в распакованном SDK:

```sh
./scripts/feeds update -a
./scripts/feeds install -p packages coreutils curl lyaml sing-box xray-core v2ray-geoip v2ray-geosite
./scripts/feeds install -p luci luci-base luci-compat luci-lib-jsonc
git clone https://github.com/quargelk/easy-vless.git package/easy-vless
cat >> .config <<'EOF'
CONFIG_PACKAGE_easy-vless=y
CONFIG_PACKAGE_easy-vless-sing-box=y
CONFIG_PACKAGE_easy-vless-xray=y
CONFIG_PACKAGE_luci-app-easy-vless=y
CONFIG_PACKAGE_easy-vless-geodata=y
EOF
make defconfig
make -C package/easy-vless TOPDIR="$PWD" clean compile V=s
find bin -name '*easy-vless*.ipk'
```

`make -C package/easy-vless` собирает только пакеты Easy VLESS; sing-box, xray-core и другие зависимости нужны только как метаданные для Depends. Для перевода нужен `python3` (он и так обязателен для OpenWrt SDK). `easy-vless-geodata` собирается, только если подключён репозиторий с `geoview`.

CI по событиям (проверяет `tests/ci/workflow-events.py`):

| Событие | Jobs |
|---|---|
| pull request, workflow_dispatch | полный CI: `checks`, `build`, вся матрица `runtime-tests` (6 целей × 4 группы, с e2e в Chromium), `ubifs` |
| push в main | `checks`, `build` — то же дерево уже прошло полный CI в своём pull request |
| тег `v*` | `checks`, `build`, `release`: черновик релиза создаётся, только если есть успешный полный запуск CI для того же дерева (`tree_id`); матрица повторно не запускается |

Черновик (draft) публикуется вручную.
