"""JSON and JSON lines files: reads, writes, a private append and an id digest."""

from __future__ import annotations

import hashlib
import json
import os
from collections.abc import Iterable
from pathlib import Path


def read_jsonl(path: Path) -> list[dict[str, object]]:
    """The records of a file; a missing file has none."""
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def write_jsonl(path: Path, items: Iterable[object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(item) + "\n" for item in items))


def append_jsonl(path: Path, item: object) -> None:
    line = (json.dumps(item) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, line)
    finally:
        os.close(descriptor)


def read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text())


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=1) + "\n")


def write_once(path: Path, value: object) -> None:
    """A frozen file: a second write is an error."""
    if path.exists():
        raise FileExistsError(f"{path} is frozen")
    write_json(path, value)


def digest(ids: Iterable[str]) -> str:
    """Order-free digest of a set of ids."""
    return hashlib.sha256("\n".join(sorted(ids)).encode()).hexdigest()[:16]


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]
