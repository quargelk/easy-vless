#!/bin/bash
# Easy VLESS - repository static checks (run by CI; can be run locally from
# the repository root: bash tests/static-checks.sh).
#
# Checks: git whitespace (git diff --check), shell / Lua / JS syntax, JSON
# validity, translations (luci/po), prepared resources (presence, manifest, byte identity with the
# reference lists via tests/resources.sha256), screenshots, package metadata
# and a scan for local paths, credentials and development leftovers.
#
# Tools: git, sh (dash or ash), bash, luac5.1 or luac or lua, node, python3.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

FAIL=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
tracked() { git ls-files -co --exclude-standard "$@"; }

echo "== git whitespace"
# New whitespace errors only: lines changed against STATIC_BASE (default HEAD,
# i.e. uncommitted changes; CI passes the previous commit). Code inherited
# from PassWall2 keeps its original whitespace to stay diffable with upstream.
BASE="${STATIC_BASE:-HEAD}"
if git rev-parse -q --verify "${BASE}^{commit}" >/dev/null; then
	if out=$(git diff --check "$BASE" -- . 2>&1); then ok "git diff --check against $BASE"; else bad "git diff --check against $BASE"; echo "$out" | head -20; fi
else
	echo "SKIP: git diff --check (base $BASE not available)"
fi

echo "== shell syntax"
SHELL_FILES=$( { tracked '*.sh'; tracked 'root/etc/init.d/*' 'root/etc/uci-defaults/*' 'root/etc/hotplug.d/*' 'luci/root/usr/libexec/rpcd/*'; } | sort -u)
for f in $SHELL_FILES; do
	[ -f "$f" ] || continue
	case "$(head -n1 "$f")" in
		*bash*) bash -n "$f" || bad "bash -n $f" ;;
		*) sh -n "$f" || bad "sh -n $f" ;;
	esac
done
ok "shell syntax ($(echo "$SHELL_FILES" | grep -c .) files)"

echo "== Lua syntax"
LUAC=$(command -v luac5.1 || command -v luac || true)
LUA_FILES=$(tracked '*.lua')
for f in $LUA_FILES; do
	if [ -n "$LUAC" ]; then "$LUAC" -p "$f" || bad "luac -p $f"
	elif command -v lua >/dev/null; then lua -e "assert(loadfile('$f'))" || bad "lua loadfile $f"
	else bad "no luac/lua available"; break; fi
done
ok "Lua syntax ($(echo "$LUA_FILES" | grep -c .) files)"

echo "== JS syntax"
JS_FILES=$(tracked '*.js')
for f in $JS_FILES; do
	# LuCI view/class files end in a top-level "return", so they are parsed
	# as a function body, the same way LuCI's loader evaluates them.
	node -e "new Function(require('fs').readFileSync(process.argv[1], 'utf8'))" "$f" || bad "JS syntax $f"
done
ok "JS syntax ($(echo "$JS_FILES" | grep -c .) files)"

echo "== translations"
# luci/po: template current, every string translated, same placeholders
# and HTML tags; every catalog compiles (scripts/po2lmo.py, as in the build)
if out=$(python3 scripts/i18n-sync.py --check 2>&1); then ok "i18n catalogs: $(echo "$out" | tr '\n' ' ')"; else bad "i18n catalogs"; echo "$out"; fi
for po in luci/po/*/easy-vless.po; do
	lmo=$(mktemp)
	if python3 scripts/po2lmo.py "$po" "$lmo" && [ -s "$lmo" ]; then ok "po2lmo $po ($(wc -c < "$lmo") bytes)"; else bad "po2lmo $po"; fi
	rm -f "$lmo"
done

echo "== JSON"
JSON_FILES=$(tracked '*.json')
for f in $JSON_FILES; do
	python3 -m json.tool "$f" >/dev/null 2>&1 || bad "invalid JSON: $f"
done
ok "JSON ($(echo "$JSON_FILES" | grep -c .) files)"

echo "== prepared resources"
RES=root/usr/share/easy_vless/resources
for f in "$RES/manifest.json" "$RES/domains/proxy.txt" "$RES/domains/russia.txt"; do
	[ -s "$f" ] && ok "present: $f" || bad "missing or empty: $f"
done
if python3 - "$RES" <<'EOF'
import json, os, sys
res = sys.argv[1]
m = json.load(open(os.path.join(res, "manifest.json")))
ids = set()
for r in m.get("resources", []):
    p = os.path.join(res, r["path"])
    assert os.path.isfile(p), "manifest resource %s -> missing file %s" % (r["id"], p)
    ids.add(r["id"])
for t in m.get("rule_templates", []):
    for rid in t.get("domain_resource", []):
        assert rid in ids, "rule template %s uses unknown resource %s" % (t["id"], rid)
EOF
then ok "manifest references existing resources"; else bad "manifest consistency"; fi
if sha256sum -c tests/resources.sha256 >/dev/null 2>&1; then
	ok "reference/domains and packaged lists match tests/resources.sha256"
else
	bad "resource lists differ from tests/resources.sha256"; sha256sum -c tests/resources.sha256
fi
for f in proxy.txt russia.txt; do
	cmp -s "reference/domains/$f" "$RES/domains/$f" \
		&& ok "$RES/domains/$f byte-identical to reference/domains/$f" \
		|| bad "$RES/domains/$f differs from reference/domains/$f"
done

echo "== screenshots"
for img in rule-manage node-list add-subscription main connection-test settings-dns settings-forwarding wizard-server-test wizard-done; do
	f="docs/images/${img}.png"
	if [ -s "$f" ] && [ "$(head -c 8 "$f" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
		ok "screenshot $f"
	else
		bad "screenshot missing or not a PNG: $f"
	fi
done

echo "== README and LICENSE"
if [ -s README.md ]; then
	ok "README.md present"
	# relative links and images: [text](path) / ![alt](path), ignoring URLs and #anchors
	for link in $(grep -oE '\]\([^)#[:space:]]+\)' README.md | sed 's/^](//; s/)$//' | grep -vE '^[a-z]+://' | sort -u); do
		[ -e "$link" ] && ok "README link $link" || bad "README link target missing: $link"
	done
	# #anchors must match a heading slug as GitHub builds it: lower case,
	# punctuation other than "-" and "_" removed, spaces -> "-"
	anchors=$(python3 - README.md <<'EOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
body = re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)
slugs = {re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-")
         for h in re.findall(r"^#+[ \t]+(.+?)[ \t]*$", body, flags=re.M)}
for a in sorted(set(re.findall(r"\]\(#([^)]+)\)", text))):
    print(("ok " if a in slugs else "bad ") + a)
EOF
)
	[ -n "$anchors" ] || bad "README anchor check produced no output"
	echo "$anchors" | while read -r res anchor; do
		[ "$res" = ok ] && echo "PASS: README anchor #$anchor" || echo "FAIL: README anchor without heading: #$anchor"
	done
	n=$(echo "$anchors" | grep -c '^bad ')
	[ "$n" -eq 0 ] || { FAIL=$((FAIL + n)); }
	[ "$(grep -c '^```' README.md)" -ne 0 ] && [ $(( $(grep -c '^```' README.md) % 2 )) -eq 0 ] \
		&& ok "README code fences balanced" || bad "README code fences unbalanced"
else
	bad "README.md missing"
fi
grep -q 'GNU GENERAL PUBLIC LICENSE' LICENSE 2>/dev/null && grep -q 'Version 3, 29 June 2007' LICENSE && [ "$(wc -l < LICENSE)" -gt 600 ] \
	&& ok "LICENSE: full GPL-3.0 text" || bad "LICENSE missing or not the full GPL-3.0 text"

echo "== tests"
[ -s tests/subscription-formats-test.sh ] && [ -d tests/subscription ] && ok "subscription format test and fixtures present" || bad "subscription format test/fixtures missing"
# (needs an OpenWrt runtime; CI runs it in the runtime-tests job)
if sh tests/dnsmasq-nftset-test.sh >/dev/null 2>&1; then ok "dnsmasq nftset regression test"; else bad "dnsmasq nftset regression test"; sh tests/dnsmasq-nftset-test.sh; fi

echo "== package metadata"
PV=$(sed -n 's/^PKG_VERSION:=//p' Makefile); PR=$(sed -n 's/^PKG_RELEASE:=//p' Makefile)
[ -n "$PV" ] && [ -n "$PR" ] && ok "version ${PV}-r${PR}" || bad "PKG_VERSION/PKG_RELEASE missing"
[ -n "$(sed -n 's/^PKG_MAINTAINER:=//p' Makefile)" ] && ok "PKG_MAINTAINER set" || bad "PKG_MAINTAINER empty"
[ -n "$(sed -n 's/^PKG_LICENSE:=//p' Makefile)" ] && ok "PKG_LICENSE set" || bad "PKG_LICENSE empty"
if grep -qE '^[[:space:]]*URL:=[[:space:]]*$' Makefile; then bad "a package has an empty URL:="; else ok "package URLs set"; fi
for pkg in easy-vless easy-vless-sing-box easy-vless-xray easy-vless-geodata luci-app-easy-vless; do
	grep -q "^define Package/${pkg}\$" Makefile && grep -q "BuildPackage,${pkg})" Makefile \
		&& ok "package ${pkg} defined and built" || bad "package ${pkg} not defined/built"
done
IV=$(sed -n 's/^EV_VERSION="\(.*\)"$/\1/p' scripts/install.sh)
IT=$(sed -n 's/^EV_TAG="\(.*\)"$/\1/p' scripts/install.sh)
[ "$IV" = "${PV}-r${PR}" ] && ok "install.sh EV_VERSION = ${IV}" || bad "install.sh EV_VERSION '${IV}' != ${PV}-r${PR}"
case "$IT" in "v${PV}"|"v${PV}-r${PR}") ok "install.sh EV_TAG = ${IT}" ;; *) bad "install.sh EV_TAG '${IT}' does not match ${PV}" ;; esac
# EV_MIN_DATE: the installer refuses a clock before this date, so it must be
# a valid date that is not in the future
MD=$(sed -n 's/^EV_MIN_DATE="\(.*\)"$/\1/p' scripts/install.sh)
if echo "$MD" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' && MDE=$(date -u -d "$MD" +%s 2>/dev/null) && [ "$MDE" -le "$(date -u +%s)" ]; then
	ok "install.sh EV_MIN_DATE = ${MD}"
else
	bad "install.sh EV_MIN_DATE '${MD}' is not a valid past date"
fi
grep -qF "releases/download/${IT}/install.sh" scripts/install.sh && ok "install.sh header URL uses ${IT}" || bad "install.sh header URL does not use ${IT}"
# README: release URLs and package file names of this version only
grep -qF "releases/download/${IT}/install.sh" README.md && ok "README installer URL uses ${IT}" || bad "README installer URL does not use ${IT}"
grep -qF "easy-vless_${IV}_all.ipk" README.md && ok "README package names use ${IV}" || bad "README package names do not use ${IV}"
stale=$(grep -oE 'releases/download/v[0-9][^/ )]*|(easy-vless|easy-vless-sing-box|luci-app-easy-vless)_[0-9][^_ ]*_all\.ipk' README.md \
	| grep -vF -e "releases/download/${IT}" -e "_${IV}_all.ipk" | sort -u)
[ -z "$stale" ] && ok "README has no other release versions" || bad "README mentions other release versions: $(echo "$stale" | tr '\n' ' ')"
grep -qF "**Текущая версия: ${IV}**" README.md && ok "README current version ${IV}" || bad "README current version is not ${IV}"

echo "== local paths, credentials, development leftovers"
# Text files only; this script is excluded because it contains the patterns.
SCAN_FILES=$(tracked | grep -v -e '^tests/static-checks.sh$' -e '\.png$' -e '\.ipk$')
scan() { # scan DESCRIPTION ERE EXCLUDE_ERE [grep options]
	local desc="$1" re="$2" excl="$3" files; shift 3
	files=$(echo "$SCAN_FILES" | grep -vE "$excl")
	# shellcheck disable=SC2086
	hits=$(grep -nE "$@" -e "$re" $files 2>/dev/null | head -10)
	if [ -n "$hits" ]; then bad "$desc"; echo "$hits"; else ok "no $desc"; fi
}
scan "Windows user/project paths" '[A-Za-z]:(\\){1,2}(Users|Projects)(\\|/)' '^tests/subscription/'
scan "home directory paths" '(/home/[a-z][a-z0-9_-]*/|/Users/[A-Za-z][A-Za-z0-9_-]*/)' '^$'
scan "private keys" '-----BEGIN [A-Z ]*PRIVATE KEY-----' '^$'
scan "hard-coded passwords/secrets" '(password|passwd|secret|token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'[:space:]]{6,}["'"'"']' '^$' -i
scan "access tokens" '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})' '^$'
# UUIDs: only the documentation/test UUIDs 00000000-0000-4000-8000-00000000000x are allowed
UUIDS=$(grep -ohE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' $SCAN_FILES 2>/dev/null | grep -vE '^00000000-0000-4000-8000-00000000000[0-9a-f]$' | sort -u)
if [ -n "$UUIDS" ]; then bad "non-test UUIDs: $UUIDS"; else ok "no real-looking UUIDs"; fi
scan "subscription-like URLs" 'https?://[^[:space:]"]+/(sub|subscribe|api/v1/client/subscribe)([/?][^[:space:]"]*)?\b' '^$' -i
scan "AI / assistant references" '\b(claude|chatgpt|openai|anthropic|gemini|copilot|llm|ai-generated|ai-assisted|assistant|prompt)\b' '^(root/usr/share/easy_vless/resources/domains/|reference/domains/|LICENSE$)' -i

echo
if [ "$FAIL" -eq 0 ]; then echo "===== static checks: all passed ====="; else echo "===== static checks: $FAIL FAILED ====="; fi
[ "$FAIL" -eq 0 ]
