#!/usr/bin/env python3
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def check(destination):
    executable = destination / "Kido.app/Contents/MacOS/Kido"
    result = subprocess.run(
        ["pgrep", "-f", "^" + re.escape(str(executable)) + "([[:space:]]|$)"],
        stdout=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        sys.exit(f"Quit {destination / 'Kido.app'} before installing it.")
    if result.returncode != 1:
        sys.exit("Cannot check whether Kido is running; installation refused.")


destination = Path(sys.argv[2]).resolve()
check(destination)
if sys.argv[1] == "install":
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / "Kido.app"
    with tempfile.TemporaryDirectory(prefix=".kido-install-", dir=destination) as temporary:
        staged = Path(temporary) / "Kido.app"
        previous = Path(temporary) / "previous.app"
        subprocess.run(["ditto", sys.argv[3], str(staged)], check=True)
        check(destination)
        if target.exists():
            os.rename(target, previous)
        try:
            os.rename(staged, target)
        except OSError:
            if previous.exists():
                os.rename(previous, target)
            raise
    print(f"Installed {target}", flush=True)
    subprocess.run([str(target / "Contents/Resources/ko/bin/ko"), "version"], check=True)
