#!/bin/sh
# Easy VLESS - update mechanism (0.9.0): test of
# root/usr/share/easy_vless/update.sh without a router and without network.
#
#   sh tests/update-test.sh      (static checks, CI "checks" job)
#
# curl, opkg, uci and the release installer are replaced by stand-ins in a
# temporary directory (EV_UPDATE_ROOT): a fake release server (files in a
# directory), a fake package database (one "name version" line per package).
# Covered: version comparison, SHA256SUMS parsing, check (newer / same /
# unreachable / foreign release), and install: success, a modified package,
# a modified installer, an installer of another release, a router that does
# not meet the requirements, a failing installation and a failing validation
# (both rolled back to the previous packages and configuration), no
# downgrade, a second update while one runs.

set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
UPDATE="$REPO_ROOT/root/usr/share/easy_vless/update.sh"
T=$(mktemp -d) || exit 2
case "$T" in /tmp/*|/var/tmp/*|"${TMPDIR:-/nonexistent}"/*) ;; *) echo "unexpected temporary directory: $T"; exit 2 ;; esac
trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

# ---------------------------------------------------------------- stand-ins
mkdir -p "$T/bin" "$T/root/etc/config" "$T/root/etc/easy_vless" "$T/root/tmp/log" "$T/root/var/run" "$T/root/var/lock" "$T/srv"
export EV_UPDATE_ROOT="$T/root"
export EV_UPDATE_BASE="https://releases.test/easy-vless/releases"
export EV_UPDATE_APP="$T/bin/app.sh"
export EV_UPDATE_INIT="$T/bin/init"
export FAKE="$T"
PKGDB="$T/pkgdb"

# curl: "-w %{redirect_url} .../latest" prints the redirect of the fake
# server; "-o FILE URL" copies $T/srv/<path after /releases/>
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
out=""; url=""; w=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift ;;
		-w) w="$2"; shift ;;
		--proto|--proto-redir|--connect-timeout|--max-time) shift ;;
		-*) ;;
		*) url="$1" ;;
	esac
	shift
done
[ -f "$FAKE/offline" ] && exit 6
case "$url" in https://releases.test/easy-vless/releases/*) ;; *) exit 3 ;; esac
path="${url#https://releases.test/easy-vless/releases/}"
if [ -n "$w" ]; then
	[ -s "$FAKE/srv/latest" ] || exit 22
	printf '%s' "https://releases.test/easy-vless/releases/tag/$(cat "$FAKE/srv/latest")"
	exit 0
fi
[ -f "$FAKE/srv/$path" ] || exit 22
cp "$FAKE/srv/$path" "$out"
STUB
# opkg: list-installed from the package database; install = set the version
# of every given <name>_<version>_all.ipk (the files must exist)
cat > "$T/bin/opkg" <<'STUB'
#!/bin/sh
db="$FAKE/pkgdb"
case "$1" in
	list-installed) awk '{ print $1 " - " $2 }' "$db" ;;
	install)
		shift
		for f in "$@"; do
			case "$f" in --*) continue ;; esac
			[ -s "$f" ] || exit 1
			b=${f##*/}; name=${b%%_*}; rest=${b#*_}; ver=${rest%_all.ipk}
			grep -v "^$name " "$db" > "$db.new"; echo "$name $ver" >> "$db.new"; mv "$db.new" "$db"
			echo "$name $ver" >> "$FAKE/opkg.log"
		done
	;;
esac
STUB
cat > "$T/bin/uci" <<'STUB'
#!/bin/sh
case "$*" in
	*"@global[0].enabled"*) cat "$FAKE/enabled" 2>/dev/null ;;
	*"@global[0].node"*) echo main_router ;;
esac
STUB
printf '#!/bin/sh\n[ -f "$FAKE/check_fails" ] && { echo "FATAL: decode config"; exit 1; }\necho "OK: sing-box accepted the configuration"\n' > "$T/bin/app.sh"
printf '#!/bin/sh\necho "$1" >> "$FAKE/init.log"\n' > "$T/bin/init"
chmod +x "$T/bin"/*
PATH="$T/bin:$PATH"; export PATH

# a release on the fake server: packages, an installer that behaves like
# scripts/install.sh for the options update.sh uses, SHA256SUMS
make_release() { # tag version
	d="$T/srv/download/$1"; mkdir -p "$d"
	for p in easy-vless easy-vless-sing-box luci-app-easy-vless; do echo "package $p $2" > "$d/${p}_$2_all.ipk"; done
	cat > "$d/install.sh" <<INST
#!/bin/sh
EV_VERSION="$2"
EV_TAG="$1"
check=0; local=""
while [ \$# -gt 0 ]; do
	case "\$1" in --check) check=1 ;; --local) local="\$2"; shift ;; esac
	shift
done
[ -f "\$FAKE/incompatible" ] && { echo "[easy-vless] ERROR: OpenWrt 23.05 is not supported" >&2; exit 1; }
[ "\$check" = 1 ] && exit 0
[ -f "\$FAKE/install_fails" ] && { opkg install "\$local/easy-vless_${2}_all.ipk"; echo "[easy-vless] ERROR: opkg install of the Easy VLESS packages failed" >&2; exit 1; }
opkg install "\$local"/easy-vless_${2}_all.ipk "\$local"/easy-vless-sing-box_${2}_all.ipk "\$local"/luci-app-easy-vless_${2}_all.ipk
[ -f "\$FAKE/wipes_config" ] && : > "\$EV_UPDATE_ROOT/etc/config/easy_vless"
exit 0
INST
	(cd "$d" && sha256sum *.ipk install.sh > SHA256SUMS)
}
reset() { # installed version
	rm -rf "${T:?}/root/var/run/easy_vless_update" "${T:?}/root/var/lock/easy_vless_update.lock" "${T:?}/root/etc/easy_vless/update-backup" "${T:?}"/root/tmp/easy_vless_update.*
	rm -f "$T/opkg.log" "$T/init.log" "$T/offline" "$T/incompatible" "$T/install_fails" "$T/check_fails" "$T/wipes_config" "$T/root/var/lock/easy_vless.lock"
	rm -rf "${T:?}/srv"; mkdir -p "$T/srv"
	printf 'easy-vless %s\neasy-vless-sing-box %s\nluci-app-easy-vless %s\n' "$1" "$1" "$1" > "$PKGDB"
	printf "config global 'global'\n\toption enabled '1'\n\toption node 'main_router'\n" > "$T/root/etc/config/easy_vless"
	echo "0123456789abcdef0123456789abcdef" > "$T/root/etc/easy_vless/hwid"
	echo 1 > "$T/enabled"
	make_release v0.9.0 0.9.0-r1
	make_release v0.9.1 0.9.1-r1
	echo v0.9.1 > "$T/srv/latest"
}
ver() { awk '$1 == "easy-vless" { print $2 }' "$PKGDB"; }
vers() { sort "$PKGDB" | awk '{ printf "%s ", $2 }'; }
state() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" "$T/root/var/run/easy_vless_update/state.json" 2>/dev/null; }
cfg_sum() { sha256sum "$T/root/etc/config/easy_vless" | cut -d' ' -f1; }
leftovers() { ls -d "$T"/root/tmp/easy_vless_update.* 2>/dev/null | grep -c .; }

# ---------------------------------------------------------------- functions
EV_UPDATE_LIB=1; . "$UPDATE"; unset EV_UPDATE_LIB
check "version_gt: newer patch, minor, release number" 'version_gt 0.9.1-r1 0.9.0-r1 && version_gt 0.10.0-r1 0.9.9-r9 && version_gt 0.9.0-r2 0.9.0-r1'
check "version_gt: equal and older are not newer" '! version_gt 0.9.0-r1 0.9.0-r1 && ! version_gt 0.8.0-r1 0.9.0-r1 && ! version_gt 0.9.0-r1 0.9.0-r2'
check "valid_tag: release tags only" 'valid_tag v0.9.1 && valid_tag v0.9.1-r2 && ! valid_tag "v0.9.1; reboot" && ! valid_tag latest && ! valid_tag "../v0.9.1" && ! valid_tag ""'
check "tag_matches: v0.9.1 and v0.9.1-r1 for 0.9.1-r1" 'tag_matches v0.9.1 0.9.1-r1 && tag_matches v0.9.1-r1 0.9.1-r1 && ! tag_matches v0.9.2 0.9.1-r1'
reset 0.9.0-r1
S="$T/srv/download/v0.9.1/SHA256SUMS"
check "sums_version: the one version of the three packages" '[ "$(sums_version "$S")" = "0.9.1-r1" ]'
grep -v "luci-app" "$S" > "$T/s1"
check "sums_version: a package missing" '! sums_version "$T/s1" >/dev/null'
sed 's/easy-vless-sing-box_0.9.1-r1/easy-vless-sing-box_0.9.0-r1/' "$S" > "$T/s2"
check "sums_version: packages of different versions" '! sums_version "$T/s2" >/dev/null'
cat "$S" "$S" > "$T/s3"
check "sums_hash: a file listed twice is not accepted" '! sums_hash "$T/s3" install.sh >/dev/null && sums_hash "$S" install.sh >/dev/null'
check "sums_hash: a file that is not listed" '! sums_hash "$S" evil.ipk >/dev/null'
check "fetch: refuses a URL that is not HTTPS" '! fetch "http://releases.test/easy-vless/releases/download/v0.9.1/SHA256SUMS" "$T/x" 2>/dev/null && ! fetch "file:///etc/passwd" "$T/x" 2>/dev/null'

run() { sh "$UPDATE" "$@"; }

# ---------------------------------------------------------------- check
out=$(run check force)
check "check: a newer release is reported" 'echo "$out" | grep -q "\"ok\":true" && echo "$out" | grep -q "\"available\":true" && echo "$out" | grep -q "\"latest\":\"0.9.1-r1\"" && echo "$out" | grep -q "\"current\":\"0.9.0-r1\"" && echo "$out" | grep -q "\"tag\":\"v0.9.1\""'
touch "$T/offline"
out=$(run check)
check "check: answered from the cache within a day (no network needed)" 'echo "$out" | grep -q "\"available\":true"'
out=$(run check force)
check "check: unreachable release page is an error with its reason, not 'no update'" 'echo "$out" | grep -q "\"ok\":false" && echo "$out" | grep -q "\"error\":\"network\"" && ! echo "$out" | grep -q available'
out=$(run check)
check "check: a failed check is not repeated for an hour (cached error)" 'echo "$out" | grep -q "\"error\":\"network\""'
rm -f "$T/offline"
out=$(run check)
check "check: ... and still answered from that cache when the network is back" 'echo "$out" | grep -q "\"error\":\"network\""'
out=$(run check force)
check "check: 'Check for updates' asks again at once" 'echo "$out" | grep -q "\"available\":true"'
reset 0.9.1-r1
out=$(run check force)
check "check: the installed version is the latest" 'echo "$out" | grep -q "\"available\":false"'
reset 0.9.0-r1; echo "nightly" > "$T/srv/latest"
out=$(run check force)
check "check: a tag that is not a release of this project is refused" 'echo "$out" | grep -q "\"error\":\"release\""'
reset 0.9.0-r1; sed -i 's/_0.9.1-r1_/_0.9.5-r1_/' "$T/srv/download/v0.9.1/SHA256SUMS"
out=$(run check force)
check "check: a release whose packages have another version than its tag is refused" 'echo "$out" | grep -q "\"error\":\"release\""'
: > "$PKGDB"
out=$(run check force)
check "check: easy-vless not installed as a package" 'echo "$out" | grep -q "\"error\":\"not_installed\""'

# ---------------------------------------------------------------- install: success
reset 0.9.0-r1; before=$(cfg_sum)
run install v0.9.1 >/dev/null 2>&1; rc=$?
check "install: succeeds (exit 0, phase done)" '[ "$rc" = 0 ] && [ "$(state phase)" = done ] && [ "$(state status)" = ok ]'
check "install: all three packages at the new version ($(vers))" '[ "$(vers)" = "0.9.1-r1 0.9.1-r1 0.9.1-r1 " ]'
check "install: the configuration is untouched and a copy was saved first" '[ "$(cfg_sum)" = "$before" ] && [ -s "$T/root/etc/easy_vless/update-backup/config" ] && [ "$(cat "$T/root/etc/easy_vless/update-backup/version")" = "0.9.0-r1" ]'
check "install: the service is restarted because the main switch is on" 'grep -qx restart "$T/init.log"'
check "install: no temporary files and no lock left" '[ "$(leftovers)" = 0 ] && [ ! -d "$T/root/var/lock/easy_vless_update.lock" ]'
out=$(run state)
check "state: reports the result and the new version" 'echo "$out" | grep -q "\"phase\":\"done\"" && echo "$out" | grep -q "\"version\":\"0.9.1-r1\"" && echo "$out" | grep -q "\"busy\":false"'
reset 0.9.0-r1; echo 0 > "$T/enabled"
run install v0.9.1 >/dev/null 2>&1
check "install: main switch off - updated, the service is not started" '[ "$(ver)" = "0.9.1-r1" ] && [ ! -f "$T/init.log" ]'

# ---------------------------------------------------------------- install: refused before anything changes
refused() { # label, expected phase, message pattern
	check "$1: refused (phase $(state phase)), nothing installed" '[ "$rc" != 0 ] && [ "$(state phase)" = "'"$2"'" ] && [ "$(state status)" = failed ] && [ "$(vers)" = "0.9.0-r1 0.9.0-r1 0.9.0-r1 " ] && [ ! -f "$T/opkg.log" ]'
	check "$1: the reason is named" 'state message | grep -q "'"$3"'"'
	check "$1: nothing left behind" '[ "$(leftovers)" = 0 ] && [ ! -d "$T/root/var/lock/easy_vless_update.lock" ] && [ "$(cfg_sum)" = "$before" ]'
}
reset 0.9.0-r1; before=$(cfg_sum); echo "tampered" >> "$T/srv/download/v0.9.1/easy-vless_0.9.1-r1_all.ipk"
run install v0.9.1 >/dev/null 2>&1; rc=$?
refused "modified package" verify "does not match SHA256SUMS"
reset 0.9.0-r1; before=$(cfg_sum); echo "# extra line" >> "$T/srv/download/v0.9.1/install.sh"
run install v0.9.1 >/dev/null 2>&1; rc=$?
refused "modified installer" verify "install.sh does not match SHA256SUMS"
reset 0.9.0-r1; before=$(cfg_sum)
cp "$T/srv/download/v0.9.0/install.sh" "$T/srv/download/v0.9.1/install.sh"; (cd "$T/srv/download/v0.9.1" && sha256sum *.ipk install.sh > SHA256SUMS)
run install v0.9.1 >/dev/null 2>&1; rc=$?
refused "installer of another release (with a matching checksum file)" verify "not the installer of v0.9.1"
reset 0.9.0-r1; before=$(cfg_sum); rm "$T/srv/download/v0.9.1/luci-app-easy-vless_0.9.1-r1_all.ipk"
run install v0.9.1 >/dev/null 2>&1; rc=$?
refused "a package is missing in the release" verify "could not be downloaded"
reset 0.9.0-r1; before=$(cfg_sum); touch "$T/offline"
run install v0.9.1 >/dev/null 2>&1; rc=$?
refused "no network" verify "could not be downloaded"
reset 0.9.0-r1; before=$(cfg_sum); touch "$T/incompatible"
run install v0.9.1 >/dev/null 2>&1; rc=$?
refused "router does not meet the requirements" compatibility "OpenWrt 23.05 is not supported"
reset 0.9.1-r1; before=$(cfg_sum)
run install v0.9.0 >/dev/null 2>&1; rc=$?
check "downgrade: refused, nothing installed" '[ "$rc" != 0 ] && [ "$(state phase)" = verify ] && state message | grep -q "not newer" && [ "$(ver)" = "0.9.1-r1" ] && [ ! -f "$T/opkg.log" ]'
reset 0.9.0-r1
run install "v0.9.1; touch $T/pwned" >/dev/null 2>&1; rc=$?
check "a tag with shell characters is refused and never executed" '[ "$rc" != 0 ] && [ "$(state phase)" = refused ] && [ ! -e "$T/pwned" ]'
reset 0.9.0-r1; touch "$T/root/var/lock/easy_vless.lock"
run install v0.9.1 >/dev/null 2>&1; rc=$?
check "while Easy VLESS starts or stops: refused" '[ "$rc" != 0 ] && [ "$(state phase)" = refused ] && [ "$(ver)" = "0.9.0-r1" ]'
reset 0.9.0-r1; mkdir -p "$T/root/var/lock/easy_vless_update.lock"
out=$(run install v0.9.1 2>/dev/null); rc=$?
check "a second update while one runs: refused as busy, the running one keeps its lock" '[ "$rc" != 0 ] && echo "$out" | grep -q "\"error\":\"busy\"" && [ -d "$T/root/var/lock/easy_vless_update.lock" ] && [ "$(ver)" = "0.9.0-r1" ]'

# ---------------------------------------------------------------- install: failure after the change -> rollback
reset 0.9.0-r1; before=$(cfg_sum); touch "$T/install_fails"
run install v0.9.1 >/dev/null 2>&1; rc=$?
check "failing installation (one package already replaced): rolled back" '[ "$rc" != 0 ] && [ "$(state phase)" = rolled_back ] && [ "$(state status)" = failed ]'
check "rollback: every package is back at the previous version ($(vers))" '[ "$(vers)" = "0.9.0-r1 0.9.0-r1 0.9.0-r1 " ]'
check "rollback: the configuration is the saved one, the reason is named" '[ "$(cfg_sum)" = "$before" ] && state message | grep -q "installation of 0.9.1-r1 failed"'
check "rollback: the service is restarted with the previous version" 'grep -qx restart "$T/init.log"'
check "rollback: nothing left behind" '[ "$(leftovers)" = 0 ] && [ ! -d "$T/root/var/lock/easy_vless_update.lock" ]'
reset 0.9.0-r1; before=$(cfg_sum); touch "$T/check_fails"
run install v0.9.1 >/dev/null 2>&1; rc=$?
check "new version rejects the saved configuration: rolled back with the reason" '[ "$rc" != 0 ] && [ "$(state phase)" = rolled_back ] && [ "$(vers)" = "0.9.0-r1 0.9.0-r1 0.9.0-r1 " ] && state message | grep -q "does not accept the saved configuration"'
reset 0.9.0-r1; before=$(cfg_sum); touch "$T/wipes_config"
run install v0.9.1 >/dev/null 2>&1; rc=$?
check "configuration lost by the installation: packages and configuration restored" '[ "$rc" != 0 ] && [ "$(state phase)" = rolled_back ] && [ "$(cfg_sum)" = "$before" ] && [ "$(ver)" = "0.9.0-r1" ]'
reset 0.9.0-r1; before=$(cfg_sum); touch "$T/install_fails"; rm -r "${T:?}/srv/download/v0.9.0"
run install v0.9.1 >/dev/null 2>&1; rc=$?
check "previous release not downloadable: the incomplete rollback is reported as such, with what to do" '[ "$rc" != 0 ] && [ "$(state phase)" = rollback_failed ] && state message | grep -q "could not be put back completely" && [ "$(cfg_sum)" = "$before" ]'

echo
echo "===== update: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
