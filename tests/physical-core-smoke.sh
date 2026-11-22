#!/usr/bin/env bash
# The target must be an authorised SSH test router with a trusted host key.
# Starts two temporary loopback-only cores, without touching installed services.
set -euo pipefail
bin=${1:?usage: physical-core-smoke.sh ARM64_CORE SSH_DESTINATION [HTTPS_URL]}
target=${2:?missing SSH destination}
probe=${3:-https://example.com/}
[[ "$probe" == https://* ]]
ssh_cmd=(ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$target")
dir=$("${ssh_cmd[@]}" 'umask 077; mktemp -d /tmp/ev-lx-smoke.XXXXXX')
[[ "$dir" =~ ^/tmp/ev-lx-smoke\.[a-zA-Z0-9]+$ ]]
local_dir=$(mktemp -d)
session=
cleanup() {
	if [[ -n "$session" ]]; then
		"${ssh_cmd[@]}" "touch '$dir/done'" >/dev/null 2>&1 || true
		wait "$session" || true
	fi
	"${ssh_cmd[@]}" "rm -rf '$dir'" >/dev/null 2>&1 || true
	rm -rf "$local_dir"
}
trap cleanup EXIT
"${ssh_cmd[@]}" "cat > '$dir/core' && chmod 700 '$dir/core'" < "$bin"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$local_dir/key.pem" \
	-out "$local_dir/cert.pem" -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost 2>/dev/null
tar -C "$local_dir" -cf - cert.pem key.pem | "${ssh_cmd[@]}" "cd '$dir' && tar -xf -"
sha256sum "$bin"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
	-o ExitOnForwardFailure=yes -L "127.0.0.1:$port:127.0.0.1:49194" "$target" \
	"cd '$dir' && sh -s" > "$local_dir/router.log" 2>&1 <<'SH' &
set -eu
umask 077
./core version
sha256sum ./core
head -4 /proc/meminfo
df -k /overlay /tmp
listening() {
	hex=$(printf '%04X' "$1")
	awk -v hex="$hex" '$4 == "0A" && $2 ~ (":" hex "$") { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6
}
! listening 49193 && ! listening 49194 || exit 1
id=00000000-0000-4000-8000-000000000001
cat > server.json <<JSON
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":49193,"users":[{"uuid":"$id"}],"tls":{"enabled":true,"certificate_path":"$PWD/cert.pem","key_path":"$PWD/key.pem"}}],"outbounds":[{"type":"direct"}]}
JSON
cat > client.json <<JSON
{"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":49194}],"outbounds":[{"type":"vless","server":"127.0.0.1","server_port":49193,"uuid":"$id","tls":{"enabled":true,"server_name":"localhost","certificate_path":"$PWD/cert.pem"}}]}
JSON
server= client=
trap 'for pid in $client $server; do kill "$pid" 2>/dev/null || :; done; wait' EXIT
trap 'exit 1' HUP INT TERM
./core check -c client.json
./core check -c server.json
wait_listener() {
	i=0
	while [ "$i" -lt 10 ]; do
		kill -0 "$1" || return 1
		listening "$2" && return 0
		i=$((i+1))
		sleep 1
	done
	return 1
}
./core run -c server.json > server.log 2>&1 & server=$!
wait_listener "$server" 49193
for round in 1 2; do
	read -r before _ < /proc/uptime
	./core run -c client.json > client.log 2>&1 & client=$!
	wait_listener "$client" 49194 || { tail -8 client.log; exit 1; }
	read -r after _ < /proc/uptime
	awk -v before="$before" -v after="$after" 'BEGIN {printf "startup, polling upper bound: %0.2fs\n", after-before}'
	awk '/^VmRSS:|^VmHWM:/{print "idle", $0}' "/proc/$client/status"
	touch "ready.$round"
	seconds=0
	while [ ! -f "complete.$round" ] && [ ! -f done ] && [ "$seconds" -lt 45 ]; do
		sleep 1; seconds=$((seconds+1))
	done
	[ -f "complete.$round" ] || { tail -8 client.log; tail -8 server.log; exit 1; }
	awk '/^VmRSS:|^VmHWM:/{print "after_https", $0}' "/proc/$client/status"
	kill "$client"
	wait "$client" || :
	client=
	! listening 49194 || exit 1
done
echo "PASS physical VLESS TLS and SOCKS5"
SH
session=$!
for round in 1 2; do
	ready=0
	for i in {1..30}; do
		if "${ssh_cmd[@]}" "test -f '$dir/ready.$round'"; then ready=1; break; fi
		kill -0 "$session" 2>/dev/null || break
		sleep 0.3
	done
	[[ "$ready" = 1 ]] || { cat "$local_dir/router.log" >&2; exit 1; }
	for i in 1 2 3; do
		curl --noproxy '' --proxy "socks5h://127.0.0.1:$port" --max-time 12 -fsS \
			-o /dev/null -w 'https=%{http_code} time=%{time_total}\n' "$probe" || {
			"${ssh_cmd[@]}" "tail -n 8 '$dir/client.log' '$dir/server.log'" >&2 || true
			exit 1
		}
	done
	"${ssh_cmd[@]}" "touch '$dir/complete.$round'"
done
wait "$session"
session=
cat "$local_dir/router.log"
