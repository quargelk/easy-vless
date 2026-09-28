#!/bin/bash
# Easy VLESS - flash/UBIFS tests on a real kernel (CI, GitHub Actions runner):
#   sudo bash tests/ci/ubifs-tests.sh <dist dir>
#
# The runner kernel simulates NAND flash chips (nandsim) with the partition
# layout of a Cudy TR3000 v1 (OpenWrt 24.10.3 mt7981b-cudy-tr3000-v1.dts:
# 128 MiB SPI-NAND, 5.75 MiB boot partitions, "ubi" 64 MiB). UBI is attached
# to the 64 MiB partition with the volumes of an OpenWrt image (kernel,
# rootfs, rootfs_data = UBIFS overlay), exactly like on the router.
#
#   1. compression: the packages of a worst-case Easy VLESS installation on a
#      TR3000 v1 (aarch64_cortex-a53: sing-box-tiny, dnsmasq-full, every
#      dependency missing from the release image) are unpacked onto the real
#      UBIFS; the space it really uses must not exceed
#      COMPRESSED_FS_PERCENT of scripts/install.sh.
#   2. install.sh in an OpenWrt rootfs container with this UBIFS as /overlay
#      and the kernel's real /proc/mtd and /sys/class/{mtd,ubi}: the flash
#      size (128 MB), the overlay and its free space are detected, and a
#      full installation passes the checks.
#   3. a 64 MiB NAND chip: install.sh refuses the flash size.
set -euo pipefail
W="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$(cd "${1:?usage: $0 <dist dir>}" && pwd)"
IMAGE="${OPENWRT_ROOTFS_IMAGE:-openwrt/rootfs:x86-64-24.10.3}"
REL=24.10.3
FEED="https://downloads.openwrt.org/releases/${REL}"
MNT=/mnt/ev-ubifs
T="$(mktemp -d)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

cleanup_flash() {
	umount "$MNT" 2>/dev/null || true
	ubidetach -d 0 2>/dev/null || true
	rmmod nandsim 2>/dev/null || true
}
trap 'cleanup_flash; rm -rf "$T"' EXIT

# flash ID_BYTES PARTS: a simulated NAND chip with these partitions (sizes in
# eraseblocks), UBI on the partition named by $UBI_PART (mtd index)
flash() {
	cleanup_flash
	# only this chip's boot messages in the kernel log
	dmesg -C
	modprobe nandsim id_bytes="$1" parts="$2"
	cat /proc/mtd
	ubiattach -m "$3" -d 0
	# volume sizes of an OpenWrt 24.10 filogic image with LuCI (FIT kernel,
	# squashfs rootfs); the rest is the overlay, as created by fstools
	ubimkvol /dev/ubi0 -N kernel -s 5MiB
	ubimkvol /dev/ubi0 -N rootfs -s 10MiB
	ubimkvol /dev/ubi0 -N rootfs_data -m
	mkdir -p "$MNT"
	mount -t ubifs ubi0:rootfs_data "$MNT"
	echo "UBI: $(cat /sys/class/ubi/ubi0/total_eraseblocks) eraseblocks, reserved_for_bad $(cat /sys/class/ubi/ubi0/reserved_for_bad), bad $(cat /sys/class/ubi/ubi0/bad_peb_count)"
	df -k "$MNT"
}

# ---------------------------------------------------------------- 1. TR3000 v1 layout
echo "######## 128 MiB NAND (Samsung K9F1G08, 2 KiB pages, 128 KiB eraseblocks), TR3000 v1 partitions"
# BL2..FIP = 0x5c0000 = 46 eraseblocks, ubi = 64 MiB = 512 eraseblocks, rest unused
flash 0xec,0xf1,0x00,0x95,0x40 46,512 1
[ "$(cat /sys/class/ubi/ubi0/reserved_for_bad)" = 20 ] && ok "UBI reserves 20 eraseblocks for bad blocks (20 per 1024 of the 128 MiB chip)" \
	|| bad "reserved_for_bad = $(cat /sys/class/ubi/ubi0/reserved_for_bad), expected 20"
free_kb="$(df -k "$MNT" | awk 'NR == 2 { print $4 }')"
echo "UBIFS rootfs_data free: ${free_kb} KB"

# worst-case package set of a fresh TR3000 v1 (release image incl. LuCI)
echo "######## compression of a worst-case installation on UBIFS (aarch64_cortex-a53)"
cd "$T"
for f in base packages luci; do curl -fsS -o "$f" "$FEED/packages/aarch64_cortex-a53/$f/Packages"; done
curl -fsS -o core "$FEED/targets/mediatek/filogic/packages/Packages"
kdir="$(curl -fsS "$FEED/targets/mediatek/filogic/kmods/" | grep -o 'href="[0-9][^"/]*/"' | head -n1 | sed 's/href="//; s#/"##')"
curl -fsS -o kmods "$FEED/targets/mediatek/filogic/kmods/$kdir/Packages"
curl -fsS -o profiles.json "$FEED/targets/mediatek/filogic/profiles.json"
deps="$(tar -xzOf "$(ls "$DIST"/easy-vless_*_all.ipk)" ./control.tar.gz | tar -xzO ./control | sed -n 's/^Depends: //p')"
python3 - "$deps" >pkgs.txt <<'EOF'
import json, re, sys
P, prov, feed = {}, {}, {}
for f in ["base", "packages", "luci", "core", "kmods"]:
    for blk in open(f, encoding="utf-8").read().split("\n\n"):
        d = dict(l.split(": ", 1) for l in blk.splitlines() if ": " in l and not l.startswith(" "))
        if "Package" in d:
            P[d["Package"]] = d; feed[d["Package"]] = f
            for p in d.get("Provides", "").split(","):
                p = p.strip().split(" ")[0]
                if p: prov.setdefault(p, d["Package"])
def closure(names, have):
    have = set(have); out = []; q = [[n] for n in names]
    while q:
        alts = q.pop(0)
        if any(a in have for a in alts): continue
        pick = next((a if a in P else prov[a] for a in alts if a in P or a in prov), None)
        if pick is None or pick in have: continue
        have.add(pick); out.append(pick)
        for p in P[pick].get("Provides", "").split(","):
            if p.strip(): have.add(p.strip().split(" ")[0])
        for dep in P[pick].get("Depends", "").split(","):
            if dep.strip(): q.append([re.sub(r"\s*\(.*\)", "", a).strip() for a in dep.split("|")])
    return out, have
prof = json.load(open("profiles.json"))
image = [p for p in prof["default_packages"] + prof["profiles"]["cudy_tr3000-v1"]["device_packages"] + ["luci"] if not p.startswith("-")]
_, have = closure(image, ["libc", "kernel"])
have |= {"libc", "kernel"}
want = ["sing-box-tiny", "dnsmasq-full", "luci-base", "rpcd"] + [d.strip().split(" ")[0] for d in sys.argv[1].split(",") if d.strip()]
new, _ = closure(want, have)
for n in new:
    print(n, feed[n], P[n]["Filename"], P[n].get("Installed-Size", "0"))
EOF
echo "worst case: $(wc -l <pkgs.txt) packages: $(awk '{ printf "%s ", $1 }' pkgs.txt)"
mkdir -p ipk
total=0
while read -r name f file size; do
	case "$f" in
		core) url="$FEED/targets/mediatek/filogic/packages/$file" ;;
		kmods) url="$FEED/targets/mediatek/filogic/kmods/$kdir/$file" ;;
		*) url="$FEED/packages/aarch64_cortex-a53/$f/$file" ;;
	esac
	curl -fsS -o "ipk/$file" "$url"
	total=$((total + size))
done <pkgs.txt
for p in "$DIST"/easy-vless_*_all.ipk "$DIST"/easy-vless-sing-box_*_all.ipk "$DIST"/luci-app-easy-vless_*_all.ipk; do
	cp "$p" ipk/
	total=$((total + $(tar -xzOf "$p" ./control.tar.gz | tar -xzO ./control | sed -n 's/^Installed-Size: //p')))
done
used0="$(df -k "$MNT" | awk 'NR == 2 { print $3 }')"
mkdir -p "$MNT/upper"
for p in ipk/*.ipk; do tar -xzOf "$p" ./data.tar.gz | tar -xz -C "$MNT/upper"; done
sync
used1="$(df -k "$MNT" | awk 'NR == 2 { print $3 }')"
real_kb=$((used1 - used0)); unc_kb=$((total / 1024))
pct=$((real_kb * 100 / unc_kb))
limit="$(sed -n 's/^COMPRESSED_FS_PERCENT=//p' "$W/scripts/install.sh")"
echo "uncompressed (Installed-Size): ${unc_kb} KB, used on UBIFS: ${real_kb} KB = ${pct}% (install.sh counts ${limit}%)"
[ "$pct" -le "$limit" ] && ok "UBIFS stores the worst-case installation in ${pct}% of its size <= ${limit}% (COMPRESSED_FS_PERCENT)" \
	|| bad "UBIFS needs ${pct}% of the uncompressed size, install.sh assumes ${limit}%"
need_kb=$((unc_kb * limit / 100 + $(sed -n 's/^SPACE_RESERVE_KB=//p' "$W/scripts/install.sh")))
echo "install.sh requirement for this worst case: ${need_kb} KB; free on this TR3000 layout: ${free_kb} KB"
[ "$need_kb" -lt "$free_kb" ] && ok "TR3000 v1 layout: worst case (${need_kb} KB) fits the free overlay (${free_kb} KB)" || bad "TR3000 v1 worst case does not fit"
[ "$real_kb" -lt "$free_kb" ] && ok "TR3000 v1 layout: the unpacked worst case really fits (${real_kb} KB used)" || bad "worst case really does not fit"
rm -rf "${MNT:?}/upper"; sync
cd "$W"

# ---------------------------------------------------------------- 2. install.sh on this flash
run() { # run DESCRIPTION EXPECTED_RC PATTERN ARGS...
	local d="$1" rc_want="$2" pat="$3" rc; shift 3
	set +e
	docker run --rm -v "$W:/w:ro" -v "$DIST:/dist:ro" -v "$MNT:/overlay" "$IMAGE" /bin/ash -c \
		'mkdir -p /var/lock /tmp/log; opkg update >/dev/null 2>&1; opkg install firewall4 luci >/dev/null 2>&1; sh /w/scripts/install.sh "$@"' sh "$@" >"$T/out" 2>&1
	rc=$?
	set -e
	sed 's/^/    | /' "$T/out" | grep -E "RAM|flash|overlay|free space|ERROR|WARNING|check finished|installed" || true
	if { [ "$rc_want" = 0 ] && [ "$rc" = 0 ] || [ "$rc_want" != 0 ] && [ "$rc" != 0 ]; } && grep -qE -e "$pat" "$T/out"; then ok "$d"; else bad "$d (rc=$rc, expected /$pat/)"; tail -n 30 "$T/out"; fi
}
echo "######## install.sh with the TR3000 v1 flash as /overlay (LuCI installed like in the release image)"
run "flash detected as 128 MB, UBIFS overlay, --check passes" 0 \
	"flash/storage: 128\\.0 MB \\(flash chip \\((UBI bad-block reserve|kernel log)\\)\\).*" --check --local /dist
grep -q "overlay: /overlay (ubifs on ubi0:rootfs_data)" "$T/out" && ok "UBIFS overlay detected (ubi0:rootfs_data)" || bad "overlay line"
grep -qE "free space on /overlay: [0-9.]+ MB, required: [0-9.]+ MB \\(ubifs compresses" "$T/out" && ok "free space of the real UBIFS compared with the requirement" || bad "free space line"
run "full installation with the TR3000 v1 flash layout passes" 0 "Easy VLESS packages verified against SHA256SUMS" --local /dist --replace-dnsmasq --yes --no-start

# ---------------------------------------------------------------- 3. 64 MiB flash
echo "######## 64 MiB NAND (Samsung K9F1208, 512 B pages, 16 KiB eraseblocks)"
flash 0xec,0x76 64,3900 1
run "64 MB flash refused before any change" 1 "flash/storage too small: 6[0-9]\\.[0-9] MB .*required: at least 128 MB" --check --local /dist

echo "===== ubifs: PASS: $PASS  FAIL: $FAIL ====="
[ "$FAIL" -eq 0 ]
