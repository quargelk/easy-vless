#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
sh "$ROOT/scripts/prepare-release-assets.sh" \
	"$ROOT/dist/sing-box-lx-integration" "$OUT/assets"
(cd "$OUT/assets" && sha256sum -c SHA256SUMS >/dev/null)
for f in \
	install.sh \
	sing-box-lx_1.14.4_p35-r1_x86_64.ipk \
	sing-box-lx_1.14.4_p35-r1_aarch64_cortex-a53.ipk \
	sing-box-lx-1.14.4_p35-r1-x86_64.apk \
	sing-box-lx-1.14.4_p35-r1-aarch64_cortex-a53.apk \
	easy-vless_1.3.0-r1_all.ipk \
	easy-vless-1.3.0-r1.apk \
	luci-app-easy-vless_1.3.0-r1_all.ipk \
	luci-app-easy-vless-1.3.0-r1.apk; do
	[ -s "$OUT/assets/$f" ] || { echo "missing release asset: $f" >&2; exit 1; }
done
grep -q 'EV_VERSION="1.3.0-r1"' "$OUT/assets/install.sh"
grep -Fxq 'EV_TAG="v1.3.0-rc.2"' "$OUT/assets/install.sh"
echo "release asset tests passed"
