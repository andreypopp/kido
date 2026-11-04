#!/usr/bin/env python3
import pathlib
import re
import subprocess
import sys

manifest = pathlib.Path(sys.argv[1]) / "test-dirs"
owned = set(manifest.read_text().splitlines()) if manifest.exists() else set()
processes = subprocess.run(
    ["/bin/ps", "-axo", "pid=,command="], check=True, capture_output=True, text=True, timeout=5
).stdout.splitlines()
leaks = []
for process in processes:
    match = re.search(r"(?:server --server|mismatch-server) (/tmp/ko-kp-[A-Za-z0-9]+)(?: |$)", process)
    if match and match[1] in owned:
        leaks.append(process.strip())
if leaks:
    sys.exit("ko-test: test servers still running:\n" + "\n".join(leaks))
