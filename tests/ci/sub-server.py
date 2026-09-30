#!/usr/bin/env python3
"""Easy VLESS - subscription test server (CI, tests/ci/wizard-tests.sh).

A plain HTTP server in its own container on the docker bridge network; the
router container downloads subscriptions from it with subscribe.lua. Every
request is recorded (path, User-Agent, X-HWID / X-Device-* headers) and can
be read back with GET /_log (and cleared with GET /_reset), so the tests can
check which requests the router made - and how many.

  GOOD_LINK / BAD_LINK   vless:// links of the VLESS test server (a working
                         server and a closed port), put into the lists

Paths:
  /plain /b64 /clash /singbox   the two servers as a plain vless:// list, a
                                base64 list, Clash YAML, sing-box JSON (plus
                                an unsupported ss:// / vmess entry)
  /empty /html /unsupported     200 without a supported VLESS server
  /happ-403                     403 unless User-Agent contains HAPP
  /happ-200                     200 with an app placeholder (no VLESS server)
                                unless User-Agent contains HAPP
  /hwid                         404 unless X-HWID (16+ chars) and
                                X-Device-OS are sent (the tests check
                                X-Ver-OS / X-Device-Model in /_log)
  /slow                         the plain list after 8 s
  /status/<code>                that HTTP status
  /count/<name>                 the plain list; servers named "<name> ..."
"""

import base64
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote

GOOD = os.environ["GOOD_LINK"]
BAD = os.environ["BAD_LINK"]
LOG = []
LOCK = threading.Lock()


def named(link, name):
    return re.sub(r"#.*$", "", link) + "#" + quote(name)


def parts(link):
    m = re.match(r"vless://([^@]+)@([^:]+):(\d+)", link)
    return m.group(1), m.group(2), int(m.group(3))


def plain(prefix="Sub"):
    return "\n".join([
        named(GOOD, prefix + " Good"),
        named(BAD, prefix + " Closed"),
        "ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#" + quote(prefix + " Shadowsocks"),
    ]) + "\n"


def clash():
    out = ["proxies:"]
    for link, name in ((GOOD, "Clash Good"), (BAD, "Clash Closed")):
        uuid, host, port = parts(link)
        out += ["  - name: \"%s\"" % name, "    type: vless", "    server: %s" % host, "    port: %d" % port,
                "    uuid: %s" % uuid, "    network: tcp", "    tls: false", "    udp: true"]
    out += ["  - name: \"Clash SS\"", "    type: ss", "    server: 192.0.2.1", "    port: 8388",
            "    cipher: aes-256-gcm", "    password: test-only"]
    return "\n".join(out) + "\n"


def singbox():
    obs = []
    for link, name in ((GOOD, "JSON Good"), (BAD, "JSON Closed")):
        uuid, host, port = parts(link)
        obs.append({"type": "vless", "tag": name, "server": host, "server_port": port, "uuid": uuid})
    obs.append({"type": "vmess", "tag": "JSON VMess", "server": "192.0.2.1", "server_port": 443,
                "uuid": "00000000-0000-4000-8000-000000000003"})
    obs.append({"type": "direct", "tag": "direct"})
    return json.dumps({"outbounds": obs}, indent=1) + "\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[sub-server] %s %s\n" % (self.address_string(), fmt % args))

    def send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        h = self.headers
        if path == "/_log":
            with LOCK:
                return self.send(200, json.dumps(LOG), "application/json")
        if path == "/_reset":
            with LOCK:
                LOG.clear()
            return self.send(200, "ok\n")
        ua = h.get("User-Agent", "")
        rec = {"path": path, "ua": ua, "hwid": h.get("X-HWID", ""), "os": h.get("X-Device-OS", ""),
               "ver": h.get("X-Ver-OS", ""), "model": h.get("X-Device-Model", ""), "time": time.time()}
        with LOCK:
            LOG.append(rec)
        happ = "happ" in ua.lower()
        if path == "/plain":
            return self.send(200, plain("Plain"))
        if path == "/b64":
            return self.send(200, base64.b64encode(plain("B64").encode()).decode() + "\n")
        if path == "/clash":
            return self.send(200, clash(), "text/yaml")
        if path == "/singbox":
            return self.send(200, singbox(), "application/json")
        if path == "/empty":
            return self.send(200, "")
        if path == "/html":
            return self.send(200, "<!doctype html><html><body><h1>Welcome</h1><p>Open this link in your app.</p></body></html>\n", "text/html")
        if path == "/unsupported":
            return self.send(200, "ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#only-ss\n"
                                  "trojan://secret@192.0.2.1:443#only-trojan\n")
        if path == "/happ-403":
            return self.send(200, plain("Happ")) if happ else self.send(403, "Forbidden: use the app\n")
        if path == "/happ-200":
            return self.send(200, plain("Happ")) if happ else self.send(200, "Please open this subscription in the HAPP app.\n")
        if path == "/hwid":
            ok = len(rec["hwid"]) >= 16 and rec["os"]
            return self.send(200, plain("Hwid")) if ok else self.send(404, "Not found\n")
        if path == "/slow":
            time.sleep(8)
            return self.send(200, plain("Slow"))
        m = re.match(r"^/status/(\d{3})$", path)
        if m:
            return self.send(int(m.group(1)), "status %s\n" % m.group(1))
        m = re.match(r"^/count/([A-Za-z0-9]+)$", path)
        if m:
            return self.send(200, plain(m.group(1)))
        return self.send(404, "unknown path\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    print("subscription test server on port %d" % port, flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
