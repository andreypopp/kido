"""The units of the transcripts: the frozen session split, deduplication and the labelling sets."""

import random
from collections.abc import Iterable
from dataclasses import dataclass

from jsonl import DATA, read_json, read_jsonl, sha256, write_json, write_jsonl
from normalise import normalise
from redact import redact
from transcripts import ROOTS, messages
from units import units

SPLIT = DATA / "split.json"
UNITS = DATA / "units.jsonl"
UNITS_META = DATA / "units.json"
SEED = 0
SHARES = (("eval", 0.15), ("dev", 0.10))
SPLITS = ("eval", "dev", "train")
EVAL_SAMPLES = 3


@dataclass(frozen=True)
class Row:
    text: str
    session: str
    split: str


def digest(items: Iterable[str]) -> str:
    return sha256("\n".join(sorted(items)))


def assign(sessions: Iterable[str]) -> dict[str, str]:
    ordered = sorted(set(sessions))
    random.Random(SEED).shuffle(ordered)
    split, start = {}, 0
    for name, share in SHARES:
        count = round(share * len(ordered))
        split |= dict.fromkeys(ordered[start : start + count], name)
        start += count
    return split | dict.fromkeys(ordered[start:], "train")


def freeze_split(sessions: Iterable[str]) -> None:
    split = assign(sessions)
    digests = {name: digest(s for s, n in split.items() if n == name) for name in SPLITS}
    write_json(SPLIT, {"seed": SEED, "digests": digests, "sessions": split})


def load_split() -> dict[str, str]:
    frozen = read_json(SPLIT)
    for name, expected in frozen["digests"].items():
        if digest(s for s, n in frozen["sessions"].items() if n == name) != expected:
            raise ValueError(f"{SPLIT} was edited: the {name} digest differs")
    return frozen["sessions"]


def scan(user: str) -> list[tuple[str, str]]:
    """(session, redacted unit text) of every unit of every assistant message."""
    return [
        (session, redact(unit.text, user=user))
        for source, root in ROOTS.items()
        for session, text in messages(source, root)
        for unit in units(normalise(text, screen=False))
    ]


def deduplicate(
    rows: list[tuple[str, str]], split_of: dict[str, str]
) -> tuple[list[Row], dict[str, int]]:
    """One row for each unit text. A text in several splits stays in eval, else in dev."""
    assigned = [
        Row(text, session, split_of[session]) for session, text in rows if session in split_of
    ]
    best: dict[str, Row] = {}
    shared: set[str] = set()
    for row in assigned:
        kept = best.setdefault(row.text, row)
        if row.split != kept.split:
            shared.add(row.text)
            if SPLITS.index(row.split) < SPLITS.index(kept.split):
                best[row.text] = row
    return list(best.values()), {
        "units": len(rows),
        "unassigned_session": len(rows) - len(assigned),
        "duplicates": len(assigned) - len(best),
        "in_several_splits": len(shared),
    }


def units_digest(rows: Iterable[Row]) -> str:
    return digest(f"{row.split}\t{row.text}" for row in rows)


def build(user: str) -> dict[str, int]:
    """Write the units once, with their digest and the dedup counts. The first call freezes the
    session split too."""
    if UNITS.exists():
        raise FileExistsError(f"{UNITS} is frozen")
    rows = scan(user)
    if not SPLIT.exists():
        freeze_split(session for session, _ in rows)
    found, counts = deduplicate(rows, load_split())
    write_jsonl(UNITS, ({"text": r.text, "session": r.session, "split": r.split} for r in found))
    write_json(UNITS_META, {"digest": units_digest(found), "dedup": counts})
    return counts


def load_units() -> tuple[list[Row], dict[str, int]]:
    """The frozen units and the dedup counts. The unit texts of the three splits are disjoint."""
    rows = [Row(**item) for item in read_jsonl(UNITS)]
    meta = read_json(UNITS_META)
    if units_digest(rows) != meta["digest"]:
        raise ValueError(f"{UNITS} was edited: its digest differs")
    if len({row.text for row in rows}) != len(rows):
        raise ValueError(f"{UNITS} has a unit text in two places")
    return rows, meta["dedup"]


def uniform_order(rows: Iterable[Row]) -> list[Row]:
    return sorted(rows, key=lambda row: sha256(row.text))


def samples(row: Row) -> int:
    return EVAL_SAMPLES if row.split == "eval" else 1


def has_letters(text: str) -> bool:
    return any(char.isalpha() for char in text)


def labelling_rows(rows: list[Row]) -> list[Row]:
    """The units that any labelling set can hold: those with a letter."""
    return [row for row in rows if has_letters(row.text)]
