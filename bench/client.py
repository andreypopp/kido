#!/usr/bin/env python3
"""usage: [KO_BIN=build/ko/bin/ko] bench/client.py [latency] [yes] [attach] [resize] [memory] [scroll] [busy] [idle]
       [KO_BIN=...] bench/client.py rtt --rtt MS --bw MBIT --variant local|none|ssh-c|deflate --out FILE [--rows attach,plain,mixed,echo] [--runs N]
       bench/client.py rtt-table FILE...   (a Markdown table of the rtt records; bench/rtt.sh runs both)

KO_BIN names the ko to measure (a reference build); without it `make build` runs and build/ko/bin/ko is measured."""
import base64
import argparse
import fcntl
import getpass
import glob
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
RTT_ECHO = "import os,tty\ntty.setraw(0)\nos.write(1,b'BENCH-READY')\nn=0\nwhile True:\n os.read(0,1)\n n+=1\n os.write(1,chr(0x4e00+n).encode())"
HISTORY_LINES = 100000
HISTORY = rf"""awk 'BEGIN{{for(i=1;i<={HISTORY_LINES};i++) printf "line %06d the quick brown fox jumps over the lazy dog 0123456789\n", i}}'"""
WHEEL_UP = b"\x1b[<64;40;10M"
CSI = rb"\x1b\[[0-?]*[ -/]*[@-~]"


def scrubbed(**extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("KO_", "XDG_", "BASH_FUNC_")) and k not in ("HOME", "ENV", "BASH_ENV", "ZDOTDIR")}
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


BEAT = [time.monotonic()]


def beat(label):
    if time.monotonic() - BEAT[0] >= 20:
        print(f"  ... {label}", flush=True)
        BEAT[0] = time.monotonic()


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
            beat(f"waiting for {pattern!r}")
            if readable(self.fd, min(end - time.monotonic(), 5)):
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

    def open_history(self, timeout=10):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            beat("waiting for the history")
            os.set_blocking(self.fd, False)
            try:
                os.write(self.fd, WHEEL_UP)
            except BlockingIOError:
                pass
            os.set_blocking(self.fd, True)
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
        self.began = time.monotonic()
        self.bytes = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(directory + "/socket")
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: ko\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                           f"Sec-WebSocket-Version: 13\r\nKo-Protocol: 1.0\r\nKo-Vt: {vt}\r\n\r\n").encode())
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
            beat("reading the snapshot")
            opcode, data = self.receive()
            if opcode == 2 and len(data) >= 11 and data[0] & 0x7F == 2:
                self.bytes += len(data)
                first = first or time.monotonic()
                if data[9] & 2:
                    return first, time.monotonic()


class Ko:
    def __init__(self, scrollback="200M", exe=None, env=None):
        self.dir = tempfile.mkdtemp(prefix="p13-ko-", dir="/tmp")
        self.exe = exe or os.environ.get("KO_BIN") or os.path.join(ROOT, "build/ko/bin/ko")
        self.env = scrubbed(HOME=self.dir, XDG_CONFIG_HOME=self.dir, XDG_STATE_HOME=self.dir, SHELL="/bin/sh", TERM="xterm-ghostty", **(env or {}))
        self.log = open(self.dir + "/server.log", "wb")
        bytes_ = int(scrollback[:-1]) << {"M": 20, "G": 30}[scrollback[-1]]
        os.makedirs(self.dir + "/ko")
        with open(self.dir + "/ko/config.yaml", "w") as f:
            f.write(f"server:\n  scrollback: {{bytes: {bytes_}}}\n")
        self.server = subprocess.Popen([self.exe, "server", "--server", self.dir], env=self.env, stdout=self.log, stderr=self.log)
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
        connection.request(method, path, json.dumps(body).encode() if body is not None else b"", {"Ko-Protocol": "1.0", "Ko-Vt": self.vt})
        response = connection.getresponse()
        data = response.read()
        if response.status != 200:
            raise RuntimeError((response.status, data))
        connection.close()
        return data

    def pane(self, command):
        document = json.loads(self.request("GET", "/layout"))
        new = {"command": {"type": "argv", "argv": ["/bin/sh", "-c", command]}, "cwd": self.dir}
        document["layout"]["sessions"].append({"name": "bench", "windows": [{"name": "bench", "tree": {"pane": {"new": new}}}]})
        done = json.loads(self.request("PUT", "/layout", document))
        return done["layout"]["sessions"][-1]["windows"][0]["tree"]["pane"]

    def screen(self, pane):
        return self.request("GET", f"/panes/{pane}/screen?history=none").decode(errors="replace")

    def attach(self):
        c = Outer([self.exe, "--server", self.dir], self.env, ROWS, PANE_COLS + SIDEBAR, track=True)
        self.clients.append(c)
        return c

    def view(self, pane, history="all"):
        return WebSocket(self.dir, self.vt, f"/panes/{pane}/view?history={history}")

    def wire(self):
        return 0, 0

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


def wait_screen(target, pane, needle, timeout=30):
    end = time.monotonic() + timeout
    while needle not in target.screen(pane):
        beat(f"waiting for the pane to show {needle!r}")
        if time.monotonic() > end:
            raise RuntimeError(f"pane never showed {needle!r}")
        time.sleep(0.02)


def history_pane(target, producer=HISTORY, tail="exec sleep 3000", done=f"line {HISTORY_LINES}", timeout=30):
    gate = target.dir + "/gate"
    pane = target.pane(f"until [ -e {gate} ]; do sleep 0.01; done; stty size > {gate}.size; {producer}; {tail}")
    target.claim(pane)
    open(gate, "w").close()
    wait_screen(target, pane, done, timeout)
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
    target = Ko()
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
        print(f"ko client, key to frame: {stats(samples)}; added over raw p50 {pct(samples, 50) - pct(raw, 50):.2f} / p99 {pct(samples, 99) - pct(raw, 99):.2f} ms", flush=True)
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
    target = Ko()
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
        print(f"ko: CPU {used} cores (server, client, ko-pane); frames {(c.frames - frames) / span:.0f}/s; server RSS {memory_before:.1f} to {rss(server):.1f} MiB", flush=True)
    finally:
        target.close()


def attach_row():
    print(f"== attach to a pane with 100k lines, warm server, new client process ({load()})", flush=True)
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
    target = Ko()
    try:
        history_pane(target)
        c = target.attach()
        c.wait(rb"line 100000")
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
        print(f"ko: one notch, first output after the event {stats(single)}", flush=True)
        print(f"ko: {sent} notches in {span:.1f} s ({rate}/s): output chunks {len(chunks) / span:.0f}/s, gap between chunks {stats(gaps)}; CPU {used} cores (server, client, ko-pane); sync frames {(c.frames - frames) / span:.0f}/s", flush=True)
    finally:
        target.close()


HOST = "koremote"
SSH, SSHD, KEYGEN = "/usr/bin/ssh", "/usr/sbin/sshd", "/usr/bin/ssh-keygen"
PROXY = os.path.join(ROOT, "bench/rtt_proxy.py")
PRODUCE = os.path.join(ROOT, "build/bench/produce")
MIXED_LONGEST_RUN = 8
RTT_DEADLINE = 180


def cpu_or_zero(pid):
    try:
        return cpu(pid)
    except subprocess.CalledProcessError:
        return 0.0


class Remote(Ko):
    """A Ko server behind a private sshd on 127.0.0.1; every ssh connection goes through bench/rtt_proxy.py."""

    def __init__(self, rtt, bw, compress, **kw):
        super().__init__(**kw)
        self.rdir = d = tempfile.mkdtemp(prefix="p13-rtt-", dir="/tmp")
        for sub in ("stats", "bin", "home", "fw"):
            os.mkdir(f"{d}/{sub}")
        for name in ("host_key", "client_key"):
            subprocess.run([KEYGEN, "-q", "-t", "ed25519", "-N", "", "-f", f"{d}/{name}"], check=True)
        with open(f"{d}/client_key.pub") as f, open(f"{d}/authorized_keys", "w") as g:
            g.write(f.read())
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        bin_dir = os.path.dirname(self.exe)
        with open(f"{d}/sshd_config", "w") as f:
            f.write(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host_key\nPidFile {d}/sshd.pid\nAuthorizedKeysFile {d}/authorized_keys\n"
                    f"StrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n"
                    f"AllowStreamLocalForwarding yes\nSetEnv KO_STATE_DIR={self.dir} PATH={bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin\n")
        proxy = f"{shlex.quote(sys.executable)} -I {shlex.quote(PROXY)} --delay {rtt / 2} --bw {bw} --stats {d}/stats/{{pid}}.json %h %p"
        with open(f"{d}/ssh_config", "w") as f:
            f.write(f"Host {HOST}\n  HostName 127.0.0.1\n  Port {port}\n  User {getpass.getuser()}\n  IdentityFile {d}/client_key\n  IdentitiesOnly yes\n"
                    f"  IdentityAgent none\n  UserKnownHostsFile /dev/null\n  StrictHostKeyChecking no\n  BatchMode yes\n  LogLevel ERROR\n"
                    f"  Compression {'yes' if compress else 'no'}\n  ProxyCommand {proxy}\n")
        self.ssh = f"{d}/bin/ssh"
        with open(self.ssh, "w") as f:
            f.write(f"#!/bin/sh\nexec {SSH} -F {d}/ssh_config \"$@\"\n")
        os.chmod(self.ssh, 0o700)
        self.sshd_log = open(f"{d}/sshd.log", "wb")
        self.sshd = subprocess.Popen([SSHD, "-D", "-e", "-f", f"{d}/sshd_config"], stdin=subprocess.DEVNULL, stdout=self.sshd_log, stderr=self.sshd_log)
        end = time.monotonic() + 5
        while True:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            except OSError:
                if time.monotonic() >= end or self.sshd.poll() is not None:
                    raise RuntimeError("sshd did not listen: " + open(f"{d}/sshd.log").read())
                select.select([], [], [], 0.01)
        self.masters = []

    def client_env(self):
        h = f"{self.rdir}/home"
        return scrubbed(HOME=h, XDG_CONFIG_HOME=h, XDG_STATE_HOME=h, SHELL="/bin/sh", TERM="xterm-ghostty", PATH=f"{self.rdir}/bin:{os.environ['PATH']}")

    def attach(self):
        c = Outer([self.exe, HOST], self.client_env(), ROWS, PANE_COLS + SIDEBAR, track=True)
        self.clients.append(c)
        return c

    def view(self, pane, history="all"):
        ctl = f"{self.rdir}/view.ctl"
        options = ["-o", f"ControlPath={ctl}", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "-o", "StreamLocalBindUnlink=yes"]
        quiet = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "check": True, "timeout": 120}
        subprocess.run([self.ssh, "-f", "-M", "-N", "-T", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "BatchMode=yes", *options, HOST], **quiet)
        self.masters.append(ctl)
        subprocess.run([self.ssh, "-S", ctl, "-O", "forward", "-L", f"{self.rdir}/fw/socket:{self.dir}/socket", HOST], **quiet)
        return WebSocket(f"{self.rdir}/fw", self.vt, f"/panes/{pane}/view?history={history}")

    def wire(self):
        up = down = 0
        for name in glob.glob(f"{self.rdir}/stats/*.json"):
            with open(name) as f:
                counts = json.load(f)
            up, down = up + counts["up"], down + counts["down"]
        return up, down

    def sshd_pids(self):
        return children(self.sshd.pid)

    def close(self):
        for ctl in self.masters:
            subprocess.run([self.ssh, "-S", ctl, "-O", "exit", HOST], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        super().close()
        signal_child(self.sshd.pid, signal.SIGTERM)
        self.sshd.wait(timeout=10)
        self.sshd_log.close()
        subprocess.run(["rm", "-rf", self.rdir])


def rtt_target(args):
    variant = args.variant
    if variant == "local":
        return Ko(scrollback="2G")
    exe = None if variant == "deflate" else os.environ["KO_BIN_REF"]
    return Remote(args.rtt, args.bw, variant == "ssh-c", exe=exe, scrollback="2G")


def echo_samples(c, count, first=1):
    samples = []
    for n in range(first, first + count):
        beat("key echo samples")
        c.collect(0.01)
        began = time.monotonic()
        os.write(c.fd, b"x")
        done = c.wait(chr(0x4E00 + n).encode(), RTT_DEADLINE)
        samples.append((done - began) * 1000)
    return samples


def cpu_seconds(target, c, before):
    server, kids = target.pids()
    used = {"server": cpu(server) - before[0], "pane": cpu(kids[0]) - before[1], "client": cpu_or_zero(c.pid)}
    if isinstance(target, Remote):
        ssh = children(c.pid)
        used["ssh"] = sum(cpu_or_zero(p) for p in ssh)
        used["proxy"] = sum(cpu_or_zero(x) for p in ssh for x in children(p))
        used["sshd"] = sum(cpu_or_zero(p) for p in target.sshd_pids())
    return {k: round(v, 2) for k, v in used.items()}


def row_attach(args, echo):
    target = rtt_target(args)
    try:
        target.pane("exec python3 -c " + shlex.quote(RTT_ECHO))
        before = target.wire()
        began = time.monotonic()
        c = target.attach()
        ready = c.wait(rb"BENCH-READY", RTT_DEADLINE)
        c.quiet(0.3, 10)
        up, down = (b - a for a, b in zip(before, target.wire()))
        out = {"attach_ms": (ready - began) * 1000, "wire_up": up, "wire_down": down}
        if echo:
            samples = echo_samples(c, 100)
            out.update(echo_p50=pct(samples, 50) - args.rtt, echo_p99=pct(samples, 99) - args.rtt, echo_min=min(samples) - args.rtt)
        return out
    finally:
        target.close()


def restore_pane(target, kind):
    producer = HISTORY if kind == "plain" else f"{PRODUCE} --mixed {HISTORY_LINES} {MIXED_LONGEST_RUN}"
    return history_pane(target, producer, "exec python3 -c " + shlex.quote(RTT_ECHO), "BENCH-READY", 120)


def row_restore(args, kind):
    target = rtt_target(args)
    try:
        pane = restore_pane(target, kind)
        server, kids = target.pids()
        before = (cpu(server), cpu(kids[0]))
        wire = target.wire()
        began = time.monotonic()
        c = target.attach()
        shown = c.wait(rb"BENCH-READY", RTT_DEADLINE)
        loaded = c.open_history(RTT_DEADLINE)
        used = cpu_seconds(target, c, before)
        c.quiet(0.3, 10)
        up, down = (b - a for a, b in zip(wire, target.wire()))
        out = {"shown_ms": (shown - began) * 1000, "loaded_ms": (loaded - began) * 1000, "wire_up": up, "wire_down": down, "cpu": used}
        c.close()
        target.clients.remove(c)
        signal.alarm(RTT_DEADLINE)
        wire = target.wire()
        view = target.view(pane)
        first, last = view.snapshot()
        up, down = (b - a for a, b in zip(wire, target.wire()))
        out.update(view_first_ms=(first - view.began) * 1000, view_last_ms=(last - view.began) * 1000, view_bytes=view.bytes, view_wire_down=down)
        return out
    finally:
        target.close()


def row_echo_restore(args):
    target = rtt_target(args)
    try:
        restore_pane(target, "mixed")
        began = time.monotonic()
        c = target.attach()
        c.wait(rb"BENCH-READY", RTT_DEADLINE)
        samples = []
        for n in range(1, 51):
            beat("key echo samples")
            c.collect(0.01)
            sent = time.monotonic()
            os.write(c.fd, b"x")
            done = c.wait(chr(0x4E00 + n).encode(), RTT_DEADLINE)
            samples.append(((done - began) * 1000, (done - sent) * 1000 - args.rtt))
        return {"samples": [[round(a, 1), round(b, 2)] for a, b in samples]}
    finally:
        target.close()


def guarded(label, run, record):
    def expired(*_):
        raise TimeoutError(label)

    signal.signal(signal.SIGALRM, expired)
    load = os.getloadavg()
    began = time.monotonic()
    signal.alarm(RTT_DEADLINE)
    try:
        result = run()
    except TimeoutError:
        print(f"{label}: timeout", flush=True)
        result = {"error": "timeout"}
    except Exception as error:
        print(f"{label}: error {error!r}", flush=True)
        result = {"error": repr(error)}
    finally:
        signal.alarm(0)
    result.update(load=[round(x, 2) for x in load], seconds=round(time.monotonic() - began, 1))
    record(result)
    if "error" not in result:
        print(f"{label}: {json.dumps({k: (round(v, 1) if isinstance(v, float) else v) for k, v in result.items() if k != 'samples'})}", flush=True)


def rtt(argv):
    parser = argparse.ArgumentParser(prog="client.py rtt")
    parser.add_argument("--rtt", type=float, required=True)
    parser.add_argument("--bw", type=float, required=True)
    parser.add_argument("--variant", required=True, choices=["local", "none", "ssh-c", "deflate"])
    parser.add_argument("--out", required=True)
    parser.add_argument("--rows", default="attach,plain,mixed,echo")
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args(argv)
    for row in args.rows.split(","):
        runs = {"attach": args.runs, "plain": args.runs, "mixed": 1 if args.bw and args.bw <= 10 else args.runs, "echo": 1}[row]
        for run in range(runs):
            def record(result, row=row, run=run):
                with open(args.out, "a") as f:
                    f.write(json.dumps({"rtt": args.rtt, "bw": args.bw, "variant": args.variant, "row": row, "run": run, **result}) + "\n")

            label = f"{args.variant} rtt={args.rtt:g} bw={args.bw:g} {row} #{run + 1}"
            fns = {"attach": lambda: row_attach(args, run == 0), "plain": lambda: row_restore(args, "plain"), "mixed": lambda: row_restore(args, "mixed"), "echo": lambda: row_echo_restore(args)}
            guarded(label, fns[row], record)


VARIANT_NAMES = [("local", "local"), ("none", "none"), ("ssh-c", "ssh -C"), ("deflate", "deflate l1")]


def rtt_table(files):
    records = []
    for name in files:
        with open(name) as f:
            records += [json.loads(line) for line in f if line.strip()]
    cells = sorted({(r["rtt"], r["bw"]) for r in records if r["variant"] != "local"})

    def pick(variant, cell, row):
        return [r for r in records if r["variant"] == variant and r["row"] == row and (variant == "local" or (r["rtt"], r["bw"]) == cell)]

    def show(runs, get, fmt):
        ok = [r for r in runs if "error" not in r]
        values = sorted(v for v in (get(r) for r in ok) if v is not None)
        if not values:
            return "timeout" if any(r.get("error") == "timeout" for r in runs) else ("error" if any("error" in r for r in runs) else "-")
        return f"{fmt(values[len(values) // 2])} ({fmt(values[0])})" if len(values) > 1 else fmt(values[0])

    def block(title, row, get, fmt, note=""):
        print(f"\n### {title}\n{note}")
        print("| RTT ms | Mbit/s | " + " | ".join(label for _, label in VARIANT_NAMES) + " |")
        print("|---|---|" + "---|" * len(VARIANT_NAMES))
        for cell in cells:
            bandwidth = f"{cell[1]:g}" if cell[1] else "unlimited"
            print(f"| {cell[0]:g} | {bandwidth} | " + " | ".join(show(pick(v, cell, row), get, fmt) for v, _ in VARIANT_NAMES) + " |")

    ms = lambda v: f"{v:.0f}"
    ms1 = lambda v: f"{v:.1f}"
    mb = lambda v: f"{v / 1e6:.1f}"
    sec = lambda v: f"{v:.2f}"
    print("Entries are the median of the runs with the minimum in parentheses. ms unless stated; echo figures are over the RTT.")
    block("attach, empty pane: `ko HOST` spawn to prompt visible (ms)", "attach", lambda r: r["attach_ms"], ms)
    block("key echo, quiet pane, p50 over RTT (ms), 100 samples", "attach", lambda r: r.get("echo_p50"), ms1)
    block("key echo, quiet pane, p99 over RTT (ms)", "attach", lambda r: r.get("echo_p99"), ms1)
    for row, label in (("plain", "restore 100k plain lines"), ("mixed", "restore 100k mixed lines")):
        sizes = sorted({r["view_bytes"] for r in records if r["row"] == row and "view_bytes" in r and r["variant"] == "none"})
        note = f"snapshot bytes (history=all, uncompressed, first to last slice): {', '.join(f'{b / 1e6:.1f} MB' for b in sizes)}" if sizes else ""
        block(f"{label}: screen visible (ms)", row, lambda r: r["shown_ms"], ms, note)
        block(f"{label}: history loaded in the client (ms)", row, lambda r: r["loaded_ms"], ms)
        block(f"{label}: protocol view, first slice (ms)", row, lambda r: r["view_first_ms"], ms)
        block(f"{label}: protocol view, last slice (ms)", row, lambda r: r["view_last_ms"], ms)
        block(f"{label}: wire bytes down, client run (MB)", row, lambda r: r["wire_down"], mb)
        block(f"{label}: wire bytes up, client run (KB)", row, lambda r: r["wire_up"] / 1e3, ms1)
        block(f"{label}: CPU seconds, server + ko-pane", row, lambda r: r["cpu"]["server"] + r["cpu"]["pane"], sec)
        block(f"{label}: CPU seconds, client ko", row, lambda r: r["cpu"]["client"], sec)
        block(f"{label}: CPU seconds, ssh master + proxy", row, lambda r: r["cpu"].get("ssh", 0) + r["cpu"].get("proxy", 0) if "ssh" in r["cpu"] else None, sec)
        block(f"{label}: CPU seconds, sshd", row, lambda r: r["cpu"].get("sshd"), sec)
    print("\n### key echo while the mixed restore streams: the first key, typed when the screen is visible, then the keys delayed by more than 20 ms over RTT (of 50, 10 ms apart)")
    print("| RTT ms | Mbit/s | " + " | ".join(label for _, label in VARIANT_NAMES) + " |")
    print("|---|---|" + "---|" * len(VARIANT_NAMES))
    for cell in cells:
        out = []
        for v, _ in VARIANT_NAMES:
            runs = [r for r in pick(v, cell, "echo") if "samples" in r]
            out.append(" ".join(f"{r['samples'][0][1] / 1000:.1f} s, {sum(1 for _, lat in r['samples'] if lat > 20)} late" for r in runs) or ("timeout" if any(r.get("error") for r in pick(v, cell, "echo")) else "-"))
        print(f"| {cell[0]:g} | {cell[1]:g} | " + " | ".join(out) + " |")
    print("\n### load average (1 min at run start), max over the runs of the cell")
    print("| RTT ms | Mbit/s | " + " | ".join(label for _, label in VARIANT_NAMES) + " |")
    print("|---|---|" + "---|" * len(VARIANT_NAMES))
    for cell in cells:
        loads = []
        for v, _ in VARIANT_NAMES:
            runs = [r["load"][0] for r in records if r["variant"] == v and (r["rtt"], r["bw"]) == cell]
            loads.append(f"{max(runs):.1f}" if runs else "-")
        print(f"| {cell[0]:g} | {cell[1]:g} | " + " | ".join(loads) + " |")


ROWS_BY_NAME = {"latency": latency, "yes": yes_row, "attach": attach_row, "resize": resize_row, "memory": memory_row, "scroll": scroll_row, "busy": busy_row, "idle": idle_row}

if __name__ == "__main__":
    if sys.argv[1:2] == ["rtt-table"]:
        rtt_table(sys.argv[2:])
        raise SystemExit(0)
    if sys.argv[1:2] == ["rtt"]:
        rtt(sys.argv[2:])
        raise SystemExit(0)
    names = sys.argv[1:] or list(ROWS_BY_NAME)
    if any(n not in ROWS_BY_NAME for n in names):
        raise SystemExit(__doc__)
    if not os.environ.get("KO_BIN"):
        subprocess.run(["make", "build"], cwd=ROOT, check=True)
    for n in names:
        ROWS_BY_NAME[n]()
