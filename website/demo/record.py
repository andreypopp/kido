#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
MEDIA = HERE.parent / "public/media"
KITTY = "/opt/homebrew/bin/kitty"
PREFIX = Path(os.environ.get("KIDO_DEMO_PREFIX", HERE / "output/prefix")).resolve()
TMUX = str(PREFIX / "bin/kido-tmux")
KIDO = str(PREFIX / "bin/kido")


def run(args, *, env=None, timeout=15, **kwargs):
    return subprocess.run(args, env=env, timeout=timeout, check=True,
                          text=True, capture_output=True, **kwargs).stdout


def wait_for(description, check, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.15)
    raise RuntimeError(f"Timed out after {seconds}s: {description}")


class Demo:
    def __init__(self, root):
        self.root = root
        self.project = Path.home() / "src/greeter"
        self.owns_project = False
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("TMUX", "KIDO_", "PI_", "KITTY_"))
                    and k not in ("ZDOTDIR", "ENV", "BASH_ENV", "TERM_PROGRAM", "TERM_PROGRAM_VERSION")}
        self.env.update(TMUX_TMPDIR=str(root / "tmux"), KIDO_STATE_DIR=str(root / "state"),
                        XDG_CONFIG_HOME=str(root / "config"), ZDOTDIR=str(root / "zsh"),
                        SHELL="/bin/zsh", PATH=f"{PREFIX}/share/kido/bin:{PREFIX}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                        KIDO_DEMO_PREFIX=str(PREFIX), KIDO_TMUX=TMUX,
                        KIDO_DEMO_STATE_DIR=str(root / "state"),
                        KIDO_DEMO_CI_SIGNAL=str(root / ".ci-release"),
                        PI_OFFLINE="1", PI_TELEMETRY="0", KITTY_CONFIG_DIRECTORY=str(HERE))
        self.socket = root / "kitty.sock"
        self.kitty = None
        self.caffeinate = None
        self.capture = None
        self.endpoint = None
        self.timeline = []
        self.start = None

    def tmux(self, *args):
        self.assert_private()
        return run([TMUX, "-S", str(self.root / "state/socket"), *args], env=self.env)

    def assert_private(self):
        assert self.root.name.startswith("kido-demo-") and self.root.parent == Path("/tmp")
        assert self.env["TMUX_TMPDIR"] == str(self.root / "tmux")
        assert self.env["KIDO_STATE_DIR"] == str(self.root / "state")
        assert "TMUX" not in self.env and "TMUX_PANE" not in self.env

    def remote(self, *args):
        return run([KITTY, "@", "--to", f"unix:{self.socket}", *args], env=self.env)

    def type(self, text, enter=True):
        rng = random.Random(7)
        for char in text:
            self.remote("send-text", "--", char)
            time.sleep(rng.uniform(0.025, 0.060))
        if enter:
            self.remote("send-text", "--", "\r")

    def focus(self, pane):
        self.remote("focus-window", "--match", "all")
        self.tmux("select-pane", "-t", pane)
        client = self.tmux("list-clients", "-F", "#{?client_control_mode,,#{client_name}}").strip()
        self.tmux("refresh-client", "-t", client, "-f", "!side-status-focus")

    def open_pi(self):
        self.focus(self.agent)
        self.type("pi")
        wait_for("pi ready", lambda: bool(self.status()), 25)
        time.sleep(.4)
        assert "Warning: tmux" not in self.screen(self.agent), self.screen(self.agent)
        self.mark("pi opened")

    def prompt(self, text):
        self.mark("typing start")
        self.type(text)
        self.mark("typing end")
        wait_for("agent running", lambda: any(r["status"] == "running" for r in self.status()), 15)
        self.mark("running")

    def runs(self):
        entries = []
        for directory in (self.root / "state/runs").glob("*"):
            if (directory / "meta.json").exists():
                meta = json.loads((directory / "meta.json").read_text())
                outcome = directory / "outcome"
                entries.append((meta, json.loads(outcome.read_text()) if outcome.exists() else None))
        return entries

    def calls(self):
        names = []
        for path in (self.root / "state/sessions").rglob("*.jsonl"):
            for line in path.read_text().splitlines():
                try:
                    message = json.loads(line).get("message", {})
                    names.extend(item["name"] for item in message.get("content", [])
                                 if isinstance(item, dict) and item.get("type") == "toolCall")
                except (json.JSONDecodeError, TypeError):
                    pass
        return names

    def screen(self, pane):
        return self.tmux("capture-pane", "-p", "-t", pane)

    def status(self):
        records = []
        for path in (self.root / "state").glob("*.json"):
            try:
                records.append(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError):
                pass
        return records

    def mark(self, label):
        self.remote("focus-window", "--match", "all")
        self.timeline.append({"event": label, "seconds": round(time.monotonic() - self.start, 2)})
        print(label, flush=True)

    def setup(self):
        self.assert_private()
        assert PREFIX not in (Path("/opt/homebrew"), Path("/usr/local"), Path.home() / ".local"), "Use a private demo prefix, not an installed kido"
        locked = run(["swift", "-e", 'import Foundation; import CoreGraphics; let s = CGSessionCopyCurrentDictionary() as? [String: Any]; print(s?["CGSSessionScreenIsLocked"] as? Bool == true ? "locked" : "unlocked")'], timeout=30).strip()
        if locked == "locked":
            raise RuntimeError("Mac session is locked. Unlock the Mac before recording; Screen Recording permission alone is not enough.")
        self.caffeinate = subprocess.Popen(["/usr/bin/caffeinate", "-du", "-t", "600"])
        self.project.parent.mkdir(parents=True, exist_ok=True)
        self.project.mkdir()
        self.owns_project = True
        for directory in ("tmux", "state", "config/kido", "zsh", "sessions", "bin"):
            (self.root / directory).mkdir(mode=0o700, parents=True, exist_ok=True)
        (self.root / "tmux").chmod(0o700)
        (self.root / "zsh/.zshrc").write_text('''PROMPT='$ '
RPROMPT=''
HISTFILE=/dev/null
unsetopt BEEP
pi() {
  "$KIDO_DEMO_PREFIX/share/kido/bin/pi" --no-extensions \\
    --no-skills --no-prompt-templates --no-context-files --no-themes \\
    --theme "$KIDO_DEMO_THEME" --use-theme demo --session-dir "$KIDO_DEMO_STATE_DIR/sessions" \\
    --extension "$KIDO_DEMO_WORKING" --model "$KIDO_DEMO_MODEL" --thinking low \\
    --name "$KIDO_DEMO_TITLE" --tools "$KIDO_DEMO_TOOLS" \\
    --append-system-prompt "$KIDO_DEMO_INSTRUCTIONS" "$@"
}
''')
        model = os.environ.get("KIDO_DEMO_MODEL", "openai-codex/gpt-6.1-sol")
        self.env["KIDO_DEMO_MODEL"] = model
        self.env["KIDO_DEMO_THEME"] = str(HERE / "pi-theme.json")
        self.env["KIDO_DEMO_WORKING"] = str(HERE / "working.ts")
        self.env["PI_CODING_AGENT_SESSION_DIR"] = str(self.root / "state/sessions")
        self.env["PATH"] = str(self.root / "bin") + ":" + self.env["PATH"]
        wrapper = self.root / "bin/pi"
        wrapper.write_text('''#!/bin/sh
exec "$KIDO_DEMO_PREFIX/share/kido/bin/pi" --no-extensions --no-skills --no-prompt-templates --no-context-files --no-themes --theme "$KIDO_DEMO_THEME" --use-theme demo --extension "$KIDO_DEMO_WORKING" --thinking low "$@"
''')
        wrapper.chmod(0o700)
        (self.root / "config/kido/kido.conf").write_text('''set -g default-shell /bin/zsh
set -g status off
set -g extended-keys on
set -g extended-keys-format csi-u
set -g side-status-width 26
set -g side-status-style 'fg=#dfe8e3,bg=#101714'
set -g pane-border-style 'fg=#2a3a33'
set -g pane-active-border-style 'fg=#2a3a33'
set -g automatic-rename off
set -g allow-rename off
set -g display-panes-time 1
''')
        (self.project / "cli.py").write_text('''import argparse

parser = argparse.ArgumentParser(description="A tiny greeting CLI")
parser.add_argument("name", nargs="?", default="world")
args = parser.parse_args()
print(f"Hello, {args.name}!")
''')
        (self.project / "README.md").write_text(f'''# Greeter
A small local command-line project.

Project files
  cli.py        Greeting command

Try it
  python3 cli.py
  python3 cli.py Ada

Current task: {self.env["KIDO_DEMO_TITLE"]}

Source
------
''')
        self.endpoint = json.loads(run([KIDO, "server"], env=self.env, cwd=self.project))
        expected = self.root / "tmux" / f"tmux-{os.getuid()}" / "kido"
        assert Path(self.endpoint["socket"]).resolve() == expected.resolve(), self.endpoint
        self.tmux("rename-session", "-t", "main", "greeter")
        self.tmux("rename-window", "-t", "greeter:0", "workspace")
        self.kitty = subprocess.Popen([KITTY, "--single-instance=no", "--config", str(HERE / "kitty.conf"),
                                      "--listen-on", f"unix:{self.socket}", "--title", "kido demo",
                                      "--debug-font-fallback", "--directory", str(self.project), KIDO], env=self.env,
                                     stdout=open(self.root / "kitty.log", "w"), stderr=subprocess.STDOUT)
        wait_for("kitty remote socket", self.socket.exists)
        wait_for("kitty terminal", lambda: self.remote("ls"))
        self.window = wait_for("demo OS window", lambda: json.loads(run(
            ["swift", str(HERE / "windows.swift"), str(self.kitty.pid)], timeout=30))) [0]
        self.window_id = str(self.window["kCGWindowNumber"])
        (self.root / "geometry.json").write_text(self.remote("ls"))
        panes = self.tmux("list-panes", "-a", "-F", "#{session_name}:#{window_name}:#{pane_id}").strip().splitlines()
        assert len(panes) == 1 and panes[0].startswith("greeter:workspace:"), panes
        assert not self.status(), "Unexpected agent records before starting demo"
        self.agent = panes[0].rsplit(":", 1)[1]
        wait_for("primed shell", lambda: "$" in self.screen(self.agent))
        self.tmux("send-keys", "-t", self.agent, "-l", "cat README.md cli.py")
        self.tmux("send-keys", "-t", self.agent, "Enter")
        wait_for("representative first frame", lambda: "print(f" in self.screen(self.agent), 10)
        print(f"Isolated server: {self.endpoint['socket']}\nKitty window: {self.window_id}", flush=True)

    def record(self, duration, target):
        self.remote("focus-window", "--match", "all")
        target.unlink(missing_ok=True)
        executable = HERE / "output/capture"
        if not executable.exists() or executable.stat().st_mtime < (HERE / "capture.swift").stat().st_mtime:
            run(["swiftc", "-parse-as-library", str(HERE / "capture.swift"), "-o", str(executable)], timeout=90)
        self.start = time.monotonic()
        self.capture = subprocess.Popen([str(executable), self.window_id, str(duration), str(target)], env=self.env,
                                        stdout=open(self.root / "capture.log", "w"), stderr=subprocess.STDOUT)
        time.sleep(0.8)
        if self.capture.poll() is not None:
            raise RuntimeError("Screen Recording blocked or capture failed: " + (self.root / "capture.log").read_text())

    def cleanup(self):
        if self.capture and self.capture.poll() is None:
            self.capture.terminate()
            self.capture.wait(timeout=10)
        if self.kitty:
            try:
                self.remote("close-window")
            except (subprocess.SubprocessError, OSError):
                pass
            try:
                self.kitty.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.kitty.terminate()
                self.kitty.wait(timeout=5)
        self.assert_private()
        if self.endpoint:
            expected = self.root / "tmux" / f"tmux-{os.getuid()}" / "kido"
            assert Path(self.endpoint["socket"]).resolve() == expected.resolve()
            try:
                self.tmux("kill-server")
            except subprocess.CalledProcessError:
                pass
        if self.owns_project:
            assert self.project == Path.home() / "src/greeter" and not self.project.is_symlink()
            shutil.rmtree(self.project)
        if self.caffeinate:
            self.caffeinate.terminate()
            self.caffeinate.wait(timeout=5)


def encode(source, name, timeline, scenario, mobile=False, keep_poster=False):
    from camera import filters
    MEDIA.mkdir(parents=True, exist_ok=True)
    duration = next(item["seconds"] for item in timeline if item["event"] == "verified") + 3
    review = HERE / "output" / name.removesuffix("-mobile")
    review.mkdir(exist_ok=True)
    camera = getattr(scenario, "MOBILE_CAMERA", scenario.CAMERA) if mobile else scenario.CAMERA
    video_filter = filters(timeline, duration, review, camera, scenario.CUTS, mobile=mobile)
    common = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
              "-an", "-vf", video_filter, "-r", "30"]
    run(common + ["-c:v", "libx264", "-preset", "veryslow", "-tune", "animation", "-crf", "28", "-g", "300", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                  str(MEDIA / f"{name}.mp4")], timeout=180)
    run(common + ["-c:v", "libvpx-vp9", "-crf", "40", "-b:v", "0", "-g", "300", "-row-mt", "1", "-cpu-used", "0", "-pix_fmt", "yuv420p",
                  str(MEDIA / f"{name}.webm")], timeout=300)
    if not keep_poster:
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(MEDIA / f"{name}.mp4"),
             "-frames:v", "1", "-q:v", "2", str(MEDIA / f"{name}.jpg")])
    stills = HERE / "output/stills"
    stills.mkdir(exist_ok=True)
    for stale in stills.glob(f"{name}-*.jpg"):
        stale.unlink()
    rendered_duration = float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(MEDIA / f"{name}.mp4")]))
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-sseof", "-0.1", "-i", str(MEDIA / f"{name}.mp4"),
         "-frames:v", "1", str(stills / f"{name}-end.jpg")])
    for second in (0, 5, 9, 18):
        if second >= rendered_duration:
            continue
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(second), "-i", str(MEDIA / f"{name}.mp4"),
             "-frames:v", "1", str(stills / f"{name}-{second:02}.jpg")])


def encode_variants(source, name, timeline, scenario, keep_poster=False):
    for variant, mobile in ((name, False), (name + "-mobile", True)):
        encode(source, variant, timeline, scenario, mobile=mobile, keep_poster=keep_poster)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", nargs="?", default="tmux", choices=["tmux", "subagents", "async"])
    parser.add_argument("--check", action="store_true", help="Capture a 2-second permission/appearance test only")
    parser.add_argument("--render-only", action="store_true", help="Re-encode the retained source and timeline without launching a demo")
    args = parser.parse_args()
    output = HERE / "output"
    output.mkdir(exist_ok=True)
    spec = importlib.util.spec_from_file_location(args.scenario, HERE / f"scenarios/{args.scenario}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if args.render_only:
        timeline = json.loads((output / f"{args.scenario}-timeline.json").read_text())
        encode_variants(output / f"{args.scenario}-source.mov", args.scenario, timeline, module, keep_poster=True)
        return
    demo = Demo(Path(tempfile.mkdtemp(prefix="kido-demo-", dir="/tmp")))
    demo.env.update(KIDO_DEMO_TITLE=module.TITLE, KIDO_DEMO_TOOLS=module.TOOLS,
                    KIDO_DEMO_INSTRUCTIONS=module.INSTRUCTIONS)
    print(f"Private runtime/logs: {demo.root}", flush=True)
    try:
        demo.setup()
        source = output / ("check.mov" if args.check else f"{args.scenario}-source.mov")
        demo.record(2 if args.check else module.DURATION, source)
        if not args.check:
            module.perform(demo)
        demo.capture.wait(timeout=module.DURATION + 10)
        if demo.capture.returncode or not source.exists():
            raise RuntimeError((demo.root / "capture.log").read_text())
        if not args.check:
            (output / f"{args.scenario}-timeline.json").write_text(json.dumps(demo.timeline, indent=2) + "\n")
        if args.check:
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), "-frames:v", "1", str(output / "check.png")])
        else:
            encode_variants(source, args.scenario, demo.timeline, module)
            shutil.copyfile(demo.root / "kitty.log", output / f"{args.scenario}-fonts.log")

        print(f"Saved: {source}", flush=True)
    finally:
        if demo.endpoint:
            try:
                (demo.root / "last-screen.txt").write_text(demo.screen(demo.agent))
            except (subprocess.SubprocessError, AttributeError):
                pass
        demo.cleanup()


if __name__ == "__main__":
    main()
