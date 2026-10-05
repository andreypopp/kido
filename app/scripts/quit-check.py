#!/usr/bin/env python3
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import tempfile
import time

bundle = pathlib.Path(sys.argv[1]).resolve()
kido = bundle / "Contents/Resources/kido/bin/kido"
tmux = bundle / "Contents/Resources/kido/bin/kido-tmux"
with tempfile.TemporaryDirectory(prefix="kido-quit-", dir="/tmp") as scratch:
    root = pathlib.Path(scratch)
    env = {k: v for k, v in os.environ.items() if not k.startswith("KIDO_") and k not in ("TMUX", "TMUX_PANE")}
    for name in ("home", "xdg", "config"):
        (root / name).mkdir(mode=0o700)
    env.update(HOME=str(root / "home"), XDG_STATE_HOME=str(root / "xdg"), XDG_CONFIG_HOME=str(root / "config"), KIDO_APP_BACKGROUND="1", KIDO_APP_SERVER=str(root / "server"), KIDO_APP_QUIT_VERIFY="1")
    control = root / "control"
    feed = root / "feed"
    control.write_text(f'#!/bin/sh\necho $$ > {shlex.quote(str(root / "control.pid"))}\nexec {shlex.quote(str(tmux))} "$@"\n')
    feed.write_text('#!/usr/bin/python3\nimport os, signal, sys, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                    + f'open({str(root / "feed.pid")!r}, "w").write(str(os.getpid()))\n'
                    + 'print(\'{"hello":{"protocol":"1.0"}}\', flush=True)\n'
                    + 'print(\'{"v":2,"filter":"","client":{"session":"$0","window":"@0","pane":"%0"},"sessions":[]}\', flush=True)\n'
                    + 'while True: time.sleep(60)\n')
    control.chmod(0o700)
    feed.chmod(0o700)
    env.update(KIDO_APP_TMUX=str(control), KIDO_APP_FEED=str(feed), KIDO_APP_QUIT_CHILDREN="|".join(str(root / (name + ".pid")) for name in ("control", "feed")))
    subprocess.run([str(kido), "server", "--server", str(root / "server")], env=env, timeout=15, capture_output=True, check=True)
    helpers = []
    log = root / "stderr"
    with log.open("w") as output:
        process = subprocess.Popen([str(bundle / "Contents/MacOS/Kido")], env=env, stdout=output, stderr=output)
        try:
            deadline = time.monotonic() + 20
            while "quit verification ready, offscreen=true" not in log.read_text() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.05)
            if "quit verification ready, offscreen=true" not in log.read_text():
                raise RuntimeError("offscreen quit check did not connect: " + log.read_text())
            helpers = [int((root / (name + ".pid")).read_text()) for name in ("control", "feed")]
            for pid in helpers:
                os.kill(pid, signal.SIGSTOP)
            states = subprocess.check_output(["/bin/ps", "-p", ",".join(map(str, helpers)), "-o", "stat="], text=True).splitlines()
            if len(states) != len(helpers) or not all(state.strip().startswith("T") for state in states):
                raise RuntimeError(f"helpers did not reach SIGSTOP: {states}")
            process.send_signal(signal.SIGTERM)
            try:
                status = process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                sample = subprocess.run(["/usr/bin/sample", str(process.pid), "1"], timeout=10, capture_output=True, text=True)
                raise RuntimeError("quit hung after the main-dispatch signal handler:\n" + sample.stdout + sample.stderr)
            if status != 0:
                raise RuntimeError(f"quit exit {status}: " + log.read_text())
            alive = []
            for pid in helpers:
                try:
                    os.kill(pid, 0)
                    alive.append(pid)
                except ProcessLookupError:
                    pass
            if alive or "quit drain completed, unreaped=[]" not in log.read_text():
                raise RuntimeError(f"quit replied before reaping SIGSTOP'd control/feed children: {alive}; " + log.read_text())
            print("PASS: offscreen connected-owner quit reaps SIGSTOP'd control and feed children")
        finally:
            if not helpers:
                helpers = [int(path.read_text()) for path in root.glob("*.pid")]
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            for pid in helpers:
                command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=3).stdout
                if str(root) in command:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            subprocess.run([str(tmux), "-u", "-S", str(root / "server/socket"), "kill-session", "-t", "main"], env=env, timeout=10, capture_output=True)
