"""Phase 1 measures from saved texts and labels. No API calls."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import random
import sys
from pathlib import Path

from deepseek import DATA
from jsonl import read_jsonl, write_jsonl
from questions import questions_of
from render import STYLES, render_text, transcript_messages
from segments import segments
from spike import ROOTS, TEXTS, WIDTH_MAX, WIDTH_MIN, labels_path, question_segments

TOKENIZER = Path("data-paragraphs/models/ettin")
MISSES = DATA / "spike-misses.jsonl"
MANIFEST = DATA / "tokens-manifest.jsonl"


def labelled(mode: str) -> list[tuple[dict[str, object], dict[str, object]]]:
    texts = {str(r["id"]): r for r in read_jsonl(TEXTS)}
    return [(texts[str(item["id"])], item) for item in read_jsonl(labels_path(mode))]


def boundaries(mode: str) -> dict[str, object]:
    """Share of question starts and ends that fall on a segment boundary."""
    misses, starts_ok, ends_ok, total = [], 0, 0, 0
    for record, item in labelled(mode):
        text = str(record["text"])
        cuts = [s for s in segments(text) if s.kind != "blank"]
        begins, finishes = {s.start for s in cuts}, {s.end for s in cuts}
        for question in questions_of(text, item["label"]):  # type: ignore[arg-type]
            total += 1
            for which, offset, ok in (
                ("start", question.start, question.start in begins),
                ("end", question.end, question.end in finishes),
            ):
                if ok:
                    starts_ok += which == "start"
                    ends_ok += which == "end"
                else:
                    misses.append(
                        {
                            "id": record["id"],
                            "which": which,
                            "offset": offset,
                            "source": record["source"],
                            "before": text[max(0, offset - 60) : offset],
                            "after": text[offset : offset + 60],
                        }
                    )
    write_jsonl(MISSES, misses)
    return {
        "texts": len(labelled(mode)),
        "questions": total,
        "starts_on_boundary": starts_ok,
        "ends_on_boundary": ends_ok,
        "share": round((starts_ok + ends_ok) / max(1, 2 * total), 4),
        "misses": len(misses),
    }


def kinds_and_options(mode: str) -> dict[str, object]:
    kinds: dict[str, int] = {}
    options = 0
    for record, item in labelled(mode):
        for question in questions_of(str(record["text"]), item["label"]):  # type: ignore[arg-type]
            kinds[question.kind] = kinds.get(question.kind, 0) + 1
            options += len(question.options)
    return {"kinds": kinds, "options": options}


def compare(first: str, second: str) -> dict[str, object]:
    """Agreement of two labelling modes on the texts that both labelled, and the drop bias."""
    texts = {str(r["id"]): r for r in read_jsonl(TEXTS)}
    found = {
        mode: {
            str(r["id"]): questions_of(str(texts[str(r["id"])]["text"]), r["label"])  # type: ignore[arg-type]
            for r in read_jsonl(labels_path(mode))
        }
        for mode in (first, second)
    }
    both = sorted(found[first].keys() & found[second].keys())
    same_count = same_ranges = 0
    matched = same_options = left_questions = 0
    for key in both:
        a, b = found[first][key], found[second][key]
        same_count += len(a) == len(b)
        same_ranges += [(q.start, q.end) for q in a] == [(q.start, q.end) for q in b]
        by_range = {(q.start, q.end): q for q in b}
        left_questions += len(a)
        for q in a:
            other = by_range.get((q.start, q.end))
            if other is not None:
                matched += 1
                same_options += set(q.options) == set(other.options)

    def drop_rate(mode: str, several: bool) -> str:
        pool = [i for i, r in texts.items() if (int(r["question_segments"]) >= 2) == several]  # type: ignore[call-overload]
        dropped = [i for i in pool if i not in found[mode]]
        return f"{len(dropped)}/{len(pool)}"

    return {
        "both_labelled": len(both),
        "same_question_count": same_count,
        "same_ranges": same_ranges,
        "questions_in_first": left_questions,
        "questions_with_same_range": matched,
        "of_those_same_option_set": same_options,
        "dropped_multi_question_texts": {m: drop_rate(m, True) for m in (first, second)},
        "dropped_other_texts": {m: drop_rate(m, False) for m in (first, second)},
    }


def tokens(user: str) -> dict[str, object]:
    """Token counts (with special tokens) of whole rendered messages, in three populations.

    The manifest holds ids, hashes and counts, no text.
    """
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(str(TOKENIZER))
    positives = {
        str(r["id"])
        for r, item in labelled("think")
        if questions_of(str(r["text"]), item["label"])  # type: ignore[arg-type]
    }
    rows: list[dict[str, object]] = []
    for source, root in ROOTS.items():
        batch = []
        for message in transcript_messages(root, source):
            digest = hashlib.sha256(f"{message.session}\0{message.text}".encode()).hexdigest()
            width = random.Random(digest).randint(WIDTH_MIN, WIDTH_MAX)
            batch.append((digest, width, render_text(message.text, width, STYLES[source], user)))
        encoded = tokenizer([text for _, _, text in batch], add_special_tokens=True)["input_ids"]
        for (digest, width, text), ids in zip(batch, encoded, strict=True):
            rows.append(
                {
                    "id": digest[:16],
                    "hash": hashlib.sha256(text.encode()).hexdigest()[:16],
                    "source": source,
                    "width": width,
                    "chars": len(text),
                    "tokens": len(ids),
                    "question_segments": question_segments(text),
                }
            )
    write_jsonl(MANIFEST, rows)
    populations = {
        "all blocks": rows,
        "blocks with a question mark outside code": [r for r in rows if r["question_segments"]],
        "labelled positives (spike)": [r for r in rows if str(r["id"]) in positives],
    }
    report: dict[str, object] = {}
    for name, values in populations.items():
        sizes = sorted(int(r["tokens"]) for r in values)  # type: ignore[call-overload]
        if not sizes:
            continue
        over = sum(size > 1024 for size in sizes)
        report[name] = {
            "messages": len(sizes),
            "p50": sizes[len(sizes) // 2],
            "p90": sizes[int(len(sizes) * 0.9)],
            "p99": sizes[int(len(sizes) * 0.99)],
            "max": sizes[-1],
            "over_1024": over,
            "over_1024_share": round(over / len(sizes), 4),
            "chars_over_4000": sum(int(r["chars"]) > 4000 for r in values),  # type: ignore[call-overload]
        }
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("boundaries").add_argument("--mode", default="think")
    commands.add_parser("kinds").add_argument("--mode", default="think")
    pair = commands.add_parser("compare")
    pair.add_argument("first")
    pair.add_argument("second")
    commands.add_parser("tokens")
    args = parser.parse_args(argv)
    if args.command == "boundaries":
        result = boundaries(args.mode)
    elif args.command == "kinds":
        result = kinds_and_options(args.mode)
    elif args.command == "compare":
        result = compare(args.first, args.second)
    else:
        result = tokens(getpass.getuser())
    print(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
