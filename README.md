# Easy VLESS

Лёгкий VLESS-клиент для OpenWrt с интерфейсом LuCI.

*A lightweight VLESS client for OpenWrt 24.10 (LuCI, sing-box, nftables/fw4 TPROXY).*

Easy VLESS прозрачно проксирует трафик роутера и LAN-устройств через VLESS-серверы. Он использует sing-box и поддерживает Reality, раздельное туннелирование с готовыми списками доменов, подписки (включая HAPP/HWID) и URL Test. Проект основан на PassWall2 и оставляет из него только то, что нужно для VLESS-клиента.

**Текущая версия: 0.5.1-r1** · OpenWrt **24.10.x** (opkg) · Лицензия **GPL-3.0-only**

Проект тестировался на **Cudy TR3000 v1** с **OpenWrt 24.10.3** (см. [Tested Hardware](#tested-hardware)).

![Main](docs/images/main.png)

## Содержание

- [Возможности](#возможности)
- [Требования](#требования)
- [Установка](#установка)
  - [Файлы релиза и SHA256SUMS](#файлы-релиза-и-sha256sums)
  - [Установка через installer](#установка-через-installer)
  - [Ручная установка](#ручная-установка)
  - [dnsmasq](#dnsmasq)
- [Первоначальная настройка](#первоначальная-настройка)
- [Rule Manage](#rule-manage)
- [Node List](#node-list)
- [Подписки](#подписки)
- [HAPP / HWID](#happ--hwid)
- [Main](#main)
- [Connection Test (Server Test)](#connection-test-server-test)
- [URL Test](#url-test)
- [Settings](#settings)
- [Resources](#resources)
- [Packages и Dependencies](#packages-и-dependencies)
- [Tested Hardware](#tested-hardware)
- [Known Limitations](#known-limitations)
- [Tests](#tests)
- [Build](#build)
- [Upstream](#upstream)
- [License](#license)

## Возможности

- VLESS (TCP, WebSocket, gRPC, HTTPUpgrade)
- TLS / Reality / uTLS, flow `xtls-rprx-vision`
- Прозрачное проксирование через TPROXY (nftables / fw4)
- DNS: Direct/Remote DNS, FakeDNS и DNS Redirect
- Раздельное туннелирование: правила, готовые списки доменов RUSSIA/PROXY, шаблоны QUIC/UDP
- Импорт и копирование VLESS URL
- Подписки: VLESS URL, base64, sing-box JSON, Clash YAML (импортируются только VLESS-узлы)
- HAPP User-Agent и HWID для подписок
- Server Test (реальный HTTPS-запрос через сервер) и URL Test (группы с автоматическим выбором сервера)
- LuCI-интерфейс: **Main**, **Node List**, **Rule Manage**, **Settings**

## Требования

| | |
|---|---|
| OpenWrt | **24.10.x** с менеджером пакетов `opkg` (OpenWrt с `apk` не поддерживается) |
| Firewall | fw4 / nftables (стандарт для OpenWrt 24.10) |
| Пакеты Easy VLESS | `easy-vless`, `easy-vless-sing-box`, `luci-app-easy-vless` |
| VLESS engine | `sing-box-tiny` **>= 1.12.0** из официального репозитория пакетов OpenWrt (или полный `sing-box`) |
| dnsmasq | `dnsmasq-full` (dnsmasq с поддержкой nftset), см. [dnsmasq](#dnsmasq) |
| Место | около 3 МБ для пакетов Easy VLESS, плюс размер `sing-box-tiny` и зависимостей |
| Конфликты | PassWall2 должен быть остановлен |

Пакеты Easy VLESS имеют архитектуру `all` (shell/Lua/JS, без бинарных файлов). Архитектурное ограничение одно: для архитектуры роутера в официальном репозитории OpenWrt должен быть `sing-box-tiny` версии 1.12.0 или новее. `install.sh --check` проверяет это до установки.

Не устанавливайте одновременно `sing-box` и `sing-box-tiny`: они предоставляют один и тот же virtual package `sing-box`.

## Установка

### Файлы релиза и SHA256SUMS

Готовые пакеты публикуются на странице [Releases](https://github.com/quargelk/easy-vless/releases). Релиз `v0.5.1` содержит:

| Файл | Назначение |
|---|---|
| `easy-vless_0.5.1-r1_all.ipk` | core runtime и подготовленные ресурсы |
| `easy-vless-sing-box_0.5.1-r1_all.ipk` | интеграция с sing-box |
| `luci-app-easy-vless_0.5.1-r1_all.ipk` | LuCI-интерфейс |
| `install.sh` | installer |
| `SHA256SUMS` | SHA-256 всех файлов выше |

`sing-box-tiny` и `dnsmasq-full` в релиз не входят: они устанавливаются из официального репозитория пакетов OpenWrt для архитектуры роутера. Optional packages (`easy-vless-xray`, `easy-vless-geodata`) тоже не входят в релиз, см. [Packages и Dependencies](#packages-и-dependencies).

Проверка контрольных сумм (все пять файлов в одной директории):

```sh
sha256sum -c SHA256SUMS
```

Все строки должны закончиться на `OK`. `install.sh` сам проверяет `.ipk` по `SHA256SUMS` релиза, при онлайн-установке и с `--local`.

### Установка через installer

`install.sh` — обычный shell-скрипт, который можно прочитать перед запуском:

```sh
wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v0.5.1/install.sh
sh /tmp/install.sh --check
sh /tmp/install.sh
```

`--check` только проверяет роутер (и обновляет списки пакетов `opkg`), ничего не устанавливает и не меняет.

Установщик по шагам:

1. проверяет root, версию OpenWrt (24.10.x), архитектуру, наличие нужных утилит, `opkg`, fw4/nftables, что PassWall2 не запущен, свободное место;
2. выполняет `opkg update`;
3. оставляет установленный `sing-box`/`sing-box-tiny` >= 1.12.0 или устанавливает `sing-box-tiny` из официального репозитория OpenWrt (подпись репозитория и checksum пакета проверяет `opkg`);
4. если `dnsmasq` без nftset — предлагает замену на `dnsmasq-full` и выполняет её только после подтверждения, см. [dnsmasq](#dnsmasq);
5. скачивает пакеты Easy VLESS релиза (или берёт их из `--local`) и проверяет их по `SHA256SUMS`;
6. устанавливает `easy-vless`, `easy-vless-sing-box`, `luci-app-easy-vless`;
7. включает автозапуск; перезапускает сервис, только если Main switch уже включён (новую установку запускают из LuCI после добавления сервера);
8. показывает итоговое состояние.

При любой ошибке установщик останавливается. Существующая конфигурация `/etc/config/easy_vless` сохраняется.

| Параметр | Назначение |
|---|---|
| `--check` | только проверки, ничего не устанавливать |
| `--local <dir>` | взять `.ipk` и `SHA256SUMS` из директории с загруженными файлами релиза |
| `--replace-dnsmasq` | разрешить замену `dnsmasq` на `dnsmasq-full` |
| `--yes` | ответить «да» на вопрос о замене `dnsmasq` (включает `--replace-dnsmasq`) |
| `--no-start` | не перезапускать сервис в конце |
| `--bootstrap-opkg` | разрешить установку `opkg`, если он отсутствует (только OpenWrt 24.10.x) |
| `--force` | продолжить на версии OpenWrt, отличной от 24.10.x (не тестируется) |

### Ручная установка

Файлы релиза должны находиться в одной директории на роутере, и их контрольные суммы должны быть проверены (см. [выше](#файлы-релиза-и-sha256sums)):

```sh
cd /tmp
for f in SHA256SUMS easy-vless_0.5.1-r1_all.ipk easy-vless-sing-box_0.5.1-r1_all.ipk luci-app-easy-vless_0.5.1-r1_all.ipk install.sh; do
	wget "https://github.com/quargelk/easy-vless/releases/download/v0.5.1/$f"
done
sha256sum -c SHA256SUMS
```

Если `opkg` на роутере отсутствует, сначала выполните bootstrap `opkg`. Пример для **OpenWrt 24.10.3 / aarch64_cortex-a53**:

```sh
wget https://archive.openwrt.org/releases/24.10.3/packages/aarch64_cortex-a53/base/opkg_2024.10.16~38eccbb1-r1_aarch64_cortex-a53.ipk
tar -xvzf opkg_*.ipk
tar -xzf data.tar.gz -C /
```

> Эта ссылка относится только к OpenWrt 24.10.3 и архитектуре `aarch64_cortex-a53`. Не используйте её для других версий и архитектур. `install.sh --bootstrap-opkg` берёт пакет `opkg` для версии и архитектуры самого роутера и проверяет его контрольную сумму по индексу репозитория.

Затем установите sing-box и Easy VLESS:

```sh
opkg update
opkg install sing-box-tiny
opkg install ./easy-vless_0.5.1-r1_all.ipk
opkg install ./easy-vless-sing-box_0.5.1-r1_all.ipk
opkg install ./luci-app-easy-vless_0.5.1-r1_all.ipk
/etc/init.d/easy_vless enable
```

Если `dnsmasq` без nftset, замените его на `dnsmasq-full` (см. [dnsmasq](#dnsmasq)).

После установки откройте **LuCI → Services → Easy VLESS**.

### dnsmasq

Easy VLESS нужен `dnsmasq` с поддержкой nftset. Проверяется фактическая сборка по Compile time options:

```sh
dnsmasq --version | grep 'Compile time options'
```

- `nftset` — поддержка есть, ничего менять не нужно;
- `no-nftset` — обычный `dnsmasq` без nftset: нужен `dnsmasq-full`. Без него Easy VLESS не запускается и сообщает об этом в логе.

`dnsmasq --help` для проверки не подходит: опция `--nftset` есть в справке любой сборки.

Easy VLESS не заменяет системный `dnsmasq` самостоятельно. `install.sh` сначала показывает, что будет сделано, и выполняет замену только после подтверждения (или с `--replace-dnsmasq`):

- `dnsmasq-full` и его зависимости скачиваются заранее; `dnsmasq-full` проверяется по SHA256 из индекса репозитория;
- сохраняется копия текущего пакета `dnsmasq` для отката;
- `/etc/config/dhcp` сохраняется в `/etc/config/dhcp.easy-vless.bak` и восстанавливается после замены;
- если установить `dnsmasq-full` не удалось, возвращается прежний `dnsmasq` и его конфигурация;
- на время перезапуска `dnsmasq` DHCP/DNS на роутере кратко недоступны.

Ручная замена (то же, что делает installer; зависимости ставятся до удаления `dnsmasq`, пока DNS ещё работает):

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

Не заменяйте системный `dnsmasq` без необходимости.

## Первоначальная настройка

1. **Rule Manage** — если нужно раздельное туннелирование, добавьте подготовленные правила.
2. **Node List** — добавьте VLESS-сервер (Import VLESS URL / Add VLESS) или подписку.
3. **Main** — выберите сервер или `Main Router (shunt)`, включите Main switch, нажмите **Save & Start**.
4. **Settings** — дополнительные параметры DNS, Forwarding и sing-box (обычно менять не требуется).

---

## Rule Manage

Раздел **Rule Manage** используется для раздельного туннелирования.

Рядом с кнопкой **Add rule** находится список подготовленных правил. Выберите нужное правило и нажмите **Add prepared rule**.

Подготовленные ресурсы уже входят в пакет `easy-vless`. Доступны правила:

- **RUSSIA** — домены из списка RUSSIA, по умолчанию Direct;
- **PROXY** — домены из списка PROXY, через выбранный сервер;
- **QUIC** — UDP 443;
- **UDP** — весь UDP.

Правила проверяются сверху вниз, срабатывает первое подходящее. Порядок меняется кнопками ↑/↓.

Для изменения правила нажмите **Edit**. Через **+ Add condition** можно добавить собственные условия, например домены. Ручные условия нужны, когда подготовленных правил недостаточно или конкретный ресурс работает неправильно.

![Rule Manage](docs/images/rule-manage.png)

---

## Node List

В **Node List** добавляются VLESS-серверы, подписки и URL Test Groups.

Для каждого сервера доступны: **Use**, **Test** (Server Test), **URL Test**, **Copy** (VLESS URL сервера), ↑/↓, **Edit**, **Delete**.

![Node List](docs/images/node-list.png)

### Добавление VLESS

Нажмите **Import VLESS URL**, вставьте одну или несколько ссылок `vless://` и выполните импорт. Сервер можно добавить и вручную через **Add VLESS**.

После добавления нажмите **Save & Apply**.

### Добавление подписки

Нажмите **Add subscription**.

![Add Subscription](docs/images/add-subscription.png)

В поле **Name** укажите любое название, в поле **Subscription URL** — ссылку на подписку (например, полученную от VPN-сервиса или Telegram-бота). После сохранения нажмите **Save & Apply**, затем **Update** у подписки.

Для некоторых сервисов при первом добавлении необходимо временно отключить VPN, чтобы запрос к серверу подписки не проходил через другой туннель.

### URL Test Groups

Группа объединяет несколько серверов: sing-box периодически проверяет их и использует самый быстрый. Группу можно выбрать как основной узел, как Default или как цель правила. Параметры: **Test URL** (по умолчанию `https://x.com`), **Interval**, **Tolerance (ms)**.

---

## Подписки

Easy VLESS определяет формат подписки автоматически и импортирует **только VLESS-узлы**. Узлы других типов пропускаются, их количество пишется в лог.

| Формат | Поддержка |
|---|---|
| Одна или несколько ссылок `vless://` (plain text) | да |
| Тот же список в base64 | да |
| sing-box JSON (`outbounds[]`) | да, experimental |
| JSON-массив outbounds | да, experimental |
| sing-box JSON в base64 | да, experimental |
| Clash YAML (`proxies`) | только VLESS-узлы |

Особенности sing-box JSON:

- читаются только `outbounds[]`; `inbounds`, `dns`, `route`, `rule_set`, `log`, `experimental` и пути к файлам из чужих конфигураций (в том числе Windows-пути) не переносятся;
- `direct`, `block`, `dns`, `selector`, `urltest` не считаются серверами; неподдерживаемые типы (например, `trojan`, `shadowsocks`, `hysteria2`, `wireguard`) пропускаются и перечисляются в логе;
- при некорректном JSON существующие узлы подписки сохраняются;
- если в подписке нет ни одного VLESS-узла, это пишется в лог и не считается успешным импортом.

При обновлении подписки ручные узлы не изменяются, повторное обновление не создаёт дубликатов.

Параметры подписки:

| Параметр | Назначение |
|---|---|
| **Update only when connected** | автоматические обновления только при запущенном Easy VLESS (кнопка Update работает всегда) |
| **HWID Support** | отправлять HWID роутера, см. [HAPP / HWID](#happ--hwid) |
| **Spoof App** | User-Agent: Default (curl), HAPP или Custom |
| **Auto Update** / **Auto Update Delay** | периодическое обновление (cron) каждые 1–24 ч, пока Easy VLESS запущен |
| **Access method** | загрузка напрямую, через запущенный прокси или автоматически |
| **allowInsecure** | сохранять флаг allowInsecure импортированных узлов (по умолчанию выключено) |

---

## HAPP / HWID

Некоторые сервисы привязывают подписку к приложению или устройству. В таком случае можно использовать:

```text
Spoof App: HAPP
HWID Support: ON
```

Для HAPP используется заголовок `User-Agent: HAPP`. При включённом **HWID Support** добавляются заголовки `X-HWID`, `X-Device-OS`, `X-Ver-OS` и `X-Device-Model`.

Easy VLESS один раз генерирует стабильный HWID роутера и хранит его локально в `/etc/easy_vless/hwid`. HWID сохраняется между обновлениями пакета и перезагрузками.

> Не публикуйте свой HWID, subscription URL или другие приватные данные в документации и screenshots.

---

## Main

В разделе **Main** находятся статус сервиса (Core, Main switch, sing-box, Memory, Firewall), кнопки **Save & Start** / **Stop** / **Check config** и основные параметры.

Есть два основных режима.

### Весь трафик через один сервер

В поле **Node** выберите VLESS-сервер или URL Test Group. Весь трафик направляется через него.

### Раздельное туннелирование

Для работы с правилами из **Rule Manage** выберите в поле **Node**:

```text
Main Router (shunt)
```

После этого для каждого правила задаётся цель (Direct, VLESS-сервер или URL Test Group):

```text
RUSSIA
PROXY
QUIC
UDP
Default
```

**Default** — трафик, не подошедший ни под одно правило.

**Localhost Proxy** — трафик самого роутера тоже идёт через маршрутизацию Easy VLESS. **Client Proxy** — трафик LAN-устройств прозрачно перенаправляется (TPROXY) в Easy VLESS.

После изменения настроек нажмите **Save & Apply**. Для запуска — **Save & Start**.

Если запуск завершился ошибкой, проверьте выбранный Node, правила, **Recent log** и **Check config**.

---

## Connection Test (Server Test)

В нижней части **Main** находится **Connection test**; та же проверка доступна кнопкой **Test** в **Node List**.

Server Test запускает временный экземпляр sing-box с VLESS outbound сервера и выполняет реальный HTTPS-запрос к `https://www.gstatic.com/generate_204`, а не просто проверяет открытие TCP-порта. Проверка работает и при остановленном Easy VLESS и использует сохранённую конфигурацию.

![Connection Test](docs/images/connection-test.png)

Для дополнительной проверки после запуска можно открыть `2ip.io`, `speedtest.net` или другие реальные сайты.

---

## URL Test

URL Test проверяет задержку серверов по HTTP/HTTPS через работающий sing-box (Clash API). URL по умолчанию:

```text
https://x.com
```

URL Test работает с отдельными серверами и с URL Test Groups.

---

## Settings

В разделе **Settings** находятся дополнительные параметры DNS, Forwarding и sing-box.

### DNS

Direct DNS, Direct Query Strategy, Remote DNS Protocol, Remote DNS, Remote DNS EDNS Client Subnet, Remote DNS Outbound, FakeDNS, Remote Query Strategy, Domain Override, DNS Redirect.

![Settings DNS](docs/images/settings-dns.png)

### Forwarding

TCP No Redir Ports, UDP No Redir Ports, TCP Redir Ports, UDP Redir Ports, TCP Proxy Way, IPv6 TProxy (experimental), Hijacking ICMP.

### Advanced

Routing mode (только `singbox`), Log level, sing-box log, Clash API port, Node SOCKS port, Delay Start.

![Settings Forwarding](docs/images/settings-forwarding.png)

---

## Resources

Подготовленные ресурсы поставляются вместе с `easy-vless`, скачивать их вручную не нужно:

```text
/usr/share/easy_vless/resources/manifest.json
/usr/share/easy_vless/resources/domains/proxy.txt
/usr/share/easy_vless/resources/domains/russia.txt
```

Исходные списки лежат в [`reference/domains/`](reference/domains/). Файлы в пакете побайтно совпадают с ними. Это проверяется SHA-256 из `tests/resources.sha256` в static checks и при сборке пакета в CI.

---

## Packages и Dependencies

| Package | В релизе | Обязателен | Назначение |
|---|:---:|:---:|---|
| `easy-vless` | да | да | core runtime, скрипты, подготовленные ресурсы |
| `easy-vless-sing-box` | да | да | sing-box backend, URL Test, Clash API client |
| `luci-app-easy-vless` | да | да | LuCI-интерфейс и rpcd-плагин |
| `sing-box-tiny` | нет (официальный feed) | да | sing-box runtime >= 1.12.0 |
| `dnsmasq-full` | нет (официальный feed) | да | dnsmasq с nftset |
| `easy-vless-xray` | нет | нет | optional Xray backend |
| `easy-vless-geodata` | нет | нет | optional geoip/geosite data |

Зависимости из package metadata устанавливаются `opkg` автоматически из официальных репозиториев OpenWrt:

- `easy-vless`: `coreutils`, `coreutils-base64`, `coreutils-nohup`, `coreutils-timeout`, `curl`, `ip-full`, `libuci-lua`, `lua`, `luci-compat`, `luci-lib-jsonc`, `resolveip`, `nftables`, `kmod-nft-socket`, `kmod-nft-tproxy`, `kmod-nft-nat`, `openssl-util`, `lyaml`;
- `easy-vless-sing-box`: `easy-vless` и virtual package `sing-box` (его предоставляет `sing-box-tiny` или `sing-box`);
- `luci-app-easy-vless`: `easy-vless`, `luci-base`, `rpcd`.

Почему часть пакетов не указана в Depends:

- **sing-box** не входит в зависимости core: engine вынесен в `easy-vless-sing-box`, чтобы на роутер с маленькой flash ставился только один backend;
- **dnsmasq-full** нельзя указать зависимостью: он заменяет стандартный `dnsmasq`, а `opkg` не умеет выполнять такую замену через Depends. Поэтому `easy-vless` при запуске проверяет nftset, а `install.sh` предлагает замену явно (см. [dnsmasq](#dnsmasq)).

Optional packages собираются тем же workflow, но в релиз не публикуются. Их можно взять из артефакта `easy-vless-optional` GitHub Actions или [собрать](#build):

- `easy-vless-xray` — зависит от `xray-core` (официальный feed). Отдельного интерфейса для Xray нет, URL Test Groups работают только с sing-box;
- `easy-vless-geodata` — meta package: `geoview`, `v2ray-geoip`, `v2ray-geosite`. Нужен только для условий правил вида `geoip:` / `geosite:`; подготовленные правила RUSSIA/PROXY работают без него. `geoview` есть только в стороннем feed [openwrt-passwall-packages](https://github.com/xiaorouji/openwrt-passwall-packages), в официальных репозиториях OpenWrt его нет.

---

## Tested Hardware

Текущий подтверждённый тест:

```text
Device: Cudy TR3000 v1
OpenWrt: 24.10.3
Target: mediatek/filogic
Architecture: aarch64_cortex-a53
sing-box-tiny: 1.12.22
```

На этом устройстве при активном подключении наблюдалось примерно:

```text
RAM: ~150 MB
Storage: ~20 MB
```

Фактическое потребление зависит от устройства, OpenWrt и конфигурации и не гарантируется для других устройств.

---

## Known Limitations

- Поддерживается только протокол VLESS; узлы других типов в подписках пропускаются.
- Поддерживается только OpenWrt 24.10.x с `opkg`; OpenWrt с `apk` не поддерживается.
- Нужен `dnsmasq-full` (nftset); без него сервис не запускается.
- JSON-подписки (sing-box JSON) в 0.5.1 — **experimental**. Их покрывают автоматические тесты на подготовленных примерах, но с реальными провайдерами они проверены мало.
- Clash YAML подписки не покрыты автоматическими тестами репозитория.
- Routing mode — только `singbox`; режим dnsmasq → nftset не реализован.
- Xray не имеет отдельного интерфейса. Если установлен `xray-core`, новые импортированные VLESS-ссылки могут создаваться как Xray-узлы.
- Geodata (`geoip:` / `geosite:`) требует optional `easy-vless-geodata` со сторонним `geoview`.
- IPv6 TProxy — experimental.
- Экспорта/импорта всей конфигурации нет (VLESS URL отдельного сервера копируется кнопкой **Copy**).
- Мастера первоначальной настройки (Wizard) нет.

---

## Tests

| Тест | Где выполняется | Что проверяет |
|---|---|---|
| [`tests/static-checks.sh`](tests/static-checks.sh) | CI job `checks`, локально | синтаксис shell/Lua/JS/JSON, ресурсы, screenshots, README/LICENSE, package metadata, поиск локальных путей и секретов |
| [`tests/dnsmasq-nftset-test.sh`](tests/dnsmasq-nftset-test.sh) | static checks | определение nftset по `dnsmasq --version` |
| [`tests/subscription-formats-test.sh`](tests/subscription-formats-test.sh) | CI job `runtime-tests`, роутер | 52 проверки форматов подписок: VLESS URL, списки plain/base64, sing-box JSON, JSON-массив, base64 JSON, неподдерживаемые outbounds, некорректный JSON, ноль VLESS-узлов, отсутствие дубликатов, сохранность ручных узлов, фильтрация чужой конфигурации |
| [`tests/ci/openwrt-runtime-tests.sh`](tests/ci/openwrt-runtime-tests.sh) | CI job `runtime-tests` | в контейнере `openwrt/rootfs:x86-64-24.10.3`: ubusd и rpcd (без procd), `install.sh --check`, установка собранных пакетов через `install.sh --local` (sing-box-tiny из feed, замена dnsmasq на dnsmasq-full, проверка SHA256SUMS), затем subscription tests |
| [`tests/tr3000-slice-smoke.sh`](tests/tr3000-slice-smoke.sh) | вручную на роутере | запуск/остановка сервиса, nftables, ip rule, процессы sing-box; с таймером отката |

Локально:

```sh
bash tests/static-checks.sh
```

---

## Build

Пакеты собираются официальным OpenWrt SDK. Эталонная сборка — GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)): OpenWrt 24.10.3 SDK для mediatek/filogic. Все пакеты имеют архитектуру `all`, поэтому подходят для любой архитектуры OpenWrt 24.10.

Ручная сборка в распакованном OpenWrt 24.10.3 SDK:

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

`make -C package/easy-vless` собирает только пакеты Easy VLESS и не компилирует sing-box, xray-core и другие зависимости: они нужны только как metadata для Depends. `easy-vless-geodata` собирается, только если подключён feed с `geoview` (в CI — `openwrt-passwall-packages` на фиксированном commit).

CI jobs:

- `checks` — static checks;
- `build` — сборка всех пакетов, проверка содержимого и зависимостей каждого `.ipk`, `dist/` с `SHA256SUMS`;
- `runtime-tests` — installer и subscription tests в OpenWrt 24.10.3 rootfs;
- `release` — только для тегов `v*`, после успешных `checks`, `build` и `runtime-tests`: draft GitHub Release с файлами из `dist/`.

---

## Upstream

Easy VLESS основан на архитектурных и технических компонентах PassWall2.

Upstream: https://github.com/Openwrt-Passwall/openwrt-passwall2

Исходная база:

```text
PassWall2 25.5.15-1
commit 394f3842969161ddd888187e72db4b493b3310b4
```

Оригинальные copyright и license notices сохраняются в исходных файлах.

---

## License

GPL-3.0-only. Полный текст лицензии: [LICENSE](LICENSE).
