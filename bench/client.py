#!/usr/bin/env python3
import base64
import fcntl
import http.client
import json
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time

if len(sys.argv) != 1:
    raise SystemExit("usage: bench/client.py")
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
subprocess.run(["dune", "build", "@install"], cwd=root, check=True)
exe = os.path.join(root, "_build/install/default/bin/ko")
with tempfile.TemporaryDirectory(prefix="ko-client-", dir="/tmp") as directory:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("KO_", "KIDO_", "TMUX", "XDG_", "BASH_FUNC_")) and k not in ("HOME", "ENV", "BASH_ENV", "ZDOTDIR")}
    env.update(HOME=directory, XDG_CONFIG_HOME=directory, XDG_STATE_HOME=directory, SHELL="/bin/sh", TERM="xterm-ghostty")
    log = open(directory + "/server.log", "wb")
    server = subprocess.Popen([exe, "server", "--server", directory, "--shell", "/bin/sh", "--scrollback", "80M"], env=env, stdout=log, stderr=log)
    pid = None
    fd = None
    vt = json.loads(subprocess.check_output([exe, "version"], env=env))["vt"]

    def request(method, path, body=None):
        connection = http.client.HTTPConnection("ko", timeout=5)
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.settimeout(5)
        connection.sock.connect(directory + "/socket")
        encoded = json.dumps(body).encode() if body is not None else b""
        connection.request(method, path, encoded, {"Ko-Protocol": "1.0", "Ko-Vt": vt})
        response = connection.getresponse()
        data = response.read()
        if response.status != 200:
            raise RuntimeError((response.status, data))
        connection.close()
        return data

    def create(command):
        return json.loads(request("POST", "/panes", {"command": ["/bin/sh", "-c", command], "cwd": directory}))["pane"]

    tail = b""
    def read_until(marker, deadline):
        global tail
        pending = b""
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            data = os.read(fd, 1 << 20)
            if not data:
                raise RuntimeError("client closed")
            pending += data
            tail = (tail + data)[-8000:]
            for match in re.finditer(rb"\x1b\[\?(\d+)\$p", pending):
                os.write(fd, b"\x1b[?" + match[1] + b";2$y")
            if b"\x1b[?u" in pending:
                os.write(fd, b"\x1b[?0u")
            if b"\x1b[c" in pending:
                os.write(fd, b"\x1b[?62;22c")
            if b"\x1b[6n" in pending:
                os.write(fd, b"\x1b[1;1R")
            plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", pending)
            if marker is not None and marker in plain:
                return time.monotonic()
            pending = pending[-32:]
        if marker is not None:
            raise RuntimeError("frame deadline: " + repr(marker) + " output: " + repr(tail[-1000:]))

    def usage():
        fields = subprocess.check_output(["ps", "-o", "time=,rss=", "-p", str(pid)], text=True).split()
        seconds = 0.0
        for part in fields[0].split(":"):
            seconds = seconds * 60 + float(part)
        return seconds, int(fields[1]) / 1024

    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                request("GET", "/version")
                break
            except (OSError, http.client.HTTPException):
                if time.monotonic() >= deadline or server.poll() is not None:
                    raise
                select.select([], [], [], min(0.01, deadline - time.monotonic()))
        program = "import os,tty\ntty.setraw(0)\nos.write(1,b'BENCH-READY')\nn=0\nwhile True:\n os.read(0,1)\n n+=1\n os.write(1,bytes([65+n%26])*8)"
        import shlex
        create("exec python3 -c " + shlex.quote(program))
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
            os.execve(exe, [exe, "--server", directory], env)
        read_until(b"BENCH-READY", time.monotonic() + 5)
        samples = []
        for n in range(1, 201):
            began = time.monotonic()
            os.write(fd, b"x")
            ended = read_until(bytes([65 + n % 26]) * 8, began + 2)
            samples.append((ended - began) * 1000)
        samples.sort()
        print(f"quiet key-to-frame: p50 {samples[100]:.3f} ms p99 {samples[198]:.3f} ms (n=200)", flush=True)
        yes = create("exec yes")
        os.write(fd, b"\x1b[1;6B")
        read_until(b"y" * 20, time.monotonic() + 5)
        before, _ = usage()
        began = time.monotonic()
        read_until(None, began + 5)
        after, memory = usage()
        print(f"shown yes: CPU {(after-before)/(time.monotonic()-began):.3f} cores, RSS {memory:.2f} MiB (5 s)", flush=True)
        request("POST", f"/panes/{yes}/input", {"text": base64.b64encode(b"\x03").decode()})
        marker = directory + "/large-ready"
        create("seq 100000; printf 'LARGE-READY\\r\\n'; touch " + shlex.quote(marker) + "; exec /bin/sh")
        deadline = time.monotonic() + 5
        while not os.path.exists(marker):
            if time.monotonic() >= deadline:
                raise RuntimeError("large history deadline")
            select.select([], [], [], min(0.01, deadline - time.monotonic()))
        os.write(fd, b"\x1b[1;6B")
        read_until(b"LARGE-READY", time.monotonic() + 5)
        _, memory = usage()
        print(f"100k-line mirror: RSS {memory:.2f} MiB", flush=True)
        os.write(fd, b"\x1b[113;6u")
    finally:
        if pid:
            deadline = time.monotonic() + 3
            while True:
                ended, status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    break
                if time.monotonic() >= deadline:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                    break
                if fd is not None:
                    ready, _, _ = select.select([fd], [], [], 0.02)
                    if ready:
                        try:
                            os.read(fd, 1 << 20)
                        except OSError:
                            pass
            os.close(fd)
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=3)
        log.close()
        if server.returncode:
            print(open(directory + "/server.log").read(), file=sys.stderr)
