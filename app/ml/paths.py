"""Where the data lives. Offline stages and the API client share these paths."""

from __future__ import annotations

from pathlib import Path

DATA = Path("data")
OLD = Path("data-paragraphs")
OLD_LEDGER = OLD / "usage.jsonl"
OLD_PLAN = OLD / "session-plan.json"
TOKENIZER = OLD / "models" / "ettin"
LEDGER = DATA / "usage.jsonl"
CACHE = DATA / "response-cache"
PLAN = DATA / "session-plan.json"
CANDIDATES = DATA / "candidates.jsonl"
ASK = DATA / "eval-ask.jsonl"
SELECTION = DATA / "selection.json"
NEGATIVES = DATA / "selection-negatives.json"
MANIFEST = Path("manifest.json")


def synthetic_path(part: str) -> Path:
    return DATA / f"synthetic-{part}.jsonl"


def samples_path(stage: str) -> Path:
    return DATA / f"samples-{stage}.jsonl"


def labels_path(stage: str) -> Path:
    return DATA / f"labels-{stage}.jsonl"


def drops_path(stage: str) -> Path:
    return DATA / f"drops-{stage}.jsonl"


def output_path(name: str) -> Path:
    return DATA / f"{name}.jsonl"
