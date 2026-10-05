#!/bin/bash
# Easy VLESS - First Run Wizard tests (CI, GitHub Actions runner):
#   bash tests/ci/wizard-tests.sh <dist dir>
#
# Two containers of the same OpenWrt rootfs image (OPENWRT_ROOTFS_IMAGE,
# DOCKER_PLATFORM as in installer-tests.sh) on the default bridge network:
#   evw     the router: Easy VLESS installed from <dist dir>
#           (tests/ci/wizard-setup.sh), NET_ADMIN for its own nftables
#   evsrv   a real VLESS server: the router's own sing-box binary with a
#           VLESS inbound (no TLS) and a direct outbound; 1.1: also a Trojan
#           inbound with TLS (self-signed certificate made here)
#   evsub   subscription test server (tests/ci/sub-server.py, Python image
#           of the runner's architecture): subscription formats, failures,
#           User-Agent / HWID request strategy; records every request
# Then:
#   tests/ci/wizard-backend-tests.sh   ubus/rpcd calls of the wizard
#   tests/ci/v09-backend-tests.sh      0.9: Route Explain, diagnostics and
#                                      their races, node list, backup / import
#   tests/ci/trojan-backend-tests.sh   1.1: Trojan links, configuration,
#                                      tests, mixed subscriptions, backup
#   WIZARD_E2E=1: tests/ci/luci_wizard_e2e.py, the LuCI wizard in headless
#   Chromium (Playwright) against uhttpd/LuCI of the router container;
#   screenshots in $SHOTS (default ./wizard-shots).

set -euo pipefail
W="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$(cd "${1:?usage: $0 <dist dir>}" && pwd)"
IMAGE="${OPENWRT_ROOTFS_IMAGE:-openwrt/rootfs:x86-64-24.10.3}"
PLATFORM=()
[ -z "${DOCKER_PLATFORM:-}" ] || PLATFORM=(--platform "$DOCKER_PLATFORM")
E2E="${WIZARD_E2E:-0}"
SHOTS="${SHOTS:-$PWD/wizard-shots}"
T="$(mktemp -d)"

cleanup() {
	echo "---- router container: Easy VLESS log (last 80 lines)"
	docker exec evw sh -c 'tail -n 80 /tmp/log/easy_vless.log 2>/dev/null' || true
	echo "---- VLESS test server log (last 40 lines)"
	docker exec evsrv sh -c 'tail -n 40 /tmp/server.log 2>/dev/null' || true
	echo "---- subscription test server log (last 30 lines)"
	docker logs --tail 30 evsub 2>&1 || true
	docker rm -f evw evsrv evsub >/dev/null 2>&1 || true
	rm -rf "$T"
}
trap cleanup EXIT

# nftables TPROXY/socket expressions of the router container are kernel
# modules of the runner (a container cannot load modules itself)
for m in nft_tproxy nft_socket nf_tproxy_ipv4 nf_tproxy_ipv6 nf_socket_ipv4 nf_socket_ipv6 nft_nat nft_chain_nat nft_redir nft_fib nft_fib_inet; do
	sudo modprobe "$m" 2>/dev/null && echo "module $m loaded" || echo "module $m: not available (built in or missing)"
done

docker rm -f evw evsrv evsub >/dev/null 2>&1 || true
docker run -d --name evsrv "${PLATFORM[@]}" "$IMAGE" /bin/ash -c 'while :; do sleep 3600; done' >/dev/null
PORTS=()
[ "$E2E" != "1" ] || PORTS=(-p 127.0.0.1:8080:80)
docker run -d --name evw "${PLATFORM[@]}" --cap-add NET_ADMIN --cap-add NET_RAW "${PORTS[@]}" \
	-v "$W:/w:ro" -v "$DIST:/dist:ro" -e W=/w -e DIST=/dist \
	"$IMAGE" /bin/ash -c 'while :; do sleep 3600; done' >/dev/null

echo "################ setup of the router container"
docker exec -e WITH_LUCI="$E2E" evw /bin/ash /w/tests/ci/wizard-setup.sh

echo "################ VLESS test server"
docker cp -L evw:/usr/bin/sing-box "$T/sing-box"
docker cp "$T/sing-box" evsrv:/usr/bin/sing-box
# Trojan inbound (1.1): TLS with a self-signed certificate for trojan.test,
# made for this run only; the password is a test value
TROJAN_PW="trojan-test-$(openssl rand -hex 8)"
export TROJAN_PW
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=trojan.test" \
	-addext "subjectAltName=DNS:trojan.test,DNS:strict.trojan.test" \
	-keyout "$T/trojan.key" -out "$T/trojan.crt" >/dev/null 2>&1
chmod 644 "$T/trojan.key" "$T/trojan.crt"
TROJAN_USER="$(printf '{ "name": "trojan-test", "%s": "%s" }' password "$TROJAN_PW")"
docker cp "$T/trojan.key" evsrv:/tmp/trojan.key
docker cp "$T/trojan.crt" evsrv:/tmp/trojan.crt
cat >"$T/server.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "vless", "tag": "vless-in", "listen": "0.0.0.0", "listen_port": 20443,
      "users": [ { "name": "wizard-test", "uuid": "00000000-0000-4000-8000-000000000001" } ] },
    { "type": "trojan", "tag": "trojan-in", "listen": "0.0.0.0", "listen_port": 20445,
      "users": [ ${TROJAN_USER} ],
      "tls": { "enabled": true, "server_name": "trojan.test", "certificate_path": "/tmp/trojan.crt", "key_path": "/tmp/trojan.key" } }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
docker cp "$T/server.json" evsrv:/tmp/server.json
docker exec evsrv /usr/bin/sing-box check -c /tmp/server.json
docker exec -d evsrv /bin/ash -c '/usr/bin/sing-box run -c /tmp/server.json >/tmp/server.log 2>&1'
SRV_IP="$(docker inspect -f '{{.NetworkSettings.IPAddress}}' evsrv)"
for i in $(seq 1 20); do
	docker exec evsrv sh -c 'netstat -ltn 2>/dev/null | grep -q ":20443 "' && break
	sleep 1
done
docker exec evsrv sh -c 'netstat -ltn | grep ":20443 "' || { docker exec evsrv cat /tmp/server.log; echo "VLESS test server did not start"; exit 1; }
docker exec evsrv sh -c 'netstat -ltn | grep ":20445 "' || { docker exec evsrv cat /tmp/server.log; echo "Trojan test server did not start"; exit 1; }
echo "VLESS test server: sing-box $(docker exec evsrv /usr/bin/sing-box version | awk 'NR==1{print $3}') on $SRV_IP:20443"
GOOD_LINK="vless://00000000-0000-4000-8000-000000000001@${SRV_IP}:20443?type=tcp&encryption=none&security=none#Wizard%20Test"
BAD_LINK="vless://00000000-0000-4000-8000-000000000002@${SRV_IP}:20444?type=tcp&encryption=none&security=none#Closed%20Port"
# the certificate is self-signed: the first link accepts it (allowInsecure=1),
# the second one verifies it and must fail
TROJAN_LINK="trojan://${TROJAN_PW}@${SRV_IP}:20445?security=tls&sni=trojan.test&type=tcp&allowInsecure=1#Trojan%20Test"
TROJAN_STRICT_LINK="trojan://${TROJAN_PW}@${SRV_IP}:20445?security=tls&sni=strict.trojan.test&type=tcp#Trojan%20Strict"
echo "Trojan test server: $SRV_IP:20445 (TLS, self-signed certificate for trojan.test)"

echo "################ subscription test server"
docker run -d --name evsub -e GOOD_LINK="$GOOD_LINK" -e BAD_LINK="$BAD_LINK" \
	-e TROJAN_LINK="$TROJAN_LINK" -e TROJAN_STRICT_LINK="$TROJAN_STRICT_LINK" -e PYTHONUNBUFFERED=1 \
	-v "$W/tests/ci:/t:ro" python:3.12-alpine python3 /t/sub-server.py 18080 >/dev/null
SUB_IP="$(docker inspect -f '{{.NetworkSettings.IPAddress}}' evsub)"
SUB_URL="http://${SUB_IP}:18080"
for i in $(seq 1 30); do
	docker exec evw sh -c "curl -s -o /dev/null --max-time 3 '$SUB_URL/_reset'" && break
	sleep 1
done
docker exec evw sh -c "curl -s --max-time 3 '$SUB_URL/plain'" | grep -q "^vless://" || { docker logs evsub; echo "subscription test server does not answer"; exit 1; }
echo "subscription test server: $SUB_URL"

echo "################ wizard backend tests (ubus)"
docker exec -e GOOD_LINK="$GOOD_LINK" -e BAD_LINK="$BAD_LINK" -e SUB_URL="$SUB_URL" evw /bin/ash /w/tests/ci/wizard-backend-tests.sh

echo "################ 0.9 backend tests (ubus): Route Explain, diagnostics, node list, backup"
docker exec -e GOOD_LINK="$GOOD_LINK" -e BAD_LINK="$BAD_LINK" -e SUB_URL="$SUB_URL" evw /bin/ash /w/tests/ci/v09-backend-tests.sh

echo "################ 1.1 Trojan backend tests (ubus): links, configuration, tests, subscriptions, backup"
docker exec -e GOOD_LINK="$GOOD_LINK" -e TROJAN_LINK="$TROJAN_LINK" -e TROJAN_STRICT_LINK="$TROJAN_STRICT_LINK" \
	-e TROJAN_PW -e SUB_URL="$SUB_URL" evw /bin/ash /w/tests/ci/trojan-backend-tests.sh

[ "$E2E" = "1" ] || exit 0

echo "################ LuCI wizard end-to-end (headless Chromium)"
docker exec evw /bin/ash /w/tests/ci/wizard-backend-tests.sh reset
# test login password for this throw-away container, never stored
PW="$(openssl rand -hex 12)"
docker exec evw /bin/ash -c "printf '%s\n%s\n' '$PW' '$PW' | passwd root >/dev/null"
mkdir -p "$SHOTS"
EV_BASE="http://127.0.0.1:8080" EV_PASSWORD="$PW" EV_CONTAINER=evw EV_SHOTS="$SHOTS" \
	GOOD_LINK="$GOOD_LINK" BAD_LINK="$BAD_LINK" SUB_URL="$SUB_URL" TROJAN_LINK="$TROJAN_LINK" \
	python3 "$W/tests/ci/luci_wizard_e2e.py"
