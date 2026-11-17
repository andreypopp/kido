#!/bin/bash
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")" && pwd)
python3 - "$base" <<'PY'
import json
import os
from pathlib import Path
import socket
import selectors
import subprocess
import sys
import tempfile
import time

base = Path(sys.argv[1])

def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, **kwargs).stdout

with tempfile.TemporaryDirectory(prefix="ko-devices-", dir="/tmp") as temporary:
    root = Path(temporary)
    devices = root / "devices"
    devices.mkdir(mode=0o750)
    stubs = root / "bin"
    stubs.mkdir()
    caddy = stubs / "caddy"
    caddy.write_text('#!/bin/sh\n[ "$*" = "validate --config /etc/caddy/Caddyfile" ] || exit 9\ntest ! -e "$KO_DEVICES_DIR/fail-validation"\n')
    caddy.chmod(0o755)
    restart = root / "restart"
    restart.write_text('''#!/usr/bin/python3
import os
from pathlib import Path
folder = Path(os.environ["KO_DEVICES_DIR"])
for output in folder.parent.glob("out-*"):
    assert "paired test device" not in output.read_text()
for pem in folder.glob("*.pem"):
    assert pem.with_suffix(".json").is_file()
with (folder / "restarts").open("a") as stream:
    stream.write(str(len(list(folder.glob("*.pem")))) + "\\n")
''')
    restart.chmod(0o755)
    env = {**os.environ, "PATH": str(stubs) + ":" + os.environ["PATH"],
           "KO_DEVICES_DIR": str(devices), "KO_PAIR_RESTART": str(restart), "KO_PAIR_SECONDS": "3"}
    run("openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(root / "other.key"))
    for kind, key, ca in (("ca", root / "other.key", "TRUE"), ("rsa", root / "rsa.key", "FALSE")):
        if kind == "rsa":
            run("openssl", "genrsa", "-out", str(key), "2048")
        run("openssl", "req", "-new", "-x509", "-key", str(key), "-subj", "/CN=test", "-days", "1",
            "-addext", "basicConstraints=critical,CA:" + ca, "-addext", "extendedKeyUsage=clientAuth",
            "-out", str(root / (kind + ".pem")))
    fixed = base / "testdata/device.pem"

    fixed_token = (base / "testdata/token").read_text().strip()
    run("python3", str(base / "enroll-request.py"), str(fixed), str(base / "testdata/device.key"), "test device", str(root / "message"), input=fixed_token.encode())
    assert (root / "message").read_bytes().hex() == (base / "testdata/message.hex").read_text().strip()
    print("PASS fixed OpenSSL message vector", flush=True)
    serial = 0

    def start(fixed_token_run=False, seconds="3"):
        global serial
        serial += 1
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        local = {**env, "KO_PAIR_SECONDS": seconds}
        output = root / f"out-{serial}"
        errors = root / f"err-{serial}"
        args = [str(base / "ko-pair"), "ko.example.test", str(port)]
        if fixed_token_run:
            args[1:1] = ["--name", "Test Server"]
            args = ["python3", "-c", 'import runpy,secrets,sys; secrets.token_bytes=lambda n: bytes(range(n)); sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name="__main__")', *args]
        with output.open("wb") as stdout, errors.open("wb") as stderr:
            process = subprocess.Popen(args, env=local, stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            lines = output.read_text().splitlines()
            if lines and lines[0].startswith("kido-pair: "):
                payload = json.loads(lines[0][11:])
                return process, payload, port, output, errors
            if process.poll() is not None:
                raise AssertionError(errors.read_text())
            time.sleep(0.01)
        raise AssertionError("pairing did not print payload")

    def body(payload, cert=fixed, key=base / "testdata/device.key", signed_token=None):
        request = json.loads(run("python3", str(base / "enroll-request.py"), str(cert), str(key), "test device", input=(signed_token or payload["token"]).encode()))
        request["token"] = payload["token"]
        return request

    def post(port, data, headers=(), path="/v1/enroll"):
        encoded = data if isinstance(data, bytes) else json.dumps(data).encode()
        result = subprocess.run(["curl", "--silent", "--show-error", "--max-time", "6", "-o", str(root / "response"), "-w", "%{http_code}",
                                 *headers, "--data-binary", "@-", f"http://127.0.0.1:{port}{path}"], input=encoded, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=7)
        return result.returncode, result.stdout.decode()

    def finish(state, expected):
        process, payload, port, output, errors = state
        assert process.wait(timeout=7) == expected, errors.read_text()
        logs = errors.read_text()
        assert payload["token"] not in logs and '"certificate"' not in logs and '"signature"' not in logs
        assert '"certificate"' not in output.read_text()
        assert payload["token"] not in "\n".join(output.read_text().splitlines()[1:])
        return output.read_text(), logs

    state = start(True)
    request = body(state[1])
    assert state[1]["token"] == fixed_token
    assert state[3].read_text().splitlines()[0] + "\n" == (base / "testdata/payload").read_text()
    assert post(state[2], request, ("-H", "X-Forwarded-For: 192.0.2.4")) == (0, "200")
    response = json.loads((root / "response").read_text())
    fp = response["fingerprint"]
    output, logs = finish(state, 0)
    assert f"paired test device {fp}" in output and "192.0.2.4" in logs
    for suffix in (".pem", ".json"):
        assert (devices / (fp + suffix)).stat().st_mode & 0o777 == 0o640
    assert devices.stat().st_mode & 0o777 == 0o750
    assert (devices / "restarts").read_text() == "1\n"
    assert post(state[2], request)[0] != 0
    assert fp in run(str(base / "ko-devices"), env=env).decode()
    for previous in root.glob("out-*"):
        previous.rename(previous.with_name(previous.name.replace("out-", "finished-")))
    run(str(base / "ko-revoke"), fp[:8], env=env)
    assert not list(devices.glob("*.pem")) and not list(devices.glob("*.json"))
    assert (devices / "restarts").read_text() == "1\n0\n"
    print("PASS pairing, single use, modes, logs, list, revoke, restart ordering", flush=True)

    for name in ("", "x" * 65, "bad\nname", "bad\x85name"):
        result = subprocess.run([str(base / "ko-pair"), "--name", name, "ko.example.test", "1"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        assert result.returncode == 2 and b"usage:" in result.stderr and not result.stdout
    state = start(seconds="60")
    assert state[1]["name"] == socket.gethostname()
    print("PASS server names, default hostname, invalid name usage errors", flush=True)
    with socket.create_connection(("127.0.0.1", state[2]), timeout=1) as connection:
        connection.sendall(b"POST /v1/enroll HTTP/1.0\r\nContent-Length: 8193\r\n\r\n")
        assert b"400" in connection.recv(1024)
    assert post(state[2], [])[1] == "400"
    assert post(state[2], b"x" * 8193)[1] == "400"
    assert post(state[2], {}, path="/wrong")[1] == "400"
    with socket.create_connection(("127.0.0.1", state[2]), timeout=1) as connection:
        connection.sendall(b"POST /v1/enroll HTTP/1.0\r\nContent-Length: 100\r\n\r\n")
        started = time.monotonic()
        deadline = started + 6
        with selectors.DefaultSelector() as selector:
            selector.register(connection, selectors.EVENT_READ)
            response = b""
            while time.monotonic() < deadline:
                if selector.select(0.2):
                    response = connection.recv(1024)
                    break
                connection.sendall(b"x")
        assert b"400" in response, response
        assert 4.5 <= time.monotonic() - started < 6
    invalid = {"token": state[1]["token"], "name": "test", "certificate": "!", "signature": "!"}
    assert post(state[2], invalid)[1] == "400"
    assert state[0].wait(timeout=1) == 1
    finish(state, 1)
    print("PASS shape, sizes, path, absolute 5 s deadline, malformed DER consumes token", flush=True)

    for label in ("ca", "rsa", "other-token", "other-key", "bad-signature-encoding", "validation", "wrong-token", "request-cap", "expiry"):
        state = start(seconds="0.3" if label == "expiry" else "60")
        if label == "expiry":
            finish(state, 1)
        elif label == "request-cap":
            for index in range(30):
                assert post(state[2], b"{}")[1] == ("429" if index == 29 else "400")
            assert state[0].wait(timeout=1) == 1
            finish(state, 1)
        elif label == "wrong-token":
            request = {"token": fixed_token, "name": "test", "certificate": "!", "signature": "!"}
            for _ in range(5):
                assert post(state[2], request)[1] == "403"
            assert state[0].wait(timeout=1) == 1
            finish(state, 1)
        else:
            cert = root / (label + ".pem") if label in ("ca", "rsa") else fixed
            key = root / "other.key" if label == "other-key" else base / "testdata/device.key"
            request = body(state[1], cert, key, signed_token=fixed_token if label == "other-token" else None)
            if label == "bad-signature-encoding":
                request["signature"] = "!"
            elif label == "validation":
                (devices / "fail-validation").touch()
            assert post(state[2], request)[1] == "400", label
            assert state[0].wait(timeout=1) == 1, label
            finish(state, 1)
        (devices / "fail-validation").unlink(missing_ok=True)
        assert not list(devices.glob("*.pem")) and not list(devices.glob("*.json")), label
        print("PASS " + label, flush=True)
PY
