"""Deduplicate contexts and split them by session."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

from datasketch import MinHash, MinHashLSH

from render import PROMPT_LINE, read_jsonl, write_jsonl
from validate import label_errors


def normalized(prompt: str) -> str:
    values = []
    for line in prompt.splitlines():
        match = PROMPT_LINE.match(line)
        values.append((match.group(3) if match else line).strip())
    return "\n".join(" ".join(line.split()) for line in values)


def shingles(text: str) -> set[str]:
    lines = normalized(text).splitlines()
    values = set(lines)
    values.update(" ".join(lines[index : index + 2]) for index in range(len(lines) - 1))
    return values


def minhash(text: str) -> MinHash:
    sketch = MinHash(num_perm=64)
    for value in shingles(text):
        sketch.update(value.encode())
    return sketch


def deduplicate(
    records: list[dict[str, object]], near: bool = True
) -> tuple[list[dict[str, object]], int, int]:
    exact: set[str] = set()
    kept: list[dict[str, object]] = []
    exact_dropped = 0
    near_dropped = 0
    lsh = MinHashLSH(threshold=0.8, num_perm=64)
    for record in sorted(records, key=lambda item: str(item["id"])):
        prompt = str(record["prompt"])
        key = normalized(prompt)
        digest = hashlib.sha256(key.encode()).hexdigest()
        if digest in exact:
            exact_dropped += 1
            continue
        exact.add(digest)
        if near:
            sketch = minhash(prompt)
            if lsh.query(sketch):
                near_dropped += 1
                continue
            lsh.insert(str(record["id"]), sketch)
        kept.append(record)
    return kept, exact_dropped, near_dropped


def assign_sessions(
    records: list[dict[str, object]], eval_fraction: float = 0.2
) -> tuple[list[str], list[str]]:
    sessions = sorted({str(record["session"]) for record in records})
    ask_sessions = {
        str(record["session"]) for record in records if record.get("source") == "ask"
    }
    rng = random.Random(0)
    others = [session for session in sessions if session not in ask_sessions]
    rng.shuffle(others)
    wanted = max(len(ask_sessions), round(len(sessions) * eval_fraction))
    eval_sessions = set(ask_sessions)
    for session in others:
        if len(eval_sessions) >= wanted:
            break
        eval_sessions.add(session)
    train = [
        str(record["id"]) for record in records if str(record["session"]) not in eval_sessions
    ]
    evaluation = [
        str(record["id"]) for record in records if str(record["session"]) in eval_sessions
    ]
    return train, evaluation


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contexts", type=Path, default=Path("data/contexts.jsonl"))
    parser.add_argument("--labels", type=Path, default=Path("data/labels.jsonl"))
    parser.add_argument("--output-dir", type=Path, default=Path("data"))
    parser.add_argument("--eval-fraction", type=float, default=0.2)
    parser.add_argument("--dev", action="store_true")
    args = parser.parse_args(argv)
    if args.dev:
        records = read_jsonl(Path("data/train.jsonl"))
        train_ids, dev_ids = assign_sessions(records, 0.2)
        by_id = {str(record["id"]): record for record in records}
        write_jsonl(Path("data/dev-train.jsonl"), [by_id[i] for i in train_ids])
        write_jsonl(Path("data/dev.jsonl"), [by_id[i] for i in dev_ids])
        summary = {
            "train": len(train_ids),
            "dev": len(dev_ids),
            "train_sessions": len({str(by_id[i]["session"]) for i in train_ids}),
            "dev_sessions": len({str(by_id[i]["session"]) for i in dev_ids}),
        }
        Path("data/dev-meta.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, sort_keys=True))
        return 0
    records = read_jsonl(args.contexts)
    labels = {
        str(item["id"]): item["label"] for item in read_jsonl(args.labels)
    }
    labelled: list[dict[str, object]] = []
    rejected = 0
    for record in records:
        label = record.get("label", labels.get(str(record["id"])))
        if label is None:
            continue
        if label_errors(str(record["prompt"]), label):
            rejected += 1
            continue
        labelled.append({**record, "label": label})
    if not labelled:
        print("split: no labelled contexts", file=sys.stderr)
        return 1
    kept, exact_dropped, near_dropped = deduplicate(labelled)
    train_ids, eval_ids = assign_sessions(kept, args.eval_fraction)
    by_id = {str(record["id"]): record for record in kept}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, ids in (("train", train_ids), ("eval", eval_ids)):
        write_jsonl(args.output_dir / f"{name}.jsonl", [by_id[identifier] for identifier in ids])
    summary = {
        "labelled": len(labelled),
        "kept": len(kept),
        "exact_duplicates": exact_dropped,
        "near_duplicates": near_dropped,
        "invalid_labels": rejected,
        "train": len(train_ids),
        "eval": len(eval_ids),
        "train_sessions": len({str(by_id[i]["session"]) for i in train_ids}),
        "eval_sessions": len({str(by_id[i]["session"]) for i in eval_ids}),
    }
    Path("data/split-meta.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
