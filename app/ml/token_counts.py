"""Measure the Ettin token count distribution of the train, dev and eval examples."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from eval import SHAPES, load_checkpoint, shape_for, token_length
from render import read_jsonl
from runtime import chosen_checkpoint
from validate import example


def distribution(tokenizer, path: Path, max_length: int, bold: bool) -> dict[str, object]:
    lengths = [token_length(tokenizer, example(record, bold)[0]) for record in read_jsonl(path)]
    counts = {str(shape): 0 for shape in SHAPES}
    for length in lengths:
        counts[str(shape_for(length))] += 1
    ordered = sorted(lengths)
    return {
        "examples": len(lengths),
        "buckets": counts,
        "truncated": sum(length > max_length for length in lengths),
        "min": ordered[0],
        "median": ordered[len(ordered) // 2],
        "max": ordered[-1],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--output", type=Path, default=Path("data/token-counts.json"))
    args = parser.parse_args(argv)
    checkpoint = args.checkpoint or chosen_checkpoint()
    bold, max_length, tokenizer = load_checkpoint(checkpoint)
    result = {
        "checkpoint": str(checkpoint),
        "bold": bold,
        "max_length": max_length,
        "splits": {
            split: distribution(
                tokenizer, Path(f"data/{split}.jsonl"), max_length, bold
            )
            for split in ("train", "dev", "eval")
        },
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
