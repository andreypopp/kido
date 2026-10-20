"""Measure the Ettin token count distribution of the rendered contexts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from transformers import AutoTokenizer

from render import read_jsonl
from runtime import MODEL


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("data/contexts.jsonl"))
    parser.add_argument("--output", type=Path, default=Path("data/token-counts.json"))
    args = parser.parse_args(argv)
    tokenizer = AutoTokenizer.from_pretrained(MODEL)
    counts = []
    for record in read_jsonl(args.input):
        counts.append(len(tokenizer(str(record["prompt"]), add_special_tokens=True)["input_ids"]))
    values = np.array(counts)
    result = {
        "contexts": len(counts),
        "min": int(values.min()),
        "p50": float(np.percentile(values, 50)),
        "p90": float(np.percentile(values, 90)),
        "p99": float(np.percentile(values, 99)),
        "max": int(values.max()),
        "over_512": int((values > 512).sum()),
        "over_1024": int((values > 1024).sum()),
        "over_2048": int((values > 2048).sum()),
        "over_512_share": float((values > 512).mean()),
        "over_1024_share": float((values > 1024).mean()),
        "over_2048_share": float((values > 2048).mean()),
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
