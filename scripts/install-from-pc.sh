#!/bin/sh
# Download one verified RC bundle and run its installer over authenticated SSH.
set -eu
umask 077
tag=v1.3.0-rc.2
base="https://github.com/quargelk/easy-vless/releases/download/$tag"
fingerprint=1ace0d12040968ea2bea4ed56479b05be5f4c331ce8b2e7aee31a272fb3d875b
host=${1:?usage: install-from-pc.sh root@ROUTER [--check] [--base-url HTTPS_URL]}
shift
check=
while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) check=--check ;;
		--base-url) [ "$#" -ge 2 ]; base=${2%/}; shift ;;
		*) echo "unsupported option: $1" >&2; exit 2 ;;
	esac
	shift
done
case "$base" in https://?*) ;; *) echo "HTTPS release URL required" >&2; exit 2 ;; esac
case "$host" in -*) exit 2 ;; esac
router() { ssh -o StrictHostKeyChecking=yes -- "$host" "$@"; }
work=$(mktemp -d)
remote=
cleanup() {
	if [ -n "$remote" ]; then router "rm -rf '$remote'" >/dev/null 2>&1 || :; fi
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

router '. /etc/openwrt_release; printf "%s %s\n" "$DISTRIB_RELEASE" "$DISTRIB_ARCH"' > "$work/target"
read -r release arch < "$work/target"
case "$arch" in x86_64|aarch64_cortex-a53) ;; *) echo "unsupported architecture" >&2; exit 1 ;; esac
case "$release" in 24.10.[0-9]*) format=ipk ;; 25.12.[0-9]*) format=apk ;; *) echo "unsupported OpenWrt release" >&2; exit 1 ;; esac
mkdir "$work/files"
cd "$work/files"
get() { curl -fsSL --retry 2 --proto '=https' --proto-redir '=https' "$base/$1" -o "$1"; }
for f in SHA256SUMS SHA256SUMS.sig easy-vless-release.pem; do get "$f"; done
openssl pkey -pubin -in easy-vless-release.pem -outform DER -out "$work/key.der"
printf '%s  %s\n' "$fingerprint" "$work/key.der" | sha256sum -c -
openssl dgst -sha256 -verify easy-vless-release.pem -signature SHA256SUMS.sig SHA256SUMS
verified_file() {
	get "$1"
	awk -v name="$1" '$2 == name { print; n++ } END { if (n != 1) exit 1 }' SHA256SUMS > "$work/one"
	sha256sum -c "$work/one"
}
verified_file easy-vless-release.pem
verified_file install.sh
verified_file PACKAGES.sha256
for package in sing-box-lx easy-vless easy-vless-sing-box luci-app-easy-vless; do
	case "$format:$package" in
		apk:sing-box-lx) file="$package-1.14.4_p35-r1-$arch.apk" ;;
		ipk:sing-box-lx) file="${package}_1.14.4_p35-r1_$arch.ipk" ;;
		apk:*) file="$package-1.3.0-r1.apk" ;;
		ipk:*) file="${package}_1.3.0-r1_all.ipk" ;;
	esac
	verified_file "$file"
done
if [ "$format:$release:$arch" = apk:25.12.6:aarch64_cortex-a53 ]; then
	verified_file rollback-tr3000-25.12.6-2.93-r1.apk
	verified_file rollback-tr3000-25.12.6-2.93-r1.adb
fi
legacy=
if router 'if command -v apk >/dev/null; then apk --network=no --repositories-file /dev/null info -v; else opkg list-installed; fi' > "$work/installed" &&
	grep -Eq '^easy-vless(-1[.]2[.]0-r1| - 1[.]2[.]0-r1)$' "$work/installed"; then
	mkdir previous
	for package in easy-vless easy-vless-sing-box luci-app-easy-vless; do
		if [ "$format" = apk ]; then file="$package-1.2.0-r1.apk"; else file="${package}_1.2.0-r1_all.ipk"; fi
		curl -fsSL --retry 2 --proto '=https' --proto-redir '=https' \
			"https://github.com/quargelk/easy-vless/releases/download/v1.2.0/$file" -o "previous/$file"
	done
	legacy=1
fi
remote=$(router 'umask 077; mktemp -d /tmp/ev-pc-stage.XXXXXX')
case "$remote" in /tmp/ev-pc-stage.*) ;; *) remote=; exit 1 ;; esac
suffix=${remote#/tmp/ev-pc-stage.}
case "$suffix" in ''|*[!a-zA-Z0-9]*) remote=; exit 1 ;; esac
tar -cf - . | router "umask 077; tar -xf - -C '$remote'"
rollback=
if [ -n "$legacy" ]; then rollback="--rollback-dir '$remote/previous'"; fi
if [ -n "$check" ]; then
	router "sh '$remote/install.sh' --local '$remote' --check $rollback"
else
	ssh -t -o StrictHostKeyChecking=yes -- "$host" "sh '$remote/install.sh' --local '$remote' $rollback"
fi
