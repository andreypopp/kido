#!/usr/bin/env python3
"""An off-screen Kido connected to a private ko server quits on SIGTERM and leaves no child behind."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

bundle = pathlib.Path(sys.argv[1]).resolve()
ko = bundle / "Contents/Resources/ko/bin/ko"
with tempfile.TemporaryDirectory(prefix="ko-quit-", dir="/tmp") as scratch:
    root = pathlib.Path(scratch)
    server = root / "server"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("KIDO_", "KO_")) and k not in ("TMUX", "TMUX_PANE")}
    for name in ("home", "xdg", "config"):
        (root / name).mkdir(mode=0o700)
    env.update(HOME=str(root / "home"), XDG_STATE_HOME=str(root / "xdg"), XDG_CONFIG_HOME=str(root / "config"),
               KIDO_APP_BACKGROUND="1", KIDO_APP_SERVER=str(server), KIDO_APP_QUIT_VERIFY="1")

    def api(*arguments):
        return subprocess.run([str(ko), "api", *arguments, "--server", str(server)], env=env, timeout=10, capture_output=True, text=True)

    started = subprocess.Popen([str(ko), "server", "--server", str(server)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = root / "stderr"
    process = None
    try:
        deadline = time.monotonic() + 15
        while api("/version").returncode:
            if time.monotonic() > deadline or started.poll() is not None:
                raise RuntimeError("the private ko server did not start")
            time.sleep(0.05)
        (root / "layout.json").write_text(json.dumps({"revision": 0, "layout": {"sessions": [{"name": "main", "windows": [{"name": "w", "tree": {"pane": {"new": {}}}}]}]}}))
        if api("-X", "PUT", "--input", str(root / "layout.json"), "/layout").returncode:
            raise RuntimeError("the private ko server refused the layout")
        with log.open("w") as output:
            process = subprocess.Popen([str(bundle / "Contents/MacOS/Kido")], env=env, stdout=output, stderr=output)
            deadline = time.monotonic() + 20
            while "quit verification ready, offscreen=true" not in log.read_text():
                if time.monotonic() > deadline or process.poll() is not None:
                    raise RuntimeError("the off-screen app did not connect: " + log.read_text())
                time.sleep(0.05)
            process.send_signal(signal.SIGTERM)
            try:
                status = process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                sample = subprocess.run(["/usr/bin/sample", str(process.pid), "1"], timeout=10, capture_output=True, text=True)
                raise RuntimeError("quit hung after the main-dispatch signal handler:\n" + sample.stdout + sample.stderr)
            if status != 0:
                raise RuntimeError(f"quit exit {status}: " + log.read_text())
            if "quit drain completed, children=[]" not in log.read_text():
                raise RuntimeError("quit left a child process: " + log.read_text())
            print("PASS: an off-screen connected owner quits and leaves no child process")
    finally:
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        subprocess.run([str(ko), "kill-server", "--server", str(server)], env=env, timeout=10, capture_output=True)
        started.wait(timeout=10)
