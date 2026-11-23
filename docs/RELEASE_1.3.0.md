# Подготовка Easy VLESS v1.3.0-rc.1

Тег кандидата `v1.3.0-rc.1` использует готовые пакеты Easy VLESS
`1.3.0-r1` и `sing-box-lx 1.14.4_p35-r1`. Git-тег описывает стадию
выпуска. OpenWrt сравнивает пакетные версии. Если содержимое пакета
изменится после RC, увеличьте ревизию соответствующего пакета перед
выпуском. Тег `v1.3.0` создаётся после испытаний.

## Подготовка исходников и пакетов

`dist/sing-box-lx-integration/` содержит проверяемые сборки для четырёх
сочетаний формата и ABI. Из исходного комплекта сохраняются пакеты.
Установщик и документы берутся из рабочего дерева.

```sh
git clone --depth 1 --branch v1.14.4-lx.35 https://github.com/Leadaxe/sing-box-lx /path/to/core-checkout
git -C /path/to/core-checkout submodule update --init --depth 1 \
  submodules/gvisor submodules/sing-tun submodules/utls submodules/wireguard-go
bash scripts/prepare-core-source.sh /path/to/core-checkout /path/to/core-source.tar.gz
sh scripts/prepare-release-assets.sh dist/sing-box-lx-integration \
  dist/release-assets-v1.3.0-rc.1-staged /path/to/core-source.tar.gz
(cd dist/release-assets-v1.3.0-rc.1-staged && sha256sum -c SHA256SUMS)
```

Комплект после подписи содержит 7 IPK, 7 APK, `install.sh`,
`INSTALL-RC.md`, `RELEASE-NOTES.md`, `THIRD-PARTY.md`,
соответствующие исходники ядра, `easy-vless-release.pem`, `SHA256SUMS`
и `SHA256SUMS.sig`. Резервные копии роутера, его конфигурация и тестовые
подписанные комплекты хранятся отдельно.

## Постоянный ключ

Ключ RC — RSA-3072 в постоянной коллекции `login` GNOME Keyring
на машине сопровождающего. Публичный отпечаток SHA-256
DER SubjectPublicKeyInfo зафиксирован ниже.

```text
1ace0d12040968ea2bea4ed56479b05be5f4c331ce8b2e7aee31a272fb3d875b
```

Владелец выпуска передаёт отпечаток установщикам по отдельно проверенному
каналу. Для будущих выпусков используется та же запись Secret Service.
При подписании сохраните закрытый PEM только в приватный tmpfs.

```sh
umask 077
keydir=$(mktemp -d /tmp/easy-vless-sign.XXXXXX) || exit 1
trap 'rm -rf "$keydir"' EXIT
secret-tool lookup project quargelk/easy-vless purpose apk-production-signing-v1 \
  > "$keydir/production.rsa" || exit 1
test -s "$keydir/production.rsa" || exit 1
fingerprint=1ace0d12040968ea2bea4ed56479b05be5f4c331ce8b2e7aee31a272fb3d875b
openssl pkey -in "$keydir/production.rsa" -pubout -outform DER -out "$keydir/public.der" || exit 1
printf '%s  %s\n' "$fingerprint" "$keydir/public.der" | sha256sum -c - || exit 1
```

Резервная копия ключа хранится только в защищённом хранилище
владельца выпуска. При ротации заранее распространите новый отпечаток.

## Подписать и проверить

```sh
APK_TOOL=/path/to/openwrt-25.12.6-sdk/staging_dir/host/bin/apk \
  sh scripts/sign-release-apks.sh dist/release-assets-v1.3.0-rc.1-staged \
  dist/release-assets-v1.3.0-rc.1-signed "$keydir/production.rsa"
sh scripts/verify-release-assets.sh dist/release-assets-v1.3.0-rc.1-signed "$fingerprint"
```

Помощник подписывает APK локально, проверяет каждый APK с отдельным
trust root и выпускает подписанный манифест для обоих форматов.
Процедура проверки и установки изложена в
[инструкции RC](INSTALL-1.3.0-RC.md). Тест с одноразовой парой и
повреждёнными файлами запускается отдельно.

```sh
sh tests/release-signing-test.sh /path/to/host/apk dist/release-assets-v1.3.0-rc.1-staged
```

Затем повторите `--check` и установку подписанного производственного
набора в чистом OpenWrt 25.12.6. Сверьте версии, целостность конфигурации и
ожидаемый отпечаток ключа. Сохраните точный подписанный комплект для выпуска.
GitHub Actions собирает пакеты для CI и подписывает тестовые APK
одноразовым ключом. Workflow имеет `contents: read`. Публикация
использует только проверенный локальный комплект после отдельного
согласования. В GitHub отметьте выпуск как prerelease, затем сверьте
публичные файлы по подписанному манифесту.
