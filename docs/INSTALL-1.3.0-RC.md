# Проверка, установка и восстановление Easy VLESS v1.3.0-rc.1

## Проверка комплекта на ПК

Получите у сопровождающего по заранее доверенному каналу SHA-256
отпечаток публичного ключа выпуска. На ПК с curl и OpenSSL скачайте
установщик, ключ и подписанный манифест в новый каталог.

```sh
mkdir -m 700 easy-vless-rc1 && cd easy-vless-rc1 || exit 1
base=https://github.com/quargelk/easy-vless/releases/download/v1.3.0-rc.1
for f in install.sh SHA256SUMS SHA256SUMS.sig easy-vless-release.pem; do
  curl -fsSL --proto '=https' --proto-redir '=https' "$base/$f" -o "$f" || exit 1
done

fingerprint=отпечаток_из_доверенного_канала
openssl pkey -pubin -in easy-vless-release.pem -outform DER -out release-key.der || exit 1
printf '%s  %s\n' "$fingerprint" release-key.der | sha256sum -c - || exit 1
openssl dgst -sha256 -verify easy-vless-release.pem -signature SHA256SUMS.sig SHA256SUMS || exit 1
awk '$2 == "install.sh" { installer++; print }
     $2 == "easy-vless-release.pem" { key++; print }
     END { if (installer != 1 || key != 1) exit 1 }' SHA256SUMS > bootstrap.sha256 || exit 1
sha256sum -c bootstrap.sha256 || exit 1
sha256sum SHA256SUMS | cut -d ' ' -f1 > manifest.sha256
```

Для проверки всех скачанных assets используйте
`scripts/verify-release-assets.sh` из доверенной копии репозитория.
Перенесите проверенный установщик и `manifest.sha256` на роутер
по SSH с проверенным ключом хоста. Для стандартного OpenWrt с Dropbear
используйте SCP в режиме `-O`.

```sh
scp -O -o StrictHostKeyChecking=yes install.sh manifest.sha256 root@192.168.10.1:/tmp/
```

Для OpenWrt 25.12.x перенесите тот же проверенный PEM с ПК.

```sh
scp -O -o StrictHostKeyChecking=yes easy-vless-release.pem root@192.168.10.1:/tmp/
```

На роутере от имени root
проверьте, что имя ключа свободно или уже занято идентичным файлом, затем
добавьте его отдельным файлом.

```sh
key=/etc/apk/keys/easy-vless-release.pem
if [ -e "$key" ] || [ -L "$key" ]; then
  [ ! -L "$key" ] && cmp -s /tmp/easy-vless-release.pem "$key" || exit 1
else
  (umask 022; set -C; cat /tmp/easy-vless-release.pem > "$key") || exit 1
fi
```

## Предварительная проверка

Параметр `--manifest-sha256` получает хеш манифеста из проверки на ПК.
Для загрузки с GitHub или с доверенного HTTPS-зеркала используйте

```sh
pin=$(cat /tmp/manifest.sha256)
sh /tmp/install.sh --check --no-mirror --manifest-sha256 "$pin"
sh /tmp/install.sh --check --manifest-sha256 "$pin" --base-url https://mirror.example/easy-vless/v1.3.0-rc.1
```

Для офлайн-установки перенесите файлы комплекта для своей архитектуры
и `SHA256SUMS` в локальный каталог. Зависимости уже должны быть установлены,
в том числе `dnsmasq` с поддержкой `nftset`. При обновлении и онлайн,
и офлайн передайте проверенные предыдущие пакеты через `--rollback-dir`.
Для 1.2.0 скачайте пакеты своего формата заранее из опубликованного
релиза и перенесите их на роутер. Установщик сверит каждый файл отката
с зафиксированной суммой релиза 1.2.0.

```sh
sh /tmp/install.sh --check --manifest-sha256 "$pin" --local /tmp/ev-rc --offline
```

После успешной проверки и подготовки резервной копии повторите выбранную
команду без `--check`. Оставьте `--no-start`, если запуск службы сначала
нужно проверить вручную. Для обычного `dnsmasq` онлайн-проверка должна
подтвердить доступность точной прежней версии из подписанного индекса.
Архив такой версии подаётся через `--dnsmasq-rollback-dir DIR`. Для TR3000
порядок подготовки локального индекса по проверенной базе ROM описан в
`docs/TR3000_LIVE_TRIAL.md` репозитория. Проверьте
переключение DNS/DHCP с отдельного LAN-клиента и сохраните доступ по SSH.

Пример для TR3000 в исходном состоянии с обычным `dnsmasq 2.93-r1`.
Каталог `/tmp/dnsmasq-rollback` должен содержать проверенные
`packages.adb` и `dnsmasq-2.93-r1.apk`. Выполните подготовку
восстановления до второй команды.

```sh
pin=$(cat /tmp/manifest.sha256)
sh /tmp/install.sh --check --no-mirror --manifest-sha256 "$pin" \
  --dnsmasq-rollback-dir /tmp/dnsmasq-rollback
sh /tmp/install.sh --no-start --replace-dnsmasq --no-mirror --manifest-sha256 "$pin" \
  --dnsmasq-rollback-dir /tmp/dnsmasq-rollback
```

## Восстановление

До установки сохраните на ПК закрытую копию конфигурации, список пакетов
и версий, состояния служб и world APK. Держите доступным точный комплект
предыдущих пакетов. Если установщик сообщает об откате, дождитесь его
завершения и проверьте версии, UCI, новый вход SSH, DNS и DHCP. Сообщение
о неполном восстановлении содержит каталог сохранённых файлов в `/tmp`.
Скопируйте его в защищённое место до перезагрузки.

Для испытания на TR3000 заранее подготовьте локальный сценарий отката
и автономный watchdog по инструкции в `docs/TR3000_LIVE_TRIAL.md`
репозитория. Проверка сохранения конфигурации после перезагрузки проводится
на отдельном этапе с проверенным способом входа и восстановления.
