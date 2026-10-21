"""Torch against Core ML on the eval units: `uv run parity`. Prints counts only."""

import argparse
import json
import sys

from coreml import COREML, load_coreml
from corpus import load_units
from evaluate import evaluate
from jsonl import DATA, write_json
from label import load_labelled, load_prompt
from model import CHECKPOINT, load, load_tokenizer, torch_taggers
from tagging import OPTION_TRAILING, encode, tags_for
from train import LABELS

TOLERANCE = 0.005


def decode(taggers: dict, texts: list[str]) -> list[list[tuple]]:
    """The questions of each text with their options, as spans."""
    spans = taggers["question"](texts)
    asked = [t[a:b] for t, found in zip(texts, spans, strict=True) for a, b in found]
    options = iter(taggers["option"](asked, OPTION_TRAILING))
    return [[((a, b), tuple(next(options))) for a, b in found] for found in spans]


def agreement(tokenizer, texts: list[str], left: list, right: list) -> float:
    """The share of tokens with the same tag when the decoded spans are tagged again."""
    same = total = 0
    for text, a, b in zip(texts, left, right, strict=True):
        _, offsets = encode(tokenizer, text)
        tags_a = tags_for(offsets, [q for q, _ in a])
        tags_b = tags_for(offsets, [q for q, _ in b])
        same += sum(x == y for x, y in zip(tags_a, tags_b, strict=True))
        total += len(offsets)
    return same / total


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compute", choices=("cpu", "gpu", "all"), default="all")
    args = parser.parse_args(argv)
    rows, _ = load_units()
    records = load_labelled(LABELS, rows, load_prompt())[0]["eval"]
    texts = [r["text"] for r in records]
    tokenizer = load_tokenizer(CHECKPOINT)
    reference = torch_taggers(tokenizer, load(CHECKPOINT))
    coreml_tokenizer, converted = load_coreml(COREML, args.compute)
    torch_scores = evaluate(tokenizer, reference, records)
    coreml_scores = evaluate(coreml_tokenizer, converted, records)
    failing = {}
    for part, scores in torch_scores.items():
        for metric, value in scores.items():
            if abs(value - coreml_scores[part][metric]) > TOLERANCE:
                failing[f"{part}.{metric}"] = [value, coreml_scores[part][metric]]
    left, right = decode(reference, texts), decode(converted, texts)
    different = [i for i, (a, b) in enumerate(zip(left, right, strict=True)) if a != b]
    result = {
        "units": len(texts),
        "metrics_outside_tolerance": failing,
        "units_with_different_decoding": len(different),
        "different_unit_indexes": different[:50],
        "question_tag_agreement": agreement(tokenizer, texts, left, right),
        "torch": torch_scores["all"],
        "coreml": coreml_scores["all"],
    }
    write_json(DATA / "reports" / "parity.json", result)
    print(json.dumps({k: v for k, v in result.items() if k not in ("torch", "coreml")}))
    return 0 if not failing else 1


if __name__ == "__main__":
    sys.exit(main())
