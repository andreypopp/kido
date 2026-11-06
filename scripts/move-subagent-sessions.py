#!/usr/bin/env -S python3 -I
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description="Move registered ko-pi child sessions out of pi's resume list. Run while no child agents restart: the live check is a snapshot.")
    parser.add_argument("--agent-dir", type=Path, default=Path(os.environ.get("PI_CODING_AGENT_DIR") or "~/.pi/agent"))
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = args.agent_dir.expanduser()
    files = sorted((root / "sessions").glob("*/*.jsonl"))
    children = set()
    sessions = {}
    for file in files + sorted((root / "ko-subagents").glob("*/*.jsonl")):
        with file.open() as source:
            for index, line in enumerate(source):
                header = index == 0 and file.parent.parent == root / "sessions"
                if not header and "ko-pi.child" not in line:
                    continue
                entry = json.loads(line)
                if header and entry.get("type") == "session":
                    sessions[file] = entry["id"]
                if entry.get("type") == "custom" and entry.get("customType") == "ko-pi.child":
                    child = entry.get("data", {}).get("session")
                    if isinstance(child, str):
                        children.add(child)
    response = subprocess.run(["ko", "api", "/panes"], check=True, capture_output=True, text=True, timeout=10)
    panes = json.loads(response.stdout)
    live = {pane.get("vars", {}).get("pi.session") for pane in panes if not pane.get("dead")}
    moved = blocked = 0
    for file in files:
        if sessions.get(file) not in children:
            continue
        destination = root / "ko-subagents" / file.relative_to(root / "sessions")
        if sessions[file] in live:
            print(f"LIVE: {file}")
            blocked += 1
            continue
        print(f"{'MOVE' if args.apply else 'WOULD MOVE'}: {file} -> {destination}")
        if args.apply:
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.link(file, destination)
            os.unlink(file)
        moved += 1
    print(f"{'Moved' if args.apply else 'Would move'}: {moved}; live, refused: {blocked}; normal files scanned: {len(files)}")


if __name__ == "__main__":
    main()
