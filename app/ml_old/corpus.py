"""The real texts: every candidate text of the transcripts, and the AskUserQuestion part.

Both files are written once. select_texts.py freezes the session plan and the selection on
their hashes.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import random
import sys
from pathlib import Path

from jsonl import read_jsonl, write_jsonl
from paths import ASK, CANDIDATES
from questions import CHOICE, label_errors, question_item
from render import CLAUDE, STYLES, ask_questions, render_text, transcript_messages
from segments import BLANK, ITEM, SENTENCE, segments

ROOTS = {
    "pi": Path.home() / ".pi" / "agent" / "sessions",
    "claude": Path.home() / ".claude" / "projects",
}
WIDTH_MIN, WIDTH_MAX = 60, 220
MAX_CHARACTERS = 8000
SETTINGS = {"width": [WIDTH_MIN, WIDTH_MAX], "max_characters": MAX_CHARACTERS}


def question_segments(text: str) -> int:
    """Sentences and list items, outside code and tables, that contain a question mark."""
    return sum(
        1 for s in segments(text) if s.kind in (SENTENCE, ITEM) and "?" in text[s.start : s.end]
    )


def question_paragraphs(text: str) -> int:
    """Blank-separated paragraphs with such a segment."""
    count, marked = 0, False
    for s in segments(text):
        if s.kind == BLANK:
            count, marked = count + marked, False
        elif s.kind in (SENTENCE, ITEM) and "?" in text[s.start : s.end]:
            marked = True
    return count + marked


def is_positive(record: dict[str, object]) -> bool:
    return bool(record["question_segments"])


def is_multi_candidate(record: dict[str, object]) -> bool:
    return int(record["question_segments"]) >= 2  # type: ignore[call-overload]


def digest_of(session: str, text: str) -> str:
    return hashlib.sha256(f"{session}\0{text}".encode()).hexdigest()


def width_of(digest: str) -> int:
    return random.Random(digest).randint(WIDTH_MIN, WIDTH_MAX)


def scan(user: str) -> dict[str, int]:
    """Every assistant text block of the transcripts, rendered at a random width."""
    if CANDIDATES.exists():
        raise FileExistsError(f"{CANDIDATES} is frozen")
    records: list[dict[str, object]] = []
    seen: set[str] = set()
    counts = {"blocks": 0, "too_long": 0, "duplicates": 0}
    for source, root in ROOTS.items():
        for message in transcript_messages(root, source):
            counts["blocks"] += 1
            if len(message.text) > MAX_CHARACTERS:
                counts["too_long"] += 1
                continue
            digest = digest_of(message.session, message.text)
            if digest in seen:
                counts["duplicates"] += 1
                continue
            seen.add(digest)
            width = width_of(digest)
            text = render_text(message.text, width, STYLES[source], user)
            records.append(
                {
                    "id": digest[:16],
                    "session": message.session,
                    "source": source,
                    "width": width,
                    "question_segments": question_segments(text),
                    "question_paragraphs": question_paragraphs(text),
                    "text": text,
                }
            )
    write_jsonl(CANDIDATES, records)
    counts["texts"] = len(records)
    counts["positive"] = sum(map(is_positive, records))
    counts["multi"] = sum(map(is_multi_candidate, records))
    return counts


def ask_part(user: str) -> dict[str, int]:
    """Texts with exact labels from the AskUserQuestion calls: the question, then its options."""
    if ASK.exists():
        raise FileExistsError(f"{ASK} is frozen")
    records: list[dict[str, object]] = []
    counts = {"questions": 0, "invalid": 0}
    seen: set[str] = set()
    for session, question, labels in ask_questions(ROOTS["claude"]):
        counts["questions"] += 1
        digest = digest_of(session, question + "\0" + "\0".join(labels))
        if digest in seen:
            continue
        seen.add(digest)
        listing = "\n".join(f"{n}. {label}" for n, label in enumerate(labels, 1))
        text = render_text(f"{question}\n\n{listing}", width_of(digest), CLAUDE, user)
        label = {"questions": [question_item(text, 1, len(segments(text)), CHOICE, labels)]}
        if label_errors(text, label):
            counts["invalid"] += 1
            continue
        records.append(
            {
                "id": digest[:16],
                "session": session,
                "source": "claude",
                "width": width_of(digest),
                "text": text,
                "label": label,
            }
        )
    write_jsonl(ASK, records)
    counts["texts"] = len(records)
    return counts


def candidates() -> list[dict[str, object]]:
    return read_jsonl(CANDIDATES)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("scan", "ask"))
    args = parser.parse_args(argv)
    user = getpass.getuser()
    print(json.dumps(scan(user) if args.command == "scan" else ask_part(user)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
