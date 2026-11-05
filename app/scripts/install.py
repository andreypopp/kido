#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
import tempfile

destination = Path(sys.argv[1]).resolve()
destination.mkdir(parents=True, exist_ok=True)
target = destination / "Kido.app"
with tempfile.TemporaryDirectory(prefix=".kido-install-", dir=destination) as temporary:
    staged = Path(temporary) / "Kido.app"
    previous = Path(temporary) / "previous.app"
    subprocess.run(["ditto", sys.argv[2], str(staged)], check=True)
    if target.exists():
        os.rename(target, previous)
    try:
        os.rename(staged, target)
    except OSError:
        if previous.exists():
            os.rename(previous, target)
        raise
print(f"Installed {target}; quit and reopen a running Kido to use it", flush=True)
subprocess.run([str(target / "Contents/Resources/ko/bin/ko"), "version"], check=True)
