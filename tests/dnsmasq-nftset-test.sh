#!/bin/sh
# Easy VLESS - regression test for the dnsmasq nftset capability check.
# Runs anywhere (no OpenWrt needed): extracts dnsmasq_nftset_supported() from
# root/usr/share/easy_vless/app.sh and scripts/install.sh and feeds it
# "dnsmasq --version" outputs. A dnsmasq built without nftset lists
# "no-nftset" in its compile time options (its --help still shows --nftset);
# only a plain "nftset" option means support.
#   sh tests/dnsmasq-nftset-test.sh      (from the repository root)

cd "$(dirname "$0")/.." || exit 2
PASS=0; FAIL=0

STOCK='Dnsmasq version 2.90  Copyright (c) 2000-2024 Simon Kelley
Compile time options: IPv6 GNU-getopt no-DBus UBus no-i18n no-IDN DHCP DHCPv6 no-Lua TFTP no-conntrack no-ipset no-nftset auth no-cryptohash no-DNSSEC no-ID loop-detect inotify dumpfile

This software comes with ABSOLUTELY NO WARRANTY.
Dnsmasq is free software, and you are welcome to redistribute it
under the terms of the GNU General Public License, version 2 or 3.'
FULL='Dnsmasq version 2.90  Copyright (c) 2000-2024 Simon Kelley
Compile time options: IPv6 GNU-getopt no-DBus UBus no-i18n IDN2 DHCP DHCPv6 no-Lua TFTP conntrack ipset nftset auth cryptohash DNSSEC no-ID loop-detect inotify dumpfile

This software comes with ABSOLUTELY NO WARRANTY.'
# "--nftset" appears in "dnsmasq --help" of every build; it must not count
HELP_TEXT='-8, --log-facility=<facility>   Log to this syslog facility or file.
    --nftset=<path>                 Specify nftables sets to which matching domains should be added'

for src in root/usr/share/easy_vless/app.sh scripts/install.sh; do
	fn=$(sed -n '/^dnsmasq_nftset_supported() {/,/^}/p' "$src")
	if [ -z "$fn" ]; then echo "FAIL: $src has no dnsmasq_nftset_supported()"; FAIL=$((FAIL + 1)); continue; fi
	eval "$fn"
	check() { # check NAME TEXT EXPECTED(0=supported,1=unsupported)
		dnsmasq_nftset_supported "$2"; got=$?
		if [ "$got" = "$3" ]; then echo "PASS: $src: $1"; PASS=$((PASS + 1)); else echo "FAIL: $src: $1 (got $got, expected $3)"; FAIL=$((FAIL + 1)); fi
	}
	check "no-nftset (stock dnsmasq 2.90) -> unsupported" "$STOCK" 1
	check "nftset (dnsmasq-full) -> supported" "$FULL" 0
	check "--help text mentioning --nftset -> unsupported" "$HELP_TEXT" 1
	check "empty output (no dnsmasq) -> unsupported" "" 1
done

echo "===== PASS: $PASS  FAIL: $FAIL ====="
[ "$FAIL" -eq 0 ]
