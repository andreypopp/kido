#!/usr/bin/env python3
"""Measures Kido.app against a remote ko server: attach, the restore of a large pane, and key echo.

usage: rtt.py --app KIDO --ko KO [--rtt MS --bw MBIT --proxy rtt_proxy.py | --ssh-config FILE --host ALIAS]
              [--rows N] [--longest-run N] [--produce PATH] [--keys N] [--interval MS] [--deadline S] [--allow-localhost]

KIDO is the executable of a Kido.app built with KIDO_VISUAL (make rtt builds it). Without --ssh-config the
script runs a private sshd and a private ko server on this machine, in the recipe of ko's remote e2e tests
(own port and keys, StrictModes no, an ssh_config for the app), and with --rtt or --bw puts the delay proxy
bench/rtt_proxy.py of ko (--proxy) on the app's connection as its ProxyCommand. With --ssh-config the app
connects to --host through that ssh_config, and the script prepares the remote panes with `ko api --host`
through an `ssh` wrapper that applies the same file: pass a config whose ProxyCommand shapes the link and
whose host key the app can verify (the app forces StrictHostKeyChecking=yes). Every other state is private:
the app's HOME, XDG directories and local server are under /tmp, the window stays off screen
(KIDO_APP_BACKGROUND=1), and the user's ssh agent, ~/.ssh and real servers are never used.

It prints a header (unless --no-header) and one row: rtt_ms attach_ms restore_ms restore_bytes echo_p50_ms
echo_p95_ms wire_up wire_down server_build app_build (wire bytes only through the private proxy, "-" otherwise;
server_build is the build of the remote ko, app_build is the build of the ko in the app, or "same").
"""
import argparse
import glob
import json
import os
import select
import shlex
import socket
import subprocess
import sys
import tempfile
import time

SSH, SSHD, KEYGEN = "/usr/bin/ssh", "/usr/sbin/sshd", "/usr/bin/ssh-keygen"
ALIAS = "korem"

def fail(message):
    sys.exit("rtt.py: " + message)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_listening(port, within, process):
    end = time.monotonic() + within
    while True:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return
        except OSError:
            if time.monotonic() >= end or process.poll() is not None:
                fail("sshd did not listen")
            select.select([], [], [], 0.02)


def scrubbed(**extra):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    env.update(extra)
    return env


class Private:
    """A private sshd, ko server and ssh_config under one /tmp directory."""

    def __init__(self, args):
        self.root = tempfile.mkdtemp(prefix="ka-rtt-", dir="/tmp")
        os.chmod(self.root, 0o700)
        for sub in ("stats", "bin", "state", "app-home", "app-state", "app-config"):
            os.mkdir(f"{self.root}/{sub}")
        self.procs = []
        self.server_dir = None
        self.wrapper_dir = f"{self.root}/bin"
        if args.ssh_config:
            self.config = os.path.abspath(args.ssh_config)
            wrapper = f"{self.wrapper_dir}/ssh"
            with open(wrapper, "w") as f:
                f.write(f"#!/bin/sh\nexec {SSH} -F {shlex.quote(self.config)} \"$@\"\n")
            os.chmod(wrapper, 0o700)
            return
        d = self.root
        for name in ("host_key", "client_key"):
            subprocess.run([KEYGEN, "-q", "-t", "ed25519", "-N", "", "-f", f"{d}/{name}"], check=True)
        with open(f"{d}/client_key.pub") as f, open(f"{d}/authorized_keys", "w") as g:
            g.write(f.read())
        with open(f"{d}/host_key.pub") as f:
            host_key = " ".join(f.read().split()[:2])
        port = free_port()
        with open(f"{d}/known_hosts", "w") as f:
            f.write(f"[127.0.0.1]:{port} {host_key}\n")
        self.server_dir = f"{d}/state/ko"
        ko_bin = os.path.dirname(args.ko)
        with open(f"{d}/sshd_config", "w") as f:
            f.write(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host_key\nPidFile {d}/sshd.pid\n"
                    f"AuthorizedKeysFile {d}/authorized_keys\nStrictModes no\nUsePAM no\nPasswordAuthentication no\n"
                    f"KbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowStreamLocalForwarding yes\n"
                    f"SetEnv KO_STATE_DIR={self.server_dir} PATH={ko_bin}:/usr/bin:/bin:/usr/sbin:/sbin\n")
        proxy = ""
        if args.rtt > 0 or args.bw > 0:
            if not os.path.exists(args.proxy):
                fail(f"{args.proxy} does not exist: pass --proxy, the bench/rtt_proxy.py of ko")
            command = (f"{shlex.quote(sys.executable)} -I {shlex.quote(os.path.abspath(args.proxy))} "
                       f"--delay {args.rtt / 2} --bw {args.bw} --stats {d}/stats/{{pid}}.json %h %p")
            proxy = f"  ProxyCommand {command}\n"
        user = os.environ.get("USER") or subprocess.check_output(["/usr/bin/id", "-un"], text=True).strip()
        self.config = f"{d}/ssh_config"
        with open(self.config, "w") as f:
            f.write(f"Host {ALIAS}\n  HostName 127.0.0.1\n  Port {port}\n  User {user}\n"
                    f"  IdentityFile {d}/client_key\n  IdentitiesOnly yes\n  IdentityAgent none\n"
                    f"  UserKnownHostsFile {d}/known_hosts\n  GlobalKnownHostsFile /dev/null\n  CheckHostIP no\n  LogLevel ERROR\n{proxy}")
        self.sshd_log = open(f"{d}/sshd.log", "wb")
        sshd = subprocess.Popen([SSHD, "-D", "-e", "-f", f"{d}/sshd_config"], stdin=subprocess.DEVNULL, stdout=self.sshd_log, stderr=self.sshd_log)
        self.procs.append(sshd)
        wait_listening(port, 5, sshd)
        server = subprocess.Popen([args.ko, "server", "--server", self.server_dir], env=scrubbed(HOME=f"{d}/state"),
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(server)
        end = time.monotonic() + 10
        while not os.path.exists(f"{self.server_dir}/socket"):
            if time.monotonic() >= end or server.poll() is not None:
                fail("the ko server did not start")
            select.select([], [], [], 0.02)

    def wire(self):
        up = down = 0
        files = glob.glob(f"{self.root}/stats/*.json")
        for name in files:
            with open(name) as f:
                counts = json.load(f)
            up, down = up + counts["up"], down + counts["down"]
        return (up, down) if files else None

    def close(self, ko):
        for server in (self.server_dir, f"{self.root}/app-state/ko-app"):
            if server:
                subprocess.run([ko, "kill-server", "--server", server], env=scrubbed(HOME=f"{self.root}/state"),
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        for proc in reversed(self.procs):
            proc.terminate()
        for proc in self.procs:
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        subprocess.run(["/bin/rm", "-rf", self.root])


class App:
    """The app's timing lines, read from its stderr."""

    def __init__(self, args, private, host):
        self.events = []
        self.partial = b""
        d = private.root
        env = scrubbed(HOME=f"{d}/app-home", XDG_STATE_HOME=f"{d}/app-state", XDG_CONFIG_HOME=f"{d}/app-config",
                       KIDO_APP_BACKGROUND="1", KIDO_APP_TIMING="1", KIDO_APP_CONNECT=host, KIDO_APP_SSH_CONFIG=private.config,
                       KIDO_APP_RTT_REQUESTS=f"{d}/requests.json", KIDO_APP_SERVER=f"{d}/app-state/ko-app")
        self.requests = f"{d}/requests.json"
        self.proc = subprocess.Popen([args.app], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def pump(self, within):
        ready, _, _ = select.select([self.proc.stderr], [], [], within)
        if not ready:
            return
        data = os.read(self.proc.stderr.fileno(), 65536)
        lines = (self.partial + data).split(b"\n")
        self.partial = lines.pop()
        for line in lines:
            if line.startswith(b"{") and b'"t":' in line:
                self.events.append(json.loads(line))
                print(line.decode(), file=sys.stderr, flush=True)

    def until(self, what, condition, deadline):
        end = time.monotonic() + deadline
        while not condition():
            if self.proc.poll() is not None:
                fail(f"the app ended while waiting for {what}")
            left = end - time.monotonic()
            if left <= 0:
                fail(f"timeout: {what}")
            self.pump(min(left, 0.5))

    def idle(self, seconds):
        end = time.monotonic() + seconds
        while (left := end - time.monotonic()) > 0:
            self.pump(left)

    def find(self, **match):
        return [e for e in self.events if all(e.get(k) == v for k, v in match.items())]

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(20)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stderr.close()


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def ko_api(private, args, *rest):
    env = scrubbed(HOME=f"{private.root}/state")
    if args.ssh_config:
        env["PATH"] = f"{private.wrapper_dir}:{env['PATH']}"
        where = ["--host", args.host]
    else:
        where = ["--server", private.server_dir]
    result = subprocess.run([args.ko, "api", *where, *rest], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        fail(f"ko api {' '.join(rest)}: {result.stderr.strip()}")
    return result.stdout


def prepare(args, private):
    script = f"{shlex.quote(args.produce)} --mixed {args.rows} {args.longest_run}; printf 'RTT-DONE\\n'; exec sleep 86400"
    big = {"pane": {"new": {"command": {"type": "argv", "argv": ["/bin/sh", "-c", script]}}}}
    echo = {"pane": {"new": {"command": {"type": "argv", "argv": ["/bin/sh", "-c", "stty raw -echo; exec cat"]}}}}
    layout = {"revision": 0, "layout": {"sessions": [{"name": "rtt", "windows": [{"name": "w", "tree": {"split": "h", "children": [big, echo]}}]}]}}
    path = f"{private.root}/layout.json"
    with open(path, "w") as f:
        json.dump(layout, f)
    result = json.loads(ko_api(private, args, "-X", "PUT", "--input", path, "/layout"))
    children = result["layout"]["sessions"][0]["windows"][0]["tree"]["children"]
    return children[0]["pane"], children[1]["pane"]


def app_build(app):
    """The build of the ko that the app bundles: its BUILD-ID is the `ko version` text."""
    contents = os.path.dirname(os.path.dirname(app))
    with open(f"{contents}/Resources/ko/BUILD-ID") as f:
        return json.load(f)["build"]


def generated(args, private, pane):
    """Waits until the generator has printed everything; returns the bytes of the whole history (private mode)."""
    end = time.monotonic() + args.deadline
    while "RTT-DONE" not in ko_api(private, args, f"/panes/{pane}/screen"):
        if time.monotonic() >= end:
            fail("timeout: the generator did not finish")
        select.select([], [], [], 0.5)
    if args.ssh_config:
        return None
    text = ko_api(private, args, f"/panes/{pane}/screen?history=all")
    if len(text.splitlines()) < args.rows:
        fail(f"the history holds {len(text.splitlines())} lines, not {args.rows}")
    return len(text.encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--ko", required=True)
    parser.add_argument("--rtt", type=float, default=0)
    parser.add_argument("--bw", type=float, default=0)
    parser.add_argument("--proxy", help="ko's bench/rtt_proxy.py (default: next to --ko's checkout)")
    parser.add_argument("--produce", help="ko's build/bench/produce, from make build-bench (default: next to --ko's checkout)")
    parser.add_argument("--ssh-config")
    parser.add_argument("--host")
    parser.add_argument("--rows", type=int, default=100000)
    parser.add_argument("--longest-run", type=int, default=8, help="produce --mixed's longest run; 100000 rows of 8 are the 78 MB snapshot of ko's table")
    parser.add_argument("--keys", type=int, default=50)
    parser.add_argument("--interval", type=int, default=200)
    parser.add_argument("--deadline", type=float, default=300)
    parser.add_argument("--allow-localhost", action="store_true")
    parser.add_argument("--no-header", action="store_true", help="print the row only, for a sweep that printed the header once")
    args = parser.parse_args()
    args.ko = os.path.abspath(args.ko)
    args.app = os.path.abspath(args.app)
    root = os.path.dirname(os.path.dirname(os.path.dirname(args.ko)))
    args.proxy = args.proxy or f"{root}/bench/rtt_proxy.py"
    args.produce = args.produce or f"{root}/build/bench/produce"
    if not os.path.exists(args.produce):
        fail(f"{args.produce} does not exist: make build-bench, or pass --produce")
    if args.ssh_config:
        if not args.host:
            fail("--ssh-config needs --host")
        if args.host.split("@")[-1] in ("localhost", "127.0.0.1", "::1") and not args.allow_localhost:
            fail("refusing localhost without --allow-localhost: a run must not land on your own servers")
    host = args.host if args.ssh_config else ALIAS
    private = Private(args)
    app = None
    try:
        big, echo = prepare(args, private)
        history = generated(args, private, big)
        app = App(args, private, host)
        app.until("the first layout", lambda: app.find(t="attach", step="first-layout"), args.deadline)
        app.until("the restore of both panes", lambda: app.find(t="restore", pane=big) and app.find(t="restore", pane=echo), args.deadline)
        tmp = f"{private.root}/requests.tmp"
        for key in range(args.keys):
            with open(tmp, "w") as f:
                json.dump({"pane": echo, "keys": 1, "interval_ms": 0}, f)
            os.rename(tmp, app.requests)
            app.until(f"the echo of key {key + 1}", lambda: len(app.find(t="echo", pane=echo)) > key, args.deadline)
            app.idle(args.interval / 1000)
        attach = app.find(t="attach", step="first-layout")[0]["ms"]
        restore = app.find(t="restore", pane=big)[0]
        if history is not None and restore["bytes"] < history:
            fail(f"the restore read {restore['bytes']} bytes, fewer than the {history} of the history text")
        echoes = [e["ms"] for e in app.find(t="echo", pane=echo)]
        wire = private.wire()
        cells = ["%.0f" % args.rtt, "%.0f" % attach, "%.0f" % restore["total_ms"], "%d" % restore["bytes"],
                 "%.1f" % percentile(echoes, 0.5), "%.1f" % percentile(echoes, 0.95)]
        cells += ["%d" % wire[0], "%d" % wire[1]] if wire else ["-", "-"]
        server = json.loads(ko_api(private, args, "/version"))["build"]
        bundled = app_build(args.app)
        cells += [server, bundled if bundled != server else "same"]
        if not args.no_header:
            print("rtt_ms attach_ms restore_ms restore_bytes echo_p50_ms echo_p95_ms wire_up wire_down server_build app_build")
        print(" ".join(cells))
    finally:
        if app:
            app.close()
        private.close(args.ko)


if __name__ == "__main__":
    main()
