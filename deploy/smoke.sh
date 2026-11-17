#!/bin/bash
set -euo pipefail
[[ $# == 1 || $# == 2 ]] || { echo 'usage: deploy/smoke.sh HOST [ADDRESS]' >&2; exit 1; }
base=$(cd -- "$(dirname -- "$0")" && pwd)
python3 - "$base" "$@" <<'PY'
import errno
import json
import os
from pathlib import Path
import selectors
import shlex
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

if b"HTTP3" not in subprocess.check_output(["curl", "-V"]).split():
    raise SystemExit("deploy/smoke.sh needs a curl with HTTP/3")

base = Path(sys.argv[1])
host = sys.argv[2]
address = sys.argv[3] if len(sys.argv) == 4 else host
ssh = shlex.split(os.environ.get("KO_SMOKE_SSH", "ssh"))

def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=kwargs.pop("timeout", 20), **kwargs).stdout

def remote(command):
    return run(*ssh, "-o", "BatchMode=yes", "me@" + address, command)

with tempfile.TemporaryDirectory(prefix="ko-smoke-") as temporary:
    root = Path(temporary)
    key, cert = root / "device.key", root / "device.pem"
    run("openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key))
    run("openssl", "req", "-new", "-x509", "-key", str(key), "-subj", "/CN=smoke", "-days", "1",
        "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "extendedKeyUsage=clientAuth", "-out", str(cert))
    def curl(*extra):
        return subprocess.run(["curl", "--silent", "--show-error", "--max-time", "10", *resolves, *extra], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
    resolves = ["--resolve", f"{host}:443:{address}"] if address != host else []
    for identity in ([], ["-cert", str(cert), "-key", str(key)]):
        result = subprocess.run(["openssl", "s_client", "-ign_eof", "-connect", address + ":443", "-servername", host, *identity],
                                input=(f"GET /version HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
        output = result.stdout + result.stderr
        alert = b"bad certificate" if identity else b"certificate required"
        assert b"HTTP/1." not in output and alert in output.lower(), output
    assert curl("https://" + host + "/version").returncode != 0
    assert curl("--cert", str(cert), "--key", str(key), "https://" + host + "/version").returncode != 0
    assert curl("--http3-only", "https://" + host + "/version").returncode != 0
    print("PASS no certificate and unpaired certificate refused, HTTP/3 without certificate refused", flush=True)
    errors = root / "pair-errors"
    with errors.open("wb") as stream:
        process = subprocess.Popen([*ssh, "-o", "BatchMode=yes", "me@" + address, "sudo ko-pair"], stdout=subprocess.PIPE, stderr=stream)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    if not selector.select(10):
        process.terminate()
        process.wait(timeout=5)
        raise AssertionError("pairing did not print its payload: " + errors.read_text())
    line = process.stdout.readline().decode()
    assert line.startswith("kido-pair: "), (line, errors.read_text())
    payload = json.loads(line[11:])
    selector.close()
    remaining = []
    reader = threading.Thread(target=lambda: remaining.append(process.stdout.read()), daemon=True)
    reader.start()
    enrolled = None
    ws = None
    try:
        request = run("python3", str(base / "enroll-request.py"), str(cert), str(key), "operator smoke test", input=payload["token"].encode())
        enroll = payload["enroll"].split("/")[2]
        if address != host:
            resolves += ["--resolve", f"{enroll}:443:{address}"]
        fallback = curl("-o", "/dev/null", "-w", "%{http_code}", "https://" + enroll + "/version")
        assert fallback.returncode == 0 and fallback.stdout == b"404", fallback
        response = subprocess.run(["curl", *resolves, "--fail-with-body", "--silent", "--show-error", "--max-time", "10", "--data-binary", "@-", payload["enroll"]], input=request, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
        assert response.returncode == 0, response.stderr.decode()
        enrolled = json.loads(response.stdout)["fingerprint"]
        process.wait(timeout=20)
        reader.join(timeout=1)
        assert process.returncode == 0 and ("paired operator smoke test " + enrolled).encode() in b"".join(remaining)
        result = curl("--fail", "--cert", str(cert), "--key", str(key), "https://" + host + "/version")
        assert result.returncode == 0, result.stderr.decode()
        version = json.loads(result.stdout)
        result = curl("--http3-only", "--cert", str(cert), "--key", str(key), "-o", "/dev/null",
                      "-w", "%{http_code} %{http_version}", "https://" + host + "/version")
        assert result.returncode == 0 and result.stdout == b"200 3", result
        context = ssl.create_default_context()
        context.load_cert_chain(cert, key)
        ws = context.wrap_socket(socket.create_connection((address, 443), timeout=5), server_hostname=host)
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
            result = run("openssl", "s_client", "-connect", address + ":443", "-servername", host, "-cert", str(cert), "-key", str(key), protocol, "-reconnect", input=b"")
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
        result = curl("--http3-only", "-o", "/dev/null", "-w", "%{http_code} %{http_version}",
                      "https://" + enroll + "/version")
        assert result.returncode == 0 and result.stdout == b"404 3", result
        assert curl("--http3-only", "--cert", str(cert), "--key", str(key), "https://" + host + "/version").returncode != 0
        ws.settimeout(5)
        closed = False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            data = ws.recv(65536)
            if not data:
                closed = True
                break
        assert closed, "old WebSocket did not end"
        print("PASS pairing, version, HTTP/3 200 3, WebSocket, no TLS resumption, SNI/Host 421, revoke including HTTP/3", flush=True)
    finally:
        if ws:
            ws.close()
        if enrolled:
            remote("sudo ko-revoke " + enrolled)
        if process.poll() is None:
            abort = json.dumps({"token": payload["token"], "name": "smoke cleanup", "certificate": "!", "signature": "!"}).encode()
            subprocess.run([*ssh, "-o", "BatchMode=yes", "me@" + address,
                '''curl --silent --max-time 5 --data-binary @- "http://127.0.0.1:$(python3 -c 'import json; print(json.load(open("/etc/ko-pair.json"))["port"])')/v1/enroll"'''], input=abort, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            process.wait(timeout=10)
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
    family, _, _, _, endpoint = socket.getaddrinfo(address, 443, type=socket.SOCK_STREAM)[0]
    deadline = time.monotonic() + 120
    ports = set()
    pending = {}
    port = 1
    with selectors.DefaultSelector() as selector:
        while port <= 65535 or pending:
            now = time.monotonic()
            assert now < deadline, "TCP scan deadline"
            while port <= 65535 and len(pending) < 500:
                connection = socket.socket(family, socket.SOCK_STREAM)
                connection.setblocking(False)
                status = connection.connect_ex((endpoint[0], port, *endpoint[2:]))
                if status == 0:
                    ports.add(port)
                    connection.close()
                elif status in (errno.EINPROGRESS, errno.EWOULDBLOCK):
                    pending[connection] = (port, now + 0.5)
                    selector.register(connection, selectors.EVENT_WRITE)
                else:
                    connection.close()
                if port % 10000 == 0:
                    print(f"TCP scan: {port}/65535", flush=True)
                port += 1
            wait = min((expires - time.monotonic() for _, expires in pending.values()), default=0)
            ready = {key.fileobj for key, _ in selector.select(max(0, min(wait, deadline - time.monotonic())))}
            for connection, (number, expires) in list(pending.items()):
                if connection in ready or time.monotonic() >= expires:
                    if connection in ready and connection.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0:
                        ports.add(number)
                    selector.unregister(connection)
                    connection.close()
                    del pending[connection]
    assert ports == {22, 443}, ports
    nonce = os.urandom(32)
    catcher = '''import json, selectors, socket, sys, time
nonce = bytes.fromhex(sys.argv[1])
ports = set()
deadline = time.monotonic() + 90
with selectors.DefaultSelector() as selector:
    sockets = []
    for family in (socket.AF_INET, socket.AF_INET6):
        raw = socket.socket(family, socket.SOCK_RAW, socket.IPPROTO_UDP)
        raw.setblocking(False)
        sockets.append(raw)
        selector.register(raw, selectors.EVENT_READ)
    selector.register(sys.stdin, selectors.EVENT_READ)
    print("ready", flush=True)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit("UDP catcher deadline")
        ready = selector.select(remaining)
        finished = any(key.fileobj is sys.stdin and not sys.stdin.read(1) for key, _ in ready)
        for raw in sockets:
            while True:
                if time.monotonic() >= deadline:
                    raise SystemExit("UDP catcher deadline")
                try:
                    data = raw.recv(65535)
                except BlockingIOError:
                    break
                offset = (data[0] & 15) * 4 if raw.family == socket.AF_INET else 0
                if data[offset + 8:] == nonce:
                    ports.add(int.from_bytes(data[offset + 2:offset + 4], "big"))
        if finished:
            print(json.dumps(sorted(ports)), flush=True)
            sys.exit(0)
'''
    process = subprocess.Popen([*ssh, "-o", "BatchMode=yes", "me@" + address,
                                "sudo python3 -c " + shlex.quote(catcher) + " " + nonce.hex()],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(10), "UDP catcher readiness deadline"
            assert process.stdout.readline() == b"ready\n", "UDP catcher did not become ready"
        deadline = time.monotonic() + 40
        with socket.socket(family, socket.SOCK_DGRAM) as sender:
            for _ in range(2):
                for port in range(1, 65536):
                    while True:
                        assert time.monotonic() < deadline, "UDP scan deadline"
                        try:
                            sender.sendto(nonce, (endpoint[0], port, *endpoint[2:]))
                            break
                        except OSError as error:
                            if error.errno != errno.ENOBUFS:
                                raise
                            time.sleep(0.01)
                    if port % 256 == 0:
                        time.sleep(0.005)
        time.sleep(1)
        output, errors = process.communicate(timeout=10)
        assert process.returncode == 0, errors.decode()
        assert json.loads(output) == [443], output
    finally:
        if process.poll() is None:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
    print("PASS external ports: TCP 22 and 443, UDP 443 only", flush=True)
PY
