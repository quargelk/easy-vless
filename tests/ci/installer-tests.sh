#!/bin/bash
# Easy VLESS - installer / bootstrap tests (CI, GitHub Actions runner):
#   bash tests/ci/installer-tests.sh <dist dir> [scenario...]
#
# Starts an HTTPS test server on the runner (test CA, a valid and a
# not-yet-valid certificate) serving copies of the release files, then runs
# every scenario of tests/ci/installer-scenarios.sh in its own fresh
# openwrt/rootfs container (default bridge network: nothing runs in the
# runner's network namespace).

set -euo pipefail
W="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$(cd "${1:?usage: $0 <dist dir> [scenario...]}" && pwd)"
shift
SCENARIOS=("$@")
[ ${#SCENARIOS[@]} -gt 0 ] || SCENARIOS=(preflight online rollback bootstrap upgrade)
IMAGE="${OPENWRT_ROOTFS_IMAGE:-openwrt/rootfs:x86-64-24.10.3}"
T="$(mktemp -d)"
GW="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"
V="$(sed -n 's/^EV_VERSION="\(.*\)"$/\1/p' "$W/scripts/install.sh")"
echo "test server address (docker bridge gateway): $GW, Easy VLESS $V"

# ---- certificates: test CA, valid leaf, leaf valid only from +400 days
cd "$T"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 30 -subj "/CN=Easy VLESS test CA" 2>/dev/null
printf 'subjectAltName=IP:%s\n' "$GW" >san.ext
openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=$GW" 2>/dev/null
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ok.crt -days 30 -extfile san.ext 2>/dev/null
mkdir -p db && : >db/index.txt && echo 01 >db/serial
cat >ca.cnf <<'EOF'
[ca]
default_ca = c
[c]
dir = db
database = db/index.txt
serial = db/serial
new_certs_dir = db
default_md = sha256
policy = p
copy_extensions = none
[p]
commonName = supplied
EOF
openssl ca -batch -config ca.cnf -cert ca.crt -keyfile ca.key -in srv.csr -out future.crt \
	-startdate "$(date -u -d '+400 days' +%y%m%d%H%M%SZ)" -enddate "$(date -u -d '+430 days' +%y%m%d%H%M%SZ)" \
	-extfile san.ext -notext 2>/dev/null
openssl x509 -in future.crt -noout -startdate

# ---- served release variants
S="$T/www"
mkdir -p "$S/ok" "$S/missing" "$S/tampered" "$S/badsums" "$S/empty"
cp "$DIST"/*.ipk "$DIST"/SHA256SUMS "$S/ok/"
cp "$DIST"/*.ipk "$DIST"/SHA256SUMS "$S/missing/" && rm "$S/missing/luci-app-easy-vless_${V}_all.ipk"
cp "$DIST"/*.ipk "$DIST"/SHA256SUMS "$S/tampered/" && printf 'x' >>"$S/tampered/easy-vless_${V}_all.ipk"
cp "$DIST"/*.ipk "$S/badsums/" && grep -v "  easy-vless_${V}_all.ipk\$" "$DIST/SHA256SUMS" >"$S/badsums/SHA256SUMS"
: >"$S/empty/SHA256SUMS"

cat >server.py <<'EOF'
import http.server, ssl, sys, functools
root, host, port, cert, key = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
httpd = http.server.ThreadingHTTPServer((host, port), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
EOF
python3 server.py "$S" "$GW" 8443 ok.crt srv.key >srv-ok.log 2>&1 &
P1=$!
python3 server.py "$S" "$GW" 8444 future.crt srv.key >srv-future.log 2>&1 &
P2=$!
trap 'kill $P1 $P2 2>/dev/null; rm -rf "$T"' EXIT
sleep 1
curl -fsS --cacert ca.crt "https://$GW:8443/ok/SHA256SUMS" >/dev/null && echo "test server ready"

cd "$W"
failed=()
for sc in "${SCENARIOS[@]}"; do
	echo
	echo "################ scenario: $sc"
	if docker run --rm \
		-v "$W:/w:ro" -v "$DIST:/dist:ro" -v "$T/ca.crt:/tls/ca.crt:ro" \
		-e W=/w -e DIST=/dist -e TEST_CA=/tls/ca.crt \
		-e SRV="https://$GW:8443" -e SRV_FUTURE="https://$GW:8444" \
		"$IMAGE" /bin/ash /w/tests/ci/installer-scenarios.sh "$sc"; then
		echo "scenario $sc: OK"
	else
		echo "scenario $sc: FAILED"
		failed+=("$sc")
	fi
done
echo
if [ ${#failed[@]} -gt 0 ]; then
	echo "===== installer tests FAILED: ${failed[*]} ====="
	exit 1
fi
echo "===== installer tests: all scenarios passed (${SCENARIOS[*]}) ====="
