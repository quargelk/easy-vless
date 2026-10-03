#!/bin/sh
# Easy VLESS 0.9.0 - update from a GitHub release (rpcd "update").
#
#   update.sh check            is a newer release available? (JSON; cached)
#   update.sh state            progress / result of the last installation (JSON)
#   update.sh install <tag>    download, verify and install that release
#
# Nothing is ever installed on its own: "install" runs only when the user
# confirmed it in LuCI, for the release that "check" reported. The update is
# done by the release's own installer (install.sh, the same file a manual
# installation uses) - not by piping a download into a shell:
#
#   1. the installed version and the latest release are compared; only a
#      newer release is installed (no downgrade);
#   2. SHA256SUMS, install.sh and the three packages of that release are
#      downloaded over HTTPS (certificates verified) into a private directory;
#   3. integrity: every file must be listed exactly once in SHA256SUMS and
#      match it; the files must belong to the release that was asked for
#      (package version = tag, and the installer says the same about itself).
#      SHA256SUMS comes from the same release: this proves that the files
#      are complete, unmodified in transit and belong together - it is not a
#      signature of the author. A file that does not fit is refused, GitHub
#      as the origin is not a reason to accept it;
#   4. compatibility: "install.sh --check" (router, OpenWrt release, feeds,
#      sing-box, dnsmasq, free space) with the verified local files;
#   5. the configuration is saved (/etc/easy_vless/update-backup) and the
#      packages of the installed version are fetched and verified for a
#      rollback;
#   6. install.sh installs the verified local files (--local, --no-start);
#   7. validation: package versions, the configuration is still there and
#      the saved node still generates a valid sing-box configuration;
#   8. the service is restarted when its main switch is on;
#   9. if 6 or 7 fails: the previous packages and the saved configuration
#      are put back and the service is restarted as it was.
#
# The state is in tmpfs (/var/run/easy_vless_update): no periodic job, no
# polling - LuCI asks "check" when its page is opened, at most once a day.

set -u

CONFIG=easy_vless
REPO="quargelk/easy-vless"
BASE_URL="${EV_UPDATE_BASE:-https://github.com/${REPO}/releases}"
# test hook: every path below lives under this directory (tests/update-test.sh)
R="${EV_UPDATE_ROOT:-}"
STATE_DIR="$R/var/run/${CONFIG}_update"
STATE_FILE="$STATE_DIR/state.json"
CHECK_FILE="$STATE_DIR/check.json"
LOCK_DIR="$R/var/lock/${CONFIG}_update.lock"
LOG_FILE="$R/tmp/log/${CONFIG}_update.log"
CONFIG_FILE="$R/etc/config/${CONFIG}"
HWID_FILE="$R/etc/${CONFIG}/hwid"
BACKUP_DIR="$R/etc/${CONFIG}/update-backup"
INIT_LOCK="$R/var/lock/${CONFIG}.lock"
APP="${EV_UPDATE_APP:-/usr/share/${CONFIG}/app.sh}"
INIT="${EV_UPDATE_INIT:-/etc/init.d/${CONFIG}}"
PACKAGES="easy-vless easy-vless-sing-box luci-app-easy-vless"
CHECK_MAX_AGE=86400
# a failed check (GitHub not reachable) is not repeated on every page view
CHECK_RETRY_AGE=3600

WORK=""

# ---------------------------------------------------------------- helpers

json_escape() {
	printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

log() {
	mkdir -p "${LOG_FILE%/*}" 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# valid_tag TAG: a release tag of this project (v1.2.3 or v1.2.3-r4)
valid_tag() {
	printf '%s' "$1" | grep -Eq '^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}(-r[0-9]{1,4})?$'
}

# valid_version V: a package version (1.2.3-r4)
valid_version() {
	printf '%s' "$1" | grep -Eq '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}-r[0-9]{1,4}$'
}

# version_gt A B: A is newer than B (numeric parts; "-r" is the last part)
version_gt() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		gsub(/-r/, ".", a); gsub(/-r/, ".", b);
		na = split(a, x, "."); nb = split(b, y, ".");
		n = (na > nb) ? na : nb;
		for (i = 1; i <= n; i++) {
			xi = x[i] + 0; yi = y[i] + 0;
			if (xi > yi) exit 0;
			if (xi < yi) exit 1;
		}
		exit 1 }'
}

installed_version() {
	opkg list-installed 2>/dev/null | awk -v p="${1:-easy-vless}" '$1 == p { print $3; exit }'
}

sha256_of() {
	sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

# fetch URL FILE [SECONDS]: HTTPS only, certificate verified, redirects only
# to HTTPS; SECONDS = time limit of the download (default 300)
fetch() {
	case "$1" in
		https://*) ;;
		*) return 1 ;;
	esac
	rm -f "$2"
	curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time "${3:-300}" -o "$2" "$1" 2>>"$LOG_FILE" && [ -s "$2" ]
}

# latest_tag: the tag the "latest release" link of the repository points to
latest_tag() {
	local url
	url=$(curl -fsS --proto '=https' --connect-timeout 8 --max-time 12 -o /dev/null -w '%{redirect_url}' "${BASE_URL}/latest" 2>>"$LOG_FILE") || return 1
	case "$url" in
		*/releases/tag/*) printf '%s' "${url##*/releases/tag/}" ;;
		*) return 1 ;;
	esac
}

# sums_hash FILE NAME: the hash of NAME in a SHA256SUMS file - only when it
# is listed exactly once, as "<64 hex>  <name>"
sums_hash() {
	awk -v f="$2" 'NF == 2 && ($2 == f || $2 == "*" f) && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; n++ } END { if (n != 1) exit 1 }' "$1"
}

# sums_version FILE: the one package version all three packages of a
# SHA256SUMS file have (fails when they differ or one is missing)
sums_version() {
	local p v ver=""
	for p in $PACKAGES; do
		v=$(awk -v p="$p" '{ n = $2; sub(/^\*/, "", n); if (index(n, p "_") == 1 && n ~ /_all\.ipk$/) { v = substr(n, length(p) + 2); sub(/_all\.ipk$/, "", v); print v; c++ } } END { if (c != 1) exit 1 }' "$1") || return 1
		valid_version "$v" || return 1
		[ -z "$ver" ] || [ "$ver" = "$v" ] || return 1
		ver="$v"
	done
	printf '%s' "$ver"
}

# verify_file DIR NAME: NAME in DIR matches DIR/SHA256SUMS
verify_file() {
	local want
	want=$(sums_hash "$1/SHA256SUMS" "$2") || return 1
	[ -s "$1/$2" ] && [ "$(sha256_of "$1/$2")" = "$want" ]
}

# tag_matches TAG VERSION: v0.9.1 or v0.9.1-r1 for version 0.9.1-r1
tag_matches() {
	[ "$1" = "v$2" ] || [ "$1" = "v${2%-r*}" ]
}

write_state() { # phase status [message] [extra json fields]
	mkdir -p "$STATE_DIR"
	printf '{"phase":"%s","status":"%s","message":"%s","time":%s%s}\n' "$1" "$2" "$(json_escape "${3:-}")" "$(date +%s)" "${4:+,$4}" > "$STATE_FILE.tmp" \
		&& mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

cleanup() {
	[ -n "$WORK" ] && rm -rf "${WORK:?}"
	rmdir "$LOCK_DIR" 2>/dev/null
}

# ---------------------------------------------------------------- check

# do_check [force]: prints {"ok":..,"current":..,"latest":..,"tag":..,
# "available":..,"time":..} and caches it; an error names its reason:
#   not_installed  easy-vless is not an installed package
#   network        the release page could not be reached over HTTPS
#   release        the latest release is not a release of this project
#                  (tag, SHA256SUMS or package versions do not fit)
do_check() {
	local force="${1:-}" now cur tag sums ver age
	now=$(date +%s)
	mkdir -p "$STATE_DIR"
	if [ "$force" != "force" ] && [ -s "$CHECK_FILE" ]; then
		age=$(( now - $(sed -n 's/.*"time":\([0-9]*\).*/\1/p' "$CHECK_FILE" | head -n1) ))
		if [ "$age" -ge 0 ] && { { [ "$age" -lt "$CHECK_MAX_AGE" ] && grep -q '"ok":true' "$CHECK_FILE"; } || [ "$age" -lt "$CHECK_RETRY_AGE" ]; }; then
			cat "$CHECK_FILE"
			return 0
		fi
	fi
	fail() {
		printf '{"ok":false,"error":"%s","detail":"%s","current":"%s","time":%s}\n' "$1" "$(json_escape "$2")" "${cur:-}" "$now" > "$CHECK_FILE.tmp" \
			&& mv -f "$CHECK_FILE.tmp" "$CHECK_FILE"
		cat "$CHECK_FILE"
	}
	cur=$(installed_version)
	if ! valid_version "$cur"; then
		fail not_installed "easy-vless is not installed as a package (version '${cur}')"
		return 1
	fi
	tag=$(latest_tag) || { fail network "the release page ${BASE_URL}/latest did not answer"; return 1; }
	valid_tag "$tag" || { fail release "unexpected release tag"; return 1; }
	sums="$STATE_DIR/SHA256SUMS.check"
	fetch "${BASE_URL}/download/${tag}/SHA256SUMS" "$sums" 15 || { rm -f "$sums"; fail network "SHA256SUMS of ${tag} could not be downloaded"; return 1; }
	ver=$(sums_version "$sums") || { rm -f "$sums"; fail release "SHA256SUMS of ${tag} does not list the three Easy VLESS packages with one version"; return 1; }
	rm -f "$sums"
	tag_matches "$tag" "$ver" || { fail release "release ${tag} contains packages of version ${ver}"; return 1; }
	printf '{"ok":true,"current":"%s","latest":"%s","tag":"%s","available":%s,"time":%s}\n' "$cur" "$ver" "$tag" \
		"$(version_gt "$ver" "$cur" && echo true || echo false)" "$now" > "$CHECK_FILE.tmp" && mv -f "$CHECK_FILE.tmp" "$CHECK_FILE"
	cat "$CHECK_FILE"
}

do_state() {
	local busy=false
	[ -d "$LOCK_DIR" ] && busy=true
	printf '{"ok":true,"busy":%s,"state":%s,"check":%s,"log":"%s"}\n' "$busy" \
		"$( [ -s "$STATE_FILE" ] && cat "$STATE_FILE" || echo null )" \
		"$( [ -s "$CHECK_FILE" ] && cat "$CHECK_FILE" || echo null )" \
		"$(json_escape "$(tail -n 40 "$LOG_FILE" 2>/dev/null | cut -c1-300)")"
}

# ---------------------------------------------------------------- install

# download_release TAG DIR: SHA256SUMS + packages (+ install.sh) of a
# release into DIR, every file verified. Prints the package version.
download_release() {
	local tag="$1" dir="$2" with_installer="${3:-1}" ver p f
	mkdir -p "$dir" || return 1
	fetch "${BASE_URL}/download/${tag}/SHA256SUMS" "$dir/SHA256SUMS" || { echo "SHA256SUMS of ${tag} could not be downloaded"; return 1; }
	ver=$(sums_version "$dir/SHA256SUMS") || { echo "SHA256SUMS of ${tag} does not list the three Easy VLESS packages with one version"; return 1; }
	tag_matches "$tag" "$ver" || { echo "release ${tag} contains packages of version ${ver}"; return 1; }
	for p in $PACKAGES; do
		f="${p}_${ver}_all.ipk"
		fetch "${BASE_URL}/download/${tag}/${f}" "$dir/$f" || { echo "${f} could not be downloaded"; return 1; }
		verify_file "$dir" "$f" || { echo "${f} does not match SHA256SUMS of ${tag}"; return 1; }
	done
	if [ "$with_installer" = 1 ]; then
		fetch "${BASE_URL}/download/${tag}/install.sh" "$dir/install.sh" || { echo "install.sh of ${tag} could not be downloaded"; return 1; }
		verify_file "$dir" install.sh || { echo "install.sh does not match SHA256SUMS of ${tag}"; return 1; }
		# the installer must be the one of this release
		[ "$(sed -n 's/^EV_VERSION="\(.*\)"$/\1/p' "$dir/install.sh" | head -n1)" = "$ver" ] \
			&& [ "$(sed -n 's/^EV_TAG="\(.*\)"$/\1/p' "$dir/install.sh" | head -n1)" = "$tag" ] \
			|| { echo "install.sh is not the installer of ${tag} (${ver})"; return 1; }
	fi
	printf '%s' "$ver"
}

packages_at() { # packages_at VERSION: all three packages are installed in that version
	local p
	for p in $PACKAGES; do
		[ "$(installed_version "$p")" = "$1" ] || return 1
	done
}

service_enabled() {
	[ "$(uci -q get ${CONFIG}.@global[0].enabled 2>/dev/null)" = "1" ]
}

restart_service() {
	if service_enabled; then
		"$INIT" restart >>"$LOG_FILE" 2>&1
	fi
	return 0
}

# rollback OLD_VERSION REASON: previous packages (when they could be
# fetched) and the saved configuration
rollback() {
	local old="$1" reason="$2" ipks="" p ok=1
	log "rollback: $reason"
	if [ -d "$WORK/old" ]; then
		for p in $PACKAGES; do ipks="$ipks $WORK/old/${p}_${old}_all.ipk"; done
		# shellcheck disable=SC2086
		opkg install --force-downgrade --force-reinstall $ipks >>"$LOG_FILE" 2>&1 || ok=0
		packages_at "$old" || ok=0
	else
		packages_at "$old" || ok=0
	fi
	if [ -s "$BACKUP_DIR/config" ]; then
		cp -f "$BACKUP_DIR/config" "$CONFIG_FILE" || ok=0
		[ -s "$BACKUP_DIR/hwid" ] && cp -f "$BACKUP_DIR/hwid" "$HWID_FILE"
	fi
	rm -f "$R/tmp/luci-indexcache" "$R"/tmp/luci-indexcache.* 2>/dev/null
	/etc/init.d/rpcd restart >/dev/null 2>&1
	restart_service
	if [ "$ok" = 1 ]; then
		write_state rolled_back failed "$reason" "\"version\":\"$old\""
	else
		write_state rollback_failed failed "$reason - and the previous version ${old} could not be put back completely: reinstall it with its install.sh; the configuration copy is in ${BACKUP_DIR}" "\"version\":\"$(installed_version)\""
	fi
	return 1
}

do_install() {
	local tag="$1" cur new old_tag msg t
	valid_tag "$tag" || { write_state refused failed "invalid release tag"; return 1; }
	cur=$(installed_version)
	valid_version "$cur" || { write_state refused failed "easy-vless is not installed as a package"; return 1; }
	if [ -e "$INIT_LOCK" ]; then
		write_state refused failed "Easy VLESS is starting or stopping; try again when it has finished"
		return 1
	fi
	mkdir -p "${LOCK_DIR%/*}"
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		echo '{"ok":false,"error":"busy"}'
		return 1
	fi
	trap cleanup EXIT
	trap 'exit 1' INT TERM
	mkdir -p "${LOG_FILE%/*}"
	: > "$LOG_FILE"
	log "update to ${tag} requested (installed: ${cur})"
	WORK=$(mktemp -d "${R}/tmp/${CONFIG}_update.XXXXXX") || { write_state refused failed "cannot create a temporary directory in /tmp"; return 1; }
	chmod 700 "$WORK"

	# 2 + 3: download and verify
	write_state download running "downloading Easy VLESS ${tag}"
	if ! new=$(download_release "$tag" "$WORK/new" 1); then
		log "$new"
		write_state verify failed "$new - nothing was installed"
		return 1
	fi
	if ! version_gt "$new" "$cur"; then
		write_state verify failed "release ${tag} (${new}) is not newer than the installed version ${cur} - nothing was installed"
		return 1
	fi
	log "release files of ${new} verified"

	# 4: compatibility
	write_state compatibility running "checking the router for Easy VLESS ${new}"
	if ! sh "$WORK/new/install.sh" --check --local "$WORK/new" >>"$LOG_FILE" 2>&1; then
		msg=$(grep -E 'ERROR:' "$LOG_FILE" | tail -n 1 | sed 's/^.*ERROR: //')
		write_state compatibility failed "this router does not meet the requirements of ${new}: ${msg:-see the update log} - nothing was installed"
		return 1
	fi

	# 5: configuration copy and the packages for a rollback
	write_state backup running "saving the configuration"
	mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" && cp -f "$CONFIG_FILE" "$BACKUP_DIR/config" \
		|| { write_state backup failed "the configuration could not be saved to ${BACKUP_DIR} - nothing was installed"; return 1; }
	rm -f "$BACKUP_DIR/hwid"
	[ -s "$HWID_FILE" ] && cp -f "$HWID_FILE" "$BACKUP_DIR/hwid"
	printf '%s\n' "$cur" > "$BACKUP_DIR/version"
	for old_tag in "v${cur%-r*}" "v${cur}"; do
		if t=$(download_release "$old_tag" "$WORK/old" 0) && [ "$t" = "$cur" ]; then
			break
		fi
		rm -rf "${WORK:?}/old"
	done
	[ -d "$WORK/old" ] && log "packages of ${cur} fetched for a rollback" || log "packages of ${cur} are not available: a rollback can only restore the configuration"

	# 6: install the verified local files
	write_state install running "installing Easy VLESS ${new}"
	if ! sh "$WORK/new/install.sh" --local "$WORK/new" --no-start >>"$LOG_FILE" 2>&1; then
		msg=$(grep -E 'ERROR:' "$LOG_FILE" | tail -n 1 | sed 's/^.*ERROR: //')
		rollback "$cur" "the installation of ${new} failed: ${msg:-see the update log}"
		return 1
	fi

	# 7: validation
	write_state validate running "checking the installation"
	if ! packages_at "$new"; then
		rollback "$cur" "after the installation the packages are not at version ${new}"
		return 1
	fi
	if [ ! -s "$CONFIG_FILE" ]; then
		rollback "$cur" "the configuration is missing after the installation"
		return 1
	fi
	if [ -n "$(uci -q get ${CONFIG}.@global[0].node 2>/dev/null)" ] && [ -x "$APP" ]; then
		if ! msg=$("$APP" check 2>&1); then
			log "$msg"
			rollback "$cur" "Easy VLESS ${new} does not accept the saved configuration: $(echo "$msg" | tail -n 1)"
			return 1
		fi
	fi

	# 8: service
	write_state restart running "restarting Easy VLESS"
	restart_service
	rm -f "$CHECK_FILE"
	log "updated to ${new}"
	write_state done ok "Easy VLESS ${new} is installed" "\"version\":\"$new\",\"previous\":\"$cur\""
	return 0
}

# ---------------------------------------------------------------- main

[ "${EV_UPDATE_LIB:-0}" = "1" ] && return 0 2>/dev/null

case "${1:-}" in
	check) do_check "${2:-}" ;;
	state) do_state ;;
	install) do_install "${2:-}" ;;
	*)
		echo '{"ok":false,"error":"action"}'
		exit 2
	;;
esac
