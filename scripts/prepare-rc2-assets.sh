#!/bin/sh
# Assemble rc.2 from production-signed rc.1 packages. Sign only the new manifest.
set -eu
umask 077
source_dir=${1:?usage: prepare-rc2-assets.sh SIGNED_RC1_DIR DNS_ARCHIVE NEW_DIR PRIVATE_KEY}
dns=${2:?missing DNS archive directory}
out=${3:?missing output directory}
key=${4:?missing signing key}
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fingerprint=1ace0d12040968ea2bea4ed56479b05be5f4c331ce8b2e7aee31a272fb3d875b
[ -f "$key" ] && [ ! -L "$key" ]
key=$(realpath "$key")
case "$key" in "$root"/*) echo "keep the production key outside the repository" >&2; exit 2 ;; esac
case "$(stat -c '%u:%a' "$key")" in "$(id -u):600"|"$(id -u):400") ;; *) exit 2 ;; esac
[ ! -e "$out" ] && [ ! -L "$out" ]
sh "$root/scripts/verify-release-assets.sh" "$source_dir" "$fingerprint" >/dev/null
tmp=$(mktemp -d "$(dirname "$out")/.rc2.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
for p in easy-vless easy-vless-sing-box easy-vless-xray easy-vless-geodata luci-app-easy-vless; do
	cp "$source_dir/$p-1.3.0-r1.apk" "$source_dir/${p}_1.3.0-r1_all.ipk" "$tmp/"
done
for arch in aarch64_cortex-a53 x86_64; do
	cp "$source_dir/sing-box-lx-1.14.4_p35-r1-$arch.apk" "$source_dir/sing-box-lx_1.14.4_p35-r1_$arch.ipk" "$tmp/"
done
cp "$source_dir/easy-vless-release.pem" "$source_dir/sing-box-lx-1.14.4-lx.35-source.tar.gz" "$tmp/"
cp "$dns/dnsmasq-2.93-r1.apk" "$tmp/rollback-tr3000-25.12.6-2.93-r1.apk"
cp "$dns/packages.adb" "$tmp/rollback-tr3000-25.12.6-2.93-r1.adb"
(cd "$tmp" && LC_ALL=C sha256sum *.apk *.ipk *.pem *.adb | LC_ALL=C sort -k2 > PACKAGES.sha256)
expected=$(sed -n 's/^EV_PACKAGE_MANIFEST_SHA256="\([a-f0-9]*\)"$/\1/p' "$root/scripts/install.sh")
printf '%s  %s\n' "$expected" "$tmp/PACKAGES.sha256" | sha256sum -c -
cp "$root/scripts/install.sh" "$root/scripts/install-from-pc.sh" "$tmp/"
cp "$root/docs/INSTALL-1.3.0-RC2.md" "$tmp/INSTALL-RC.md"
sed 's/v1\.3\.0-rc\.1/v1.3.0-rc.2/g' "$root/docs/THIRD-PARTY-RC.md" > "$tmp/THIRD-PARTY.md"
printf '\nРезервный dnsmasq 2.93-r1 (GPL-2.0) соответствует неизменяемой прошивке OpenWrt 25.12.6 для Cudy TR3000 v1. Рецепт и патчи доступны в [исходниках OpenWrt 25.12.6](https://github.com/openwrt/openwrt/tree/v25.12.6/package/network/services/dnsmasq).\n' >> "$tmp/THIRD-PARTY.md"
printf '%s\n' '# Easy VLESS v1.3.0-rc.2' '' 'Исправлен установщик. Пакеты приложения и ядра совпадают с rc.1. Инструкция и ограничения приведены в INSTALL-RC.md.' > "$tmp/RELEASE-NOTES.md"
(
	cd "$tmp"
	LC_ALL=C sha256sum * > SHA256SUMS
	openssl dgst -sha256 -sign "$key" -out SHA256SUMS.sig SHA256SUMS
)
sh "$root/scripts/verify-release-assets.sh" "$tmp" "$fingerprint" >/dev/null
mv -T --no-clobber "$tmp" "$out"
[ ! -e "$tmp" ]
