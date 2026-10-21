"""What a report was made from: the code and the input files."""

from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path

from jsonl import file_digest


def code_state() -> dict[str, str]:
    """The git revision and a hash of the contents of the sources, which may be uncommitted."""
    sources = "".join(f"{p.name}:{file_digest(p)}\n" for p in sorted(Path().glob("*.py")))
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()
    return {"revision": revision, "source_hash": hashlib.sha256(sources.encode()).hexdigest()[:16]}


def input_hashes(**files: Path) -> dict[str, str]:
    return {name: file_digest(path) for name, path in files.items()}
