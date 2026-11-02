#!/usr/bin/env python3
"""usage: KIDO_TMUX=path/to/kido-tmux [KO_BIN=build/ko/bin/ko] bench/client.py [latency] [yes] [attach] [resize] [memory] [scroll] [busy] [idle]

KO_BIN names the ko to measure (a reference build); without it `make build-ko` runs and build/ko/bin/ko is measured."""
import base64
import fcntl
import http.client
import json
import os
import pty
import re
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROWS, PANE_COLS, SIDEBAR = 30, 95, 25
BUSY = (
    "import os,sys,threading,time,tty\n"
    "os.write(1,b''.join(b'line %06d the quick brown fox jumps over the lazy dog 0123456789\\r\\n'%i for i in range(100000)))\n"
    "tty.setraw(0)\n"
    "def writer():\n"
    " n=0\n"
    " while True:\n"
    "  time.sleep(0.1)\n"
    "  if os.path.exists(sys.argv[1]):\n"
    "   n+=1\n"
    "   os.write(1,b'\\r\\n%d'%n)\n"
    "threading.Thread(target=writer,daemon=True).start()\n"
    "os.write(1,b'BENCH-READY')\n"
    "n=0\n"
    "while True:\n"
    " os.read(0,1)\n"
    " n+=1\n"
    " os.write(1,chr(0x4e00+n).encode())"
)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ECHO = "import os,tty\ntty.setraw(0)\nos.write(1,b'BENCH-READY')\nn=0\nwhile True:\n os.read(0,1)\n n+=1\n os.write(1,b'<%04d>'%n)"
HISTORY_LINES = 100000
HISTORY = rf"""awk 'BEGIN{{for(i=1;i<={HISTORY_LINES};i++) printf "line %06d the quick brown fox jumps over the lazy dog 0123456789\n", i}}'"""
WHEEL_UP = b"\x1b[<64;40;10M"
CSI = rb"\x1b\[[0-?]*[ -/]*[@-~]"


def scrubbed(**extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("KO_", "KIDO_", "TMUX", "XDG_", "BASH_FUNC_")) and k not in ("HOME", "ENV", "BASH_ENV", "ZDOTDIR")}
    env.update(extra)
    return env


def pct(samples, p):
    s = sorted(samples)
    return s[min(len(s) - 1, int(len(s) * p / 100))]


def stats(samples):
    return f"p50 {pct(samples, 50):.2f} / p99 {pct(samples, 99):.2f} ms (n={len(samples)})"


def signal_child(pid, sig):
    assert 1 < pid <= 0x7FFFFFFF and pid not in (os.getpid(), os.getpgrp())
    os.kill(pid, sig)


def cpu(pid):
    total = 0.0
    for part in subprocess.check_output(["ps", "-o", "time=", "-p", str(pid)], text=True).strip().split(":"):
        total = total * 60 + float(part)
    return total


def cores(pids, before, span):
    return ", ".join(f"{(cpu(p) - b) / span:.2f}" for p, b in zip(pids, before))


def rss(pid):
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True)) / 1024


def footprint(pid):
    with tempfile.TemporaryDirectory(prefix="p13-fp-") as d:
        subprocess.run(["footprint", "-p", str(pid), "-j", d + "/f.json"], stdout=subprocess.DEVNULL, check=True)
        with open(d + "/f.json") as f:
            return json.load(f)["processes"][0]["footprint"] / 1048576


def memory(label, pid):
    print(f"{label}: RSS {rss(pid):.1f} MiB, footprint {footprint(pid):.1f} MiB", flush=True)


def children(pid):
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def load():
    return f"load {os.getloadavg()[0]:.2f}"


def readable(fd, timeout):
    return select.select([fd], [], [], max(0, timeout))[0]


class Screen:
    TOKEN = re.compile(rb"\x1b\[([0-?]*)[ -/]*([@-~])|\x1b[\]P_^][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[^\[\]P_^]|\r|\n|[^\x1b\r\n]+")

    def __init__(self):
        self.cells, self.row, self.col, self.rest = {}, 0, 0, b""

    def feed(self, data):
        data, self.rest, i = self.rest + data, b"", 0
        while i < len(data):
            m = self.TOKEN.match(data, i)
            if not m:
                self.rest = data[i:]
                return
            i = m.end()
            token = m.group(0)
            if m.group(2) == b"H":
                row, _, col = m.group(1).partition(b";")
                self.row, self.col = int(row or 1) - 1, int(col or 1) - 1
            elif token == b"\r":
                self.col = 0
            elif token == b"\n":
                self.row += 1
            elif token[0] != 0x1b:
                for ch in token.decode("utf-8", "replace"):
                    self.cells[self.row, self.col] = ch
                    self.col += 1

    def lowest_line(self):
        rows = {}
        for (r, c), ch in self.cells.items():
            rows.setdefault(r, {})[c] = ch
        numbers = [int(n) for row in rows.values() for n in re.findall(rb"line (\d{6})", "".join(row.get(c, " ") for c in range(max(row) + 1)).encode())]
        return min(numbers, default=None)


class Outer:

    def __init__(self, argv, env, rows, cols, track=False):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            os.execve(argv[0], argv, env)
        self.frames = 0
        self.probes = 0
        self.screen = Screen() if track else None

    def settle(self, rows, cols):
        began = time.monotonic()
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        last = began
        while readable(self.fd, 0.05):
            self.feed()
            last = time.monotonic()
        return (last - began) * 1000

    def feed(self):
        data = os.read(self.fd, 1 << 20)
        if not data:
            raise RuntimeError("client closed")
        for match in re.finditer(rb"\x1b\[\?(\d+)\$p", data):
            os.write(self.fd, b"\x1b[?" + match[1] + b";2$y")
        if b"\x1b[?u" in data:
            os.write(self.fd, b"\x1b[?0u")
        if b"\x1b[c" in data:
            os.write(self.fd, b"\x1b[?62;22c")
        for _ in range(data.count(b"\x1b[6n")):
            self.probes += 1
            os.write(self.fd, b"\x1b[1;%dR" % (2 if self.probes % 2 else 3))
        self.frames += data.count(b"\x1b[?2026l")
        if self.screen:
            self.screen.feed(data)
        return data

    def wait(self, pattern, timeout=10):
        end = time.monotonic() + timeout
        regex = re.compile(pattern)
        plain = b""
        while time.monotonic() < end:
            if readable(self.fd, end - time.monotonic()):
                plain += re.sub(CSI, b"", self.feed())
                if regex.search(plain):
                    return time.monotonic()
                plain = plain[-64:]
        raise RuntimeError(f"deadline for {pattern!r}")

    def collect(self, duration):
        end = time.monotonic() + duration
        chunks = []
        while time.monotonic() < end:
            if readable(self.fd, end - time.monotonic()):
                chunks.append((time.monotonic(), self.feed()))
        return chunks

    def quiet(self, gap=0.05, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if not readable(self.fd, gap):
                return
            self.feed()
        raise RuntimeError("never quiet")

    def open_history(self):
        end = time.monotonic() + 10
        while time.monotonic() < end:
            os.write(self.fd, WHEEL_UP)
            self.collect(0.002)
            if (self.screen.lowest_line() or HISTORY_LINES) <= HISTORY_LINES - ROWS:
                return time.monotonic()
        raise RuntimeError("history never scrolled")

    def close(self):
        try:
            signal_child(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        end = time.monotonic() + 3
        while time.monotonic() < end:
            if os.waitpid(self.pid, os.WNOHANG)[0]:
                break
            if readable(self.fd, 0.02):
                try:
                    os.read(self.fd, 1 << 20)
                except OSError:
                    pass
        else:
            signal_child(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


class WebSocket:
    def __init__(self, directory, vt, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(directory + "/socket")
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: ko\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                           f"Sec-WebSocket-Version: 13\r\nKo-Protocol: 2.0\r\nKo-Vt: {vt}\r\n\r\n").encode())
        self.buffer = b""
        while b"\r\n\r\n" not in self.buffer:
            self.buffer += self.sock.recv(65536)
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise RuntimeError(head)

    def send(self, value):
        payload = json.dumps(value).encode()
        mask = os.urandom(4)
        n = len(payload)
        header = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def need(self, n):
        while len(self.buffer) < n:
            data = self.sock.recv(1 << 20)
            if not data:
                raise RuntimeError("websocket closed")
            self.buffer += data

    def receive(self):
        self.need(2)
        opcode, length, at = self.buffer[0] & 15, self.buffer[1] & 127, 2
        if length == 126:
            self.need(4)
            length, at = struct.unpack(">H", self.buffer[2:4])[0], 4
        elif length == 127:
            self.need(10)
            length, at = struct.unpack(">Q", self.buffer[2:10])[0], 10
        self.need(at + length)
        payload = self.buffer[at:at + length]
        self.buffer = self.buffer[at + length:]
        return opcode, payload

    def snapshot(self):
        first = None
        while True:
            opcode, data = self.receive()
            if opcode == 2 and len(data) >= 11 and data[0] == 2:
                first = first or time.monotonic()
                if data[9] & 2:
                    return first, time.monotonic()


class Ko:
    def __init__(self, scrollback="200M"):
        self.dir = tempfile.mkdtemp(prefix="p13-ko-", dir="/tmp")
        self.exe = os.environ.get("KO_BIN") or os.path.join(ROOT, "build/ko/bin/ko")
        self.env = scrubbed(HOME=self.dir, XDG_CONFIG_HOME=self.dir, XDG_STATE_HOME=self.dir, SHELL="/bin/sh", TERM="xterm-ghostty")
        self.log = open(self.dir + "/server.log", "wb")
        self.server = subprocess.Popen([self.exe, "server", "--server", self.dir, "--shell", "/bin/sh", "--scrollback-bytes", scrollback], env=self.env, stdout=self.log, stderr=self.log)
        self.vt = json.loads(subprocess.check_output([self.exe, "version"], env=self.env))["vt"]
        self.clients = []
        end = time.monotonic() + 5
        while True:
            try:
                self.request("GET", "/version")
                break
            except (OSError, http.client.HTTPException):
                if time.monotonic() >= end or self.server.poll() is not None:
                    raise
                time.sleep(0.01)

    def request(self, method, path, body=None):
        connection = http.client.HTTPConnection("ko", timeout=10)
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.settimeout(10)
        connection.sock.connect(self.dir + "/socket")
        connection.request(method, path, json.dumps(body).encode() if body is not None else b"", {"Ko-Protocol": "2.0", "Ko-Vt": self.vt})
        response = connection.getresponse()
        data = response.read()
        if response.status != 200:
            raise RuntimeError((response.status, data))
        connection.close()
        return data

    def pane(self, command):
        return json.loads(self.request("POST", "/panes", {"command": {"type": "argv", "argv": ["/bin/sh", "-c", command]}, "cwd": self.dir}))["pane"]

    def screen(self, pane):
        return self.request("GET", f"/panes/{pane}/screen?history=none").decode(errors="replace")

    def attach(self):
        c = Outer([self.exe, "--server", self.dir], self.env, ROWS, PANE_COLS + SIDEBAR, track=True)
        self.clients.append(c)
        return c

    def claim(self, pane):
        self.sizing = WebSocket(self.dir, self.vt, "/client")
        self.sizing.send({"type": "hello", "kind": "terminal", "name": "bench", "pane": pane, "focused": True, "size": {"cols": PANE_COLS, "rows": ROWS, "cell_px": {"width": 8, "height": 16}}})
        self.sizing.receive()
        self.sizing.receive()

    def pids(self):
        return self.server.pid, children(self.server.pid)

    def close(self):
        for c in self.clients:
            c.close()
        self.server.terminate()
        try:
            self.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait()
        self.log.close()
        subprocess.run(["rm", "-rf", self.dir])


class Tmux:
    def __init__(self):
        self.exe = os.environ["KIDO_TMUX"]
        self.dir = tempfile.mkdtemp(prefix="p13-tmux-", dir="/tmp")
        self.sock = self.dir + "/socket"
        with open(self.dir + "/conf", "w") as f:
            f.write("set -g status off\nset -g history-limit 200000\nset -g mouse on\nset -g escape-time 0\n")
        self.env = scrubbed(TERM="xterm-256color", SHELL="/bin/sh")
        self.clients = []

    def run(self, *args):
        return subprocess.run([self.exe, "-S", self.sock, "-f", self.dir + "/conf", *args], env=self.env, capture_output=True, text=True, check=True).stdout

    def pane(self, command):
        self.run("new-session", "-d", "-x", str(PANE_COLS), "-y", str(ROWS), "/bin/sh", "-c", command)

    def screen(self, pane):
        return self.run("capture-pane", "-p")

    def claim(self, pane):
        pass

    def attach(self):
        c = Outer([self.exe, "-S", self.sock, "-f", self.dir + "/conf", "attach"], self.env, ROWS, PANE_COLS)
        self.clients.append(c)
        return c

    def pids(self):
        return int(self.run("display", "-p", "#{pid}")), []

    def close(self):
        for c in self.clients:
            c.close()
        subprocess.run([self.exe, "-S", self.sock, "kill-server"], capture_output=True)
        subprocess.run(["rm", "-rf", self.dir])


def wait_screen(target, pane, needle, timeout=30):
    end = time.monotonic() + timeout
    while needle not in target.screen(pane):
        if time.monotonic() > end:
            raise RuntimeError(f"pane never showed {needle!r}")
        time.sleep(0.02)


def history_pane(target):
    gate = target.dir + "/gate"
    pane = target.pane(f"until [ -e {gate} ]; do sleep 0.01; done; stty size > {gate}.size; {HISTORY}; exec sleep 3000")
    target.claim(pane)
    open(gate, "w").close()
    wait_screen(target, pane, f"line {HISTORY_LINES}")
    if open(gate + ".size").read().split() != [str(ROWS), str(PANE_COLS)]:
        raise RuntimeError("history producer did not run at the benchmark size")
    return pane


def raw_latency(count):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("python3", ["python3", "-c", ECHO])
    samples = []
    try:
        buffer = b""
        while b"BENCH-READY" not in buffer:
            buffer += os.read(fd, 4096)
        for n in range(1, count + 1):
            time.sleep(0.01)
            began = time.monotonic()
            os.write(fd, b"x")
            buffer = b""
            while b"<%04d>" % n not in buffer:
                buffer += os.read(fd, 4096)
            samples.append((time.monotonic() - began) * 1000)
    finally:
        signal_child(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        os.close(fd)
    return samples


def latency(count=500):
    print(f"== keystroke echo, quiet pane, {count} samples 10 ms apart ({load()})", flush=True)
    raw = raw_latency(count)
    print(f"raw pty (python round trip): {stats(raw)}", flush=True)
    for name, make in (("tmux client", Tmux), ("ko client", Ko)):
        target = make()
        try:
            target.pane("exec python3 -c " + shlex.quote(ECHO))
            c = target.attach()
            c.wait(rb"BENCH-READY")
            samples = []
            for n in range(1, count + 1):
                time.sleep(0.01)
                began = time.monotonic()
                os.write(c.fd, b"x")
                samples.append((c.wait(rb"<%04d>" % n, 2) - began) * 1000)
            print(f"{name}, key to frame: {stats(samples)}; added over raw p50 {pct(samples, 50) - pct(raw, 50):.2f} / p99 {pct(samples, 99) - pct(raw, 99):.2f} ms", flush=True)
            if isinstance(target, Ko):
                view = WebSocket(target.dir, target.vt, "/panes/pane_1/view?history=none")
                view.snapshot()
                hop = []
                for n in range(count + 1, 2 * count + 1):
                    time.sleep(0.01)
                    began = time.monotonic()
                    view.send({"type": "input", "input": {"type": "text", "data": base64.b64encode(b"x").decode()}})
                    while True:
                        opcode, data = view.receive()
                        if opcode == 2 and data[0] == 1 and b"<%04d>" % n in data[9:]:
                            break
                    hop.append((time.monotonic() - began) * 1000)
                print(f"ko view, no client (input event to output record): {stats(hop)}; added over raw p50 {pct(hop, 50) - pct(raw, 50):.2f} / p99 {pct(hop, 99) - pct(raw, 99):.2f} ms", flush=True)
        finally:
            target.close()


def busy_row(count=300):
    print(f"== keystroke echo in a 100k-line pane, quiet and with a line every 100 ms from the start ({load()})", flush=True)
    for name, loaded in (("quiet", False), ("a line every 100 ms", True)):
        ko = Ko()
        try:
            gate = ko.dir + "/load"
            if loaded:
                open(gate, "w").close()
            ko.pane(f"exec python3 -c {shlex.quote(BUSY)} {gate}")
            c = ko.attach()
            began = c.wait(rb"BENCH-READY", 60)
            kid = children(ko.server.pid)[0]
            time.sleep(max(0, 5 - (time.monotonic() - began)))
            footprint_5s = footprint(kid)
            samples = []
            for n in range(1, count + 1):
                time.sleep(0.01)
                while readable(c.fd, 0):
                    c.feed()
                sent = time.monotonic()
                os.write(c.fd, b"x")
                samples.append((c.wait(chr(0x4e00 + n).encode(), 2) - sent) * 1000)
            print(f"ko, {name}: key to frame {stats(samples)}; ko-pane footprint {footprint_5s:.1f} MiB after 5 s, {footprint(kid):.1f} MiB at the end", flush=True)
        finally:
            ko.close()


def yes_row():
    print(f"== yes for 5 s in a shown pane ({load()})", flush=True)
    for name, make in (("tmux", Tmux), ("ko", Ko)):
        target = make()
        try:
            target.pane("exec yes")
            c = target.attach()
            c.wait(b"y")
            server, kids = target.pids()
            pids = [server, c.pid, *kids]
            before = [cpu(p) for p in pids]
            memory_before, frames, began = rss(server), c.frames, time.monotonic()
            c.collect(5)
            span = time.monotonic() - began
            used = cores(pids, before, span)
            print(f"{name}: CPU {used} cores ({'server, client' + (', ko-pane' if kids else '')}); frames {(c.frames - frames) / span:.0f}/s; server RSS {memory_before:.1f} to {rss(server):.1f} MiB", flush=True)
        finally:
            target.close()


def attach_row():
    print(f"== attach to a pane with 100k lines, warm server, new client process ({load()})", flush=True)
    tmux = Tmux()
    try:
        history_pane(tmux)
        began = time.monotonic()
        c = tmux.attach()
        shown = c.wait(rb"line 100000") - began
        began = time.monotonic()
        out = tmux.run("capture-pane", "-p", "-S", "-")
        print(f"tmux: attach, screen visible {shown * 1000:.0f} ms; then capture-pane -S - ({len(out) / 1e6:.1f} MB) {(time.monotonic() - began) * 1000:.0f} ms", flush=True)
    finally:
        tmux.close()
    ko = Ko()
    try:
        pane = history_pane(ko)
        time.sleep(1)
        began = time.monotonic()
        c = ko.attach()
        shown = c.wait(rb"line 100000") - began
        loaded = c.open_history() - began
        print(f"ko: attach, screen visible {shown * 1000:.0f} ms; first wheel scroll that changes the screen (history in the mirror) {loaded * 1000:.0f} ms", flush=True)
        view = WebSocket(ko.dir, ko.vt, f"/panes/{pane}/view?history=all")
        began = time.monotonic()
        first, last = view.snapshot()
        print(f"ko protocol, view history=all: first slice {(first - began) * 1000:.0f} ms, last slice {(last - began) * 1000:.0f} ms", flush=True)
    finally:
        ko.close()


def resize_row():
    print(f"== resize a pane with 100k lines, 95 and 60 columns alternately ({load()})", flush=True)
    tmux = Tmux()
    try:
        history_pane(tmux)
        tmux.run("set", "-g", "window-size", "manual")
        base = []
        for _ in range(20):
            began = time.monotonic()
            tmux.run("display", "-p", "x")
            base.append((time.monotonic() - began) * 1000)
        samples = []
        for n in range(20):
            began = time.monotonic()
            tmux.run("resize-window", "-x", str(60 if n % 2 == 0 else PANE_COLS), "-y", str(ROWS))
            samples.append((time.monotonic() - began) * 1000)
        print(f"tmux resize-window: command wall {stats(samples)}, empty command p50 {pct(base, 50):.1f} ms", flush=True)
    finally:
        tmux.close()
    tmux = Tmux()
    try:
        history_pane(tmux)
        c = tmux.attach()
        c.wait(rb"line 100000")
        c.quiet()
        shown = [c.settle(ROWS, PANE_COLS - 35 if n % 2 == 0 else PANE_COLS) for n in range(20)]
        print(f"tmux client: outer pty resize to the last output: {stats(shown)}", flush=True)
    finally:
        tmux.close()
    ko = Ko()
    try:
        pane = history_pane(ko)
        for history, name in (("none", "screen snapshot READY"), ("all", "marker of a full view")):
            view = WebSocket(ko.dir, ko.vt, f"/panes/{pane}/view?history={history}")
            view.snapshot()
            samples = []
            for n in range(20):
                cols = 60 if n % 2 == 0 else PANE_COLS
                began = time.monotonic()
                ko.sizing.send({"type": "size", "cols": cols, "rows": ROWS, "cell_px": {"width": 8, "height": 16}})
                if history == "none":
                    view.snapshot()
                else:
                    while True:
                        opcode, data = view.receive()
                        if opcode == 1 and b'"marked"' in data:
                            break
                samples.append((time.monotonic() - began) * 1000)
            print(f"ko: size sent to the {name}: {stats(samples)}", flush=True)
        c = ko.attach()
        c.wait(rb"line 100000")
        c.open_history()
        c.quiet()
        shown = [c.settle(ROWS, PANE_COLS + SIDEBAR - 35 if n % 2 == 0 else PANE_COLS + SIDEBAR) for n in range(20)]
        print(f"ko client: outer pty resize to the last output: {stats(shown)}", flush=True)
    finally:
        ko.close()


def memory_row():
    print(f"== memory ({load()})", flush=True)
    ko = Ko()
    try:
        time.sleep(1)
        memory("ko coordinator, idle, no panes", ko.server.pid)
        pane = ko.pane("exec sleep 3000")
        time.sleep(1)
        kid = children(ko.server.pid)[0]
        memory("ko-pane, idle", kid)
        ko.request("DELETE", f"/panes/{pane}")
        pane = history_pane(ko)
        kid = children(ko.server.pid)[0]
        memory("ko-pane, 100k lines, just written", kid)
        time.sleep(3)
        memory("ko-pane, 100k lines, 3 s idle", kid)
        memory("ko coordinator, 100k-line pane", ko.server.pid)
        c = ko.attach()
        c.wait(rb"line 100000")
        c.open_history()
        c.quiet()
        memory("ko client, 100k-line mirror, just loaded", c.pid)
        time.sleep(3)
        memory("ko client, 100k-line mirror, 3 s idle", c.pid)
    finally:
        ko.close()
    tmux = Tmux()
    try:
        history_pane(tmux)
        memory("tmux server, 100k-line pane", tmux.pids()[0])
        c = tmux.attach()
        c.wait(rb"line 100000")
        c.quiet()
        memory("tmux client", c.pid)
    finally:
        tmux.close()


IDLE_SECONDS = 10


def idle_row():
    print(f"== idle wakeups of the coordinator, three idle panes, {IDLE_SECONDS} s ({load()})", flush=True)
    ko = Ko()
    try:
        for _ in range(3):
            pane = ko.pane("printf READY; while read x; do :; done")
            wait_screen(ko, pane, "READY")
        client = ko.attach()
        client.quiet()
        report = os.path.join(ko.dir, "idle.txt")
        if sys.platform == "darwin":
            command = ["sample", str(ko.server.pid), str(IDLE_SECONDS), "-file", report]
        else:
            command = ["strace", "-c", "-f", "-p", str(ko.server.pid), "-o", report]
        tool = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        time.sleep(IDLE_SECONDS)
        if tool.poll() is None and sys.platform != "darwin":
            signal_child(tool.pid, signal.SIGINT)
        _, errors = tool.communicate(timeout=30)
        if tool.returncode not in (0, -signal.SIGINT) or (sys.platform != "darwin" and "attached" not in errors):
            raise RuntimeError(f"{command[0]} did not trace the coordinator (status {tool.returncode}): {errors}")
        with open(report) as f:
            # strace -c prints no table when the process made no system call.
            print(f.read() or f"no system call in {IDLE_SECONDS} s", flush=True)
    finally:
        ko.close()


def scroll_row():
    print(f"== wheel scrolling through 100k lines ({load()})", flush=True)
    for name, make in (("tmux copy-mode", Tmux), ("ko", Ko)):
        target = make()
        try:
            history_pane(target)
            c = target.attach()
            c.wait(rb"line 100000")
            if name == "ko":
                c.open_history()
            c.quiet(0.2)
            single = []
            for _ in range(60):
                began = time.monotonic()
                os.write(c.fd, WHEEL_UP)
                chunks = c.collect(0.05)
                if chunks:
                    single.append((chunks[0][0] - began) * 1000)
                c.quiet(0.03)
            server, kids = target.pids()
            pids = [server, c.pid, *kids]
            rate, duration = 240, 4
            before, frames, chunks, sent, began = [cpu(p) for p in pids], c.frames, [], 0, time.monotonic()
            while time.monotonic() - began < duration:
                due = int((time.monotonic() - began) * rate) + 1
                while sent < due:
                    os.write(c.fd, WHEEL_UP)
                    sent += 1
                if readable(c.fd, 0.002):
                    chunks.append((time.monotonic(), c.feed()))
            span = time.monotonic() - began
            used = cores(pids, before, span)
            gaps = [(b[0] - a[0]) * 1000 for a, b in zip(chunks, chunks[1:])]
            print(f"{name}: one notch, first output after the event {stats(single)}", flush=True)
            print(f"{name}: {sent} notches in {span:.1f} s ({rate}/s): output chunks {len(chunks) / span:.0f}/s, gap between chunks {stats(gaps)}; CPU {used} cores ({'server, client' + (', ko-pane' if kids else '')}); sync frames {(c.frames - frames) / span:.0f}/s", flush=True)
        finally:
            target.close()


ROWS_BY_NAME = {"latency": latency, "yes": yes_row, "attach": attach_row, "resize": resize_row, "memory": memory_row, "scroll": scroll_row, "busy": busy_row, "idle": idle_row}

if __name__ == "__main__":
    names = sys.argv[1:] or list(ROWS_BY_NAME)
    if any(n not in ROWS_BY_NAME for n in names):
        raise SystemExit(__doc__)
    if not os.environ.get("KO_BIN"):
        subprocess.run(["make", "build-ko"], cwd=ROOT, check=True)
    for n in names:
        ROWS_BY_NAME[n]()
