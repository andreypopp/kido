#!/usr/bin/env python3
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, **kwargs).stdout


token = sys.stdin.read().strip()
cert, key, name, *message_output = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="ko-enroll-", dir="/tmp") as temporary:
    root = Path(temporary)
    (root / "token").write_bytes(base64.urlsafe_b64decode(token + "="))
    der = run("openssl", "x509", "-in", cert, "-outform", "DER")
    (root / "der").write_bytes(der)
    message = run("bash", "-c", '{ printf "kido-enroll-v1\\000"; openssl dgst -sha256 -binary "$1/token"; openssl dgst -sha256 -binary "$1/der"; }', "bash", str(root))
    (root / "message").write_bytes(message)
    if message_output:
        Path(message_output[0]).write_bytes(message)
    signature = run("openssl", "dgst", "-sha256", "-sign", key, str(root / "message"))
    print(json.dumps({"token": token, "name": name, "certificate": base64.b64encode(der).decode(), "signature": base64.b64encode(signature).decode()}))
