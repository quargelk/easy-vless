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

Владелец выпуска создаёт ключ на подписывающей машине в приватном каталоге
на зашифрованном носителе или в другом утверждённом хранилище. Резервная
копия ключа также шифруется. Для `apk adbsign` используется доступный
процессу подписания RSA PEM с правами `0600` или `0400`. Если ключ
хранится зашифрованным отдельно, распакуйте его только на время подписания
в защищённый каталог на зашифрованном томе или в приватный tmpfs.

```sh
umask 077
keydir=/path/to/encrypted-storage/easy-vless
install -d -m 0700 "$keydir"
( set -C
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 > "$keydir/production.rsa"
) || exit 1
openssl pkey -in "$keydir/production.rsa" -pubout -outform DER -out "$keydir/public.der" || exit 1
sha256sum "$keydir/public.der"
```

Зафиксируйте отпечаток DER SubjectPublicKeyInfo у владельца выпуска и
передайте его установщикам по отдельно проверенному каналу. При ротации
сначала распространите и проверьте новый отпечаток. Приватный PEM
остаётся в хранилище. Для следующих выпусков используется тот же
подтверждённый ключ до согласованной ротации.

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
