#!/bin/bash
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: deploy/smoke.sh HOST' >&2; exit 1; }
base=$(cd -- "$(dirname -- "$0")" && pwd)
python3 - "$base" "$1" <<'PY'
import json
import os
from pathlib import Path
import selectors
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

base = Path(sys.argv[1])
host = sys.argv[2]

def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=kwargs.pop("timeout", 20), **kwargs).stdout

def remote(command):
    return run("ssh", "-o", "BatchMode=yes", "me@" + host, command)

with tempfile.TemporaryDirectory(prefix="ko-smoke-") as temporary:
    root = Path(temporary)
    key, cert = root / "device.key", root / "device.pem"
    run("openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key))
    run("openssl", "req", "-new", "-x509", "-key", str(key), "-subj", "/CN=smoke", "-days", "1",
        "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "extendedKeyUsage=clientAuth", "-out", str(cert))
    def curl(*extra):
        return subprocess.run(["curl", "--silent", "--show-error", "--max-time", "10", *extra], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
    for identity in ([], ["-cert", str(cert), "-key", str(key)]):
        result = subprocess.run(["openssl", "s_client", "-connect", host + ":443", "-servername", host, *identity],
                                input=(f"GET /version HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
        assert result.returncode != 0 and b"HTTP/1.1 200" not in result.stdout
    assert curl("https://" + host + "/version").returncode != 0
    assert curl("--cert", str(cert), "--key", str(key), "https://" + host + "/version").returncode != 0
    print("PASS no certificate and unpaired certificate refused", flush=True)
    process = subprocess.Popen(["ssh", "-o", "BatchMode=yes", "me@" + host, "sudo ko-pair"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    assert selector.select(10), "pairing did not print its payload"
    line = process.stdout.readline().decode()
    assert line.startswith("kido-pair: "), line
    payload = json.loads(line[11:])
    selector.close()
    remaining = []
    reader = threading.Thread(target=lambda: remaining.append(process.stdout.read()), daemon=True)
    reader.start()
    enrolled = None
    ws = None
    try:
        request = run("python3", str(base / "enroll-request.py"), str(cert), str(key), "operator smoke test", input=payload["token"].encode())
        response = subprocess.run(["curl", "--fail-with-body", "--silent", "--show-error", "--max-time", "10", "--data-binary", "@-", payload["enroll"]], input=request, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
        assert response.returncode == 0, response.stderr.decode()
        enrolled = json.loads(response.stdout)["fingerprint"]
        process.wait(timeout=20)
        reader.join(timeout=1)
        assert process.returncode == 0 and ("paired operator smoke test " + enrolled).encode() in b"".join(remaining)
        result = curl("--fail", "--cert", str(cert), "--key", str(key), "https://" + host + "/version")
        assert result.returncode == 0, result.stderr.decode()
        version = json.loads(result.stdout)
        context = ssl.create_default_context()
        context.load_cert_chain(cert, key)
        ws = context.wrap_socket(socket.create_connection((host, 443), timeout=5), server_hostname=host)
        request = (f"GET /client HTTP/1.1\r\nHost: {host}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nKo-Protocol: {version['protocol']}\r\nKo-Vt: {version['vt']}\r\n\r\n")
        ws.sendall(request.encode())
        header = b""
        deadline = time.monotonic() + 5
        while b"\r\n\r\n" not in header and len(header) < 16384 and time.monotonic() < deadline:
            chunk = ws.recv(1)
            if not chunk:
                break
            header += chunk
        assert header.startswith(b"HTTP/1.1 101"), header
        def send_frame(opcode, data):
            assert len(data) < 126
            mask = os.urandom(4)
            ws.sendall(bytes([0x80 | opcode, 0x80 | len(data)]) + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

        def read_exact(length):
            result = b""
            while len(result) < length:
                chunk = ws.recv(length - len(result))
                assert chunk, "WebSocket ended before revocation"
                result += chunk
            return result

        def read_frame():
            head = read_exact(2)
            assert not head[1] & 0x80
            length = head[1] & 127
            if length in (126, 127):
                length = int.from_bytes(read_exact(2 if length == 126 else 8), "big")
            assert length <= 16 * 1024 * 1024
            opcode, data = head[0] & 15, read_exact(length)
            assert opcode != 8, "WebSocket closed before revocation"
            if opcode == 9:
                send_frame(10, data)
            return opcode, data

        send_frame(1, b'{"type":"hello","name":"smoke","webview":false,"focused":false,"sizing":{"type":"disabled"}}')
        opcode, answer = read_frame()
        assert opcode == 1 and json.loads(answer)["type"] == "welcome", answer
        for protocol in ("-tls1_2", "-tls1_3"):
            result = run("openssl", "s_client", "-connect", host + ":443", "-servername", host, "-cert", str(cert), "-key", str(key), protocol, "-reconnect", input=b"")
            assert b"Reused," not in result and result.count(b"New,") >= 5
        enroll = payload["enroll"].split("/")[2]
        result = curl("-H", "Host: " + host, "-o", "/dev/null", "-w", "%{http_code}", "https://" + enroll + "/version")
        assert result.stdout == b"421", result
        ping = os.urandom(16)
        send_frame(9, ping)
        deadline = time.monotonic() + 5
        pong = False
        while time.monotonic() < deadline:
            opcode, data = read_frame()
            if opcode == 10 and data == ping:
                pong = True
                break
        assert pong, "WebSocket did not answer the pre-revocation ping"
        remote("sudo ko-revoke " + enrolled)
        enrolled = None
        assert curl("--cert", str(cert), "--key", str(key), "https://" + host + "/version").returncode != 0
        ws.settimeout(5)
        closed = False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            data = ws.recv(65536)
            if not data:
                closed = True
                break
        assert closed, "old WebSocket did not end"
        print("PASS pairing, version, WebSocket, no TLS resumption, SNI/Host 421, revoke", flush=True)
    finally:
        if ws:
            ws.close()
        if enrolled:
            remote("sudo ko-revoke " + enrolled)
        if process.poll() is None:
            process.wait(timeout=125)
        reader.join(timeout=1)
    remote('''set -eu
for user in me caddy; do
  sudo -u "$user" curl --fail --silent --unix-socket /var/lib/ko/socket http://localhost/version >/dev/null
done
if sudo -u nobody curl --fail --silent --unix-socket /var/lib/ko/socket http://localhost/version >/dev/null; then exit 1; fi
if sudo -u nobody test -r /run/caddy/admin.sock; then exit 1; fi
if sudo -u nobody test -x /var/lib/ko-devices; then exit 1; fi
''')
    print("PASS socket admission and private admin/device paths", flush=True)
    scan = run("nmap", "-Pn", "-p-", "--open", "--host-timeout", "5m", "-oG", "-", host, timeout=310).decode()
    import re
    ports = set(re.findall(r"(\d+)/open/tcp", scan))
    assert ports == {"22", "443"}, scan
    print("PASS external TCP ports: 22 and 443 only", flush=True)
PY
