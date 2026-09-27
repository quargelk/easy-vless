# Easy VLESS

Лёгкий VLESS-клиент для OpenWrt с интерфейсом LuCI.

Easy VLESS использует sing-box для работы с VLESS и поддерживает прозрачное проксирование, Reality, раздельное туннелирование, подписки, HAPP/HWID и URL Test.

**Текущая версия: 0.5.1-r1**

Проект тестировался на **Cudy TR3000 v1** с **OpenWrt 24.10.3**.

> Потребление ресурсов зависит от устройства и конфигурации. На тестовом Cudy TR3000 при активном подключении наблюдалось около **150 МБ RAM** и около **20 МБ хранилища**. Это не является гарантированным потреблением для других устройств.

## Возможности

- VLESS
- TLS / Reality / uTLS
- TCP / WebSocket / gRPC / HTTPUpgrade
- TPROXY
- nftables / fw4
- DNS, FakeDNS и DNS Redirect
- Раздельное туннелирование
- Подготовленные правила маршрутизации
- Импорт VLESS URL
- Подписки
- HAPP
- HWID
- URL Test
- Connection Test
- LuCI-интерфейс

## Установка

### Требования

Основные компоненты:

- `easy-vless`
- `easy-vless-sing-box`
- `luci-app-easy-vless`
- `sing-box-tiny`

Easy VLESS использует **sing-box-tiny** как основной runtime.

`easy-vless-sing-box` зависит от виртуального пакета `sing-box`, который предоставляет `sing-box-tiny`.

Не устанавливайте одновременно `sing-box` и `sing-box-tiny`: они предоставляют один и тот же virtual package `sing-box`.

Также нужен `dnsmasq` с поддержкой nftset (`dnsmasq-full`), см. раздел [dnsmasq](#dnsmasq).

### Установка через installer

Релиз содержит `install.sh` — обычный shell-скрипт, который можно прочитать перед запуском:

```sh
wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v0.5.1/install.sh
sh /tmp/install.sh --check
sh /tmp/install.sh
```

`--check` только проверяет роутер и ничего не устанавливает.

Установщик:

- определяет OpenWrt;
- определяет архитектуру;
- проверяет совместимость (OpenWrt 24.10.x с `opkg`, fw4/nftables, свободное место, остановленный PassWall2);
- устанавливает необходимые зависимости через `opkg`;
- устанавливает `sing-box-tiny` из официального репозитория пакетов OpenWrt для архитектуры роутера;
- устанавливает пакеты Easy VLESS, предварительно проверив их по `SHA256SUMS` релиза;
- включает автозапуск;
- запускает сервис, если это необходимо (перезапуск выполняется, только если Main switch уже включён);
- проверяет итоговое состояние.

Установщик не удаляет существующую конфигурацию Easy VLESS (`/etc/config/easy_vless`).

Дополнительные параметры:

| Параметр | Назначение |
|---|---|
| `--local <dir>` | установить пакеты Easy VLESS и `SHA256SUMS` из директории с загруженными файлами релиза |
| `--replace-dnsmasq` | разрешить замену `dnsmasq` на `dnsmasq-full` (см. [dnsmasq](#dnsmasq)) |
| `--bootstrap-opkg` | разрешить установку `opkg`, если он отсутствует (только OpenWrt 24.10.x) |
| `--no-start` | не перезапускать сервис в конце |

### Ручная установка

Файлы релиза должны находиться в одной директории на роутере. Перейдите в директорию с загруженными файлами релиза.

Сначала при необходимости выполните bootstrap `opkg`.

Для **OpenWrt 24.10.3 / aarch64_cortex-a53**:

```sh
wget https://archive.openwrt.org/releases/24.10.3/packages/aarch64_cortex-a53/base/opkg_2024.10.16~38eccbb1-r1_aarch64_cortex-a53.ipk
tar -xvzf opkg_*.ipk
tar -xzf data.tar.gz -C /
```

После этого:

```sh
opkg update
opkg install sing-box-tiny
```

Затем установите Easy VLESS:

```sh
opkg install ./easy-vless_0.5.1-r1_all.ipk
opkg install ./easy-vless-sing-box_0.5.1-r1_all.ipk
opkg install ./luci-app-easy-vless_0.5.1-r1_all.ipk
```

После установки откройте:

**LuCI → Services → Easy VLESS**

> Bootstrap `opkg` выше относится к конкретной версии OpenWrt и архитектуре `aarch64_cortex-a53`. Не используйте эту ссылку как универсальную для других версий или архитектур. `install.sh --bootstrap-opkg` берёт пакет `opkg` для версии и архитектуры самого роутера и проверяет его контрольную сумму по индексу репозитория.

### dnsmasq

Easy VLESS проверяет фактическую поддержку nftset в `dnsmasq`.

Проверка основана на:

```sh
dnsmasq --version
```

и фактических Compile time options, а не просто на:

```sh
dnsmasq --help
```

Опция `--nftset` есть в `dnsmasq --help` любой сборки, поэтому учитываются только Compile time options:

- `nftset` — поддержка есть, ничего менять не нужно;
- `no-nftset` — обычный `dnsmasq` без nftset: нужен `dnsmasq-full`. Без него Easy VLESS не запускается и сообщает об этом в логе.

```sh
dnsmasq --version | grep 'Compile time options'
```

Easy VLESS не заменяет системный `dnsmasq` самостоятельно. Если замена нужна, `install.sh` сначала показывает, что будет сделано, и выполняет её только после подтверждения (или с параметром `--replace-dnsmasq`): зависимости и пакеты скачиваются заранее, `/etc/config/dhcp` сохраняется, а при ошибке установки `dnsmasq-full` возвращается прежний `dnsmasq`. На время перезапуска `dnsmasq` DHCP/DNS на роутере кратко недоступны.

Не заменяйте системный `dnsmasq` без необходимости.

## Первоначальная настройка

Если вы используете раздельное туннелирование, сначала откройте:

**Rule Manage**

Затем:

**Node List**

После добавления сервера настройте:

**Main**

Дополнительные параметры находятся в:

**Settings**

---

## Rule Manage

Раздел **Rule Manage** используется для раздельного туннелирования.

Рядом с кнопкой **Add rule** находится список подготовленных правил.

Выберите нужное правило и нажмите:

**Add prepared rule**

Подготовленные ресурсы уже загружены в Easy VLESS.

Доступны категории:

- **RUSSIA**
- **PROXY**
- **QUIC**
- **UDP**

Порядок правил имеет значение.

Для изменения существующего правила нажмите **Edit**.

Через:

**+ Add condition**

можно добавить собственные условия, например домены.

Ручные условия рекомендуется использовать тогда, когда подготовленных правил недостаточно или конкретный ресурс работает неправильно.

![Rule Manage](docs/images/rule-manage.png)

---

## Node List

В **Node List** добавляются VLESS-серверы и подписки.

Доступны:

- Import VLESS URL
- Add VLESS
- Add subscription
- Use
- Test
- URL Test
- Copy
- Edit
- Delete
- управление подписками
- URL Test Groups

![Node List](docs/images/node-list.png)

### Добавление VLESS

Нажмите:

**Import VLESS URL**

Вставьте VLESS-ссылку и выполните импорт.

После добавления нажмите:

**Save & Apply**

### Добавление подписки

Нажмите:

**Add subscription**

![Add Subscription](docs/images/add-subscription.png)

В поле **Name** укажите любое название.

В поле **Subscription URL** вставьте ссылку на подписку.

Например, ссылку, полученную от VPN-сервиса или Telegram-бота.

После сохранения нажмите:

**Save & Apply**

Для некоторых сервисов при первом добавлении необходимо временно отключить VPN, чтобы запрос к серверу подписки не проходил через другой туннель.

---

## HAPP / HWID

Некоторые сервисы привязывают подписку к приложению или устройству.

В таком случае можно использовать:

```text
Spoof App: HAPP
HWID Support: ON
```

Easy VLESS генерирует стабильный HWID для роутера и передаёт его при обновлении подписки.

Для HAPP используется заголовок `User-Agent: HAPP`; при включённом **HWID Support** добавляются заголовки `X-HWID`, `X-Device-OS`, `X-Ver-OS` и `X-Device-Model`.

HWID хранится локально на роутере (`/etc/easy_vless/hwid`) и сохраняется между обновлениями конфигурации и перезагрузками.

> Не публикуйте свой HWID, subscription URL или другие приватные данные в документации и screenshots.

---

## Main

В разделе **Main** настраивается работа Easy VLESS.

![Main](docs/images/main.png)

Есть два основных режима.

### Весь трафик через один сервер

В поле **Node** выберите нужный VLESS-сервер.

В этом режиме трафик направляется через выбранный сервер.

### Раздельное туннелирование

Для работы с правилами из **Rule Manage** выберите:

```text
Main Router (shunt)
```

После этого для категорий задаются соответствующие цели:

```text
RUSSIA
PROXY
QUIC
UDP
Default
```

Для каждой категории можно выбрать VLESS-сервер или соответствующую группу.

После изменения настроек нажмите:

**Save & Apply**

Для запуска:

**Save & Start**

Если запуск завершился ошибкой, проверьте выбранный Node, правила и статус sing-box.

---

## Connection Test

В нижней части **Main** находится **Connection Test**.

После добавления сервера можно выполнить **Test**.

Проверка выполняет реальный HTTPS-запрос через VLESS, а не просто проверяет открытие TCP-порта.

Это позволяет проверить именно доступность внешнего ресурса через сервер.

![Connection Test](docs/images/connection-test.png)

Для дополнительной проверки после запуска можно использовать:

- `2ip.io`
- `speedtest.net`
- другие реальные сайты.

---

## URL Test

URL Test используется для проверки серверов по HTTP/HTTPS и сравнения задержки.

URL по умолчанию:

```text
https://x.com
```

URL Test работает с отдельными серверами и URL Test Groups.

---

## Settings

В разделе **Settings** находятся дополнительные параметры DNS, Forwarding и sing-box.

### DNS

Доступны:

- Direct DNS
- Direct Query Strategy
- Remote DNS Protocol
- Remote DNS
- Remote DNS EDNS Client Subnet
- Remote DNS Outbound
- FakeDNS
- Remote Query Strategy
- Domain Override
- DNS Redirect

![Settings DNS](docs/images/settings-dns.png)

### Forwarding

Доступны:

- TCP No Redir Ports
- UDP No Redir Ports
- TCP Redir Ports
- UDP Redir Ports
- TCP Proxy Way
- IPv6 TProxy
- Hijacking ICMP

![Settings Forwarding](docs/images/settings-forwarding.png)

### Advanced

Доступны:

- Routing mode
- Log level
- sing-box log
- Clash API port
- Node SOCKS port
- Delay Start

---

## Resources

Подготовленные ресурсы уже поставляются вместе с `easy-vless`.

В пакет входят:

```text
/usr/share/easy_vless/resources/manifest.json
/usr/share/easy_vless/resources/domains/proxy.txt
/usr/share/easy_vless/resources/domains/russia.txt
```

Исходные файлы находятся в:

```text
reference/domains/
```

Пользователю не требуется скачивать эти списки вручную.

---

## Dependencies

Основные компоненты:

| Package | Required | Purpose |
|---|:---:|---|
| `easy-vless` | Yes | Core runtime and resources |
| `easy-vless-sing-box` | Yes | sing-box backend integration |
| `luci-app-easy-vless` | Yes | LuCI interface |
| `sing-box-tiny` | Yes | sing-box runtime |

Optional:

| Package | Required | Purpose |
|---|:---:|---|
| `easy-vless-xray` | No | Optional Xray backend |
| `easy-vless-geodata` | No | Optional geodata support |

Системные зависимости OpenWrt устанавливаются через `opkg` согласно package metadata:

- `easy-vless`: `coreutils`, `coreutils-base64`, `coreutils-nohup`, `coreutils-timeout`, `curl`, `ip-full`, `libuci-lua`, `lua`, `luci-compat`, `luci-lib-jsonc`, `resolveip`, `nftables`, `kmod-nft-socket`, `kmod-nft-tproxy`, `kmod-nft-nat`, `openssl-util`, `lyaml`;
- `easy-vless-sing-box`: `easy-vless` и virtual package `sing-box` (`sing-box-tiny`);
- `luci-app-easy-vless`: `easy-vless`, `luci-base`, `rpcd`.

`dnsmasq-full` нельзя указать как зависимость пакета (он заменяет стандартный `dnsmasq`), поэтому он устанавливается отдельно — см. [dnsmasq](#dnsmasq).

`easy-vless-geodata` требует `geoview`, которого нет в официальных репозиториях OpenWrt.

---

## Tested Hardware

Текущий подтверждённый тест:

```text
Device: Cudy TR3000 v1
OpenWrt: 24.10.3
Target: mediatek/filogic
Architecture: aarch64_cortex-a53
```

На этом устройстве при активном подключении наблюдалось примерно:

```text
RAM: ~150 MB
Storage: ~20 MB
```

Фактическое потребление зависит от устройства, OpenWrt и конфигурации.

---

## Known Limitations

- JSON subscription support в версии 0.5.1 является экспериментальным и не считается полностью проверенным.
- Xray не имеет отдельного полноценного интерфейса в Easy VLESS.
- Geodata не является обязательным для подготовленных правил RUSSIA/PROXY.
- nftset mode не входит в текущий пользовательский режим маршрутизации.
- Export config не входит в текущий интерфейс.
- Wizard первоначальной настройки отсутствует.

---

## Build

Проект собирается через OpenWrt SDK (OpenWrt 24.10.3, mediatek/filogic).

GitHub Actions выполняет автоматическую сборку и проверки (`.github/workflows/build.yml`).

Основные пакеты:

```text
easy-vless
easy-vless-sing-box
luci-app-easy-vless
```

Release build также создаёт:

```text
SHA256SUMS
```

---

## Upstream

Easy VLESS основан на архитектурных и технических компонентах PassWall2.

Upstream:

https://github.com/Openwrt-Passwall/openwrt-passwall2

Исходная база:

```text
PassWall2 25.5.15-1
commit 394f3842969161ddd888187e72db4b493b3310b4
```

Оригинальные copyright и license notices сохраняются в исходных файлах.

---

## License

GPL-3.0-only. Полный текст лицензии: [LICENSE](LICENSE).
