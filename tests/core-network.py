#!/usr/bin/env python3
"""Run genuine sing-box-lx client/server sessions with a local HTTPS origin."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HOST = "127.0.0.1"


def free_port():
    with socket.socket() as s:
        s.bind((HOST, 0))
        return s.getsockname()[1]


def wait_listener(process, port):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"core exited {process.returncode} before listening on {port}")
        with contextlib.suppress(OSError), socket.create_connection((HOST, port), 0.2):
            return
        time.sleep(0.05)
    raise RuntimeError(f"listener timeout on {port}")


@contextlib.contextmanager
def core(core_bin, directory, label, config, port, xray=False):
    filename = directory / (label + ".json")
    config["log"] = {"level": "warn"}
    filename.write_text(json.dumps(config))
    check = ["run", "-test"] if xray else ["check"]
    subprocess.run([core_bin, *check, "-c", filename], check=True, timeout=20)
    with (directory / (label + ".log")).open("w+") as log:
        start = time.monotonic()
        process = subprocess.Popen([core_bin, "run", "-c", filename], stdout=log, stderr=log)
        try:
            wait_listener(process, port)
            print(f"{label} listener {time.monotonic() - start:.3f} s", flush=True)
            yield
        except Exception:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        body = b"easy-vless HTTPS fixture\n"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def test(core_bin, directory, xray_bin=None):
    version = subprocess.check_output([core_bin, "version"], text=True, timeout=10)
    assert "sing-box version 1.14.4-lx.35\n" in version
    assert "with_xhttp" in version and "with_clash_api" in version and "with_utls" in version
    key, cert = directory / "key.pem", directory / "cert.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
         "-keyout", key, "-out", cert],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=20,
    )
    origin = http.server.ThreadingHTTPServer((HOST, 0), Handler)
    tls_origin = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_origin.load_cert_chain(cert, key)
    origin.socket = tls_origin.wrap_socket(origin.socket, server_side=True)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    try:
        output = subprocess.check_output([core_bin, "generate", "reality-keypair"], text=True, timeout=10)
        reality_keys = dict(line.split(": ", 1) for line in output.splitlines() if ": " in line)
        for proto, name, transport, flow in (
            ("vless", "tcp", None, None),
            ("vless", "vision", None, "xtls-rprx-vision"),
            ("vless", "reality-vision", None, "xtls-rprx-vision"),
            ("vless", "ws", {"type": "ws", "path": "/test"}, None),
            ("vless", "grpc", {"type": "grpc", "service_name": "test"}, None),
            ("vless", "httpupgrade", {"type": "httpupgrade", "path": "/test"}, None),
            ("trojan", "tcp", None, None),
        ):
            server_port, socks_port = free_port(), free_port()
            user = {"uuid" if proto == "vless" else "password": str(uuid.uuid4())}
            if flow:
                user["flow"] = flow
            inbound = {
                "type": proto, "listen": HOST, "listen_port": server_port, "users": [user],
                "tls": {"enabled": True, "certificate_path": str(cert), "key_path": str(key)},
            }
            outbound = {
                "type": proto, "server": HOST, "server_port": server_port, **user,
                "tls": {"enabled": True, "server_name": "localhost", "certificate_path": str(cert)},
            }
            cover = contextlib.nullcontext()
            if name == "reality-vision":
                cover_port = free_port()
                cover_config = {"inbounds": [{
                    "type": "http", "listen": HOST, "listen_port": cover_port,
                    "tls": {"enabled": True, "certificate_path": str(cert), "key_path": str(key)},
                }], "outbounds": [{"type": "direct"}]}
                cover = core(core_bin, directory, "reality-cover", cover_config, cover_port)
                short_id = "0123456789abcdef"
                inbound["tls"] = {"enabled": True, "server_name": "localhost", "reality": {
                    "enabled": True, "private_key": reality_keys["PrivateKey"], "short_id": [short_id],
                    "handshake": {"server": HOST, "server_port": cover_port},
                }}
                outbound["tls"] = {"enabled": True, "server_name": "localhost",
                                   "utls": {"enabled": True, "fingerprint": "chrome"},
                                   "reality": {"enabled": True, "short_id": short_id,
                                               "public_key": reality_keys["PublicKey"]}}
            if transport:
                inbound["transport"] = outbound["transport"] = transport
            server = {"inbounds": [inbound], "outbounds": [{"type": "direct"}]}
            client = {
                "inbounds": [{"type": "socks", "listen": HOST, "listen_port": socks_port}],
                "outbounds": [outbound],
            }
            with cover, core(core_bin, directory, f"{proto}-{name}-server", server, server_port):
                for round_no in range(2 if name == "tcp" else 1):
                    with core(core_bin, directory, f"{proto}-{name}-client-{round_no}", client, socks_port):
                        response = subprocess.check_output(
                            ["curl", "--noproxy", "", "--proxy", f"socks5h://{HOST}:{socks_port}",
                             "--cacert", cert, "--max-time", "10", "-fsS",
                             f"https://localhost:{origin.server_port}/"], timeout=12,
                        )
                        assert response == b"easy-vless HTTPS fixture\n"
            print(f"PASS {proto}+{name} HTTPS through SOCKS5", flush=True)
        cfg = directory / "client-options.json"
        for mode in ("auto", "packet-up", "stream-up", "stream-one", "invalid"):
            outbound = {
                "type": "vless", "server": HOST, "server_port": 443, "uuid": str(uuid.uuid4()),
                "transport": {"type": "xhttp", "host": "localhost", "path": "/test", "mode": mode},
                "tls": {"enabled": True, "server_name": "localhost"},
            }
            cfg.write_text(json.dumps({"outbounds": [outbound]}))
            checked = subprocess.run([core_bin, "check", "-c", cfg], capture_output=True, timeout=10)
            assert (checked.returncode == 0) == (mode != "invalid"), checked.stderr.decode()
            print(f"PASS XHTTP config mode={mode}", flush=True)
        if xray_bin:
            for mode in ("packet-up", "stream-up", "stream-one"):
                server_port, socks_port = free_port(), free_port()
                user = str(uuid.uuid4())
                server = {"inbounds": [{
                    "protocol": "vless", "listen": HOST, "port": server_port,
                    "settings": {"clients": [{"id": user}], "decryption": "none"},
                    "streamSettings": {
                        "network": "xhttp", "security": "tls",
                        "tlsSettings": {"certificates": [{"certificateFile": str(cert), "keyFile": str(key)}]},
                        "xhttpSettings": {"path": "/test", "mode": mode},
                    },
                }], "outbounds": [{"protocol": "freedom", "settings": {
                    "targetStrategy": "UseIPv4",
                    "finalRules": [{"action": "allow", "network": "tcp",
                                    "ip": [f"{HOST}/32"], "port": str(origin.server_port)}],
                }}]}
                client = {
                    "inbounds": [{"type": "socks", "listen": HOST, "listen_port": socks_port}],
                    "outbounds": [{
                        "type": "vless", "server": HOST, "server_port": server_port, "uuid": user,
                        "transport": {"type": "xhttp", "mode": mode, "path": "/test"},
                        "tls": {"enabled": True, "server_name": "localhost", "certificate_path": str(cert)},
                    }],
                }
                with core(xray_bin, directory, f"xray-{mode}", server, server_port, xray=True):
                    with core(core_bin, directory, f"lx-{mode}", client, socks_port):
                        response = subprocess.check_output(
                            ["curl", "--noproxy", "", "--proxy", f"socks5h://{HOST}:{socks_port}",
                             "--cacert", cert, "--max-time", "10", "-fsS",
                             f"https://localhost:{origin.server_port}/"], timeout=12,
                        )
                        assert response == b"easy-vless HTTPS fixture\n"
                print(f"PASS XHTTP TLS HTTPS with Xray mode={mode}", flush=True)
    finally:
        origin.shutdown()
        origin.server_close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="easy-vless-core-") as tmp:
        xray_bin = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
        test(os.path.abspath(sys.argv[1]), Path(tmp), xray_bin)
