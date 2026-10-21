"""Print the questions of a text and their options: `uv run extract [FILE]`."""

import argparse
import json
import sys
from pathlib import Path

from model import CHECKPOINT, load, load_tokenizer, torch_taggers
from normalise import normalise
from tagging import MAX_TOKENS, OPTION_TRAILING, token_count
from units import category, units


def extract(tokenizer, taggers: dict, text: str) -> tuple[list[dict], int]:
    """Questions in text order, and how many units were cut at the token limit. Each question is
    a substring of text, as are its options."""
    found = [u for u in units(normalise(text, screen=True)) if category(u.text) != "other"]
    cut = sum(token_count(tokenizer, u.text) > MAX_TOKENS for u in found)
    spans = taggers["question"]([u.text for u in found])
    asked = [(u, a, b) for u, pairs in zip(found, spans, strict=True) for a, b in pairs]
    options = taggers["option"]([u.text[a:b] for u, a, b in asked], OPTION_TRAILING)
    out = []
    for (unit, a, b), inner in zip(asked, options, strict=True):
        start, end = unit.origin[a], unit.origin[b - 1] + 1
        ranges = [(unit.origin[a + x], unit.origin[a + y - 1] + 1) for x, y in inner]
        out.append(
            {
                "question": text[start:end],
                "options": [text[x:y] for x, y in ranges],
                "range": [start, end],
                "option_ranges": [list(r) for r in ranges],
            }
        )
    return out, cut


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", type=Path, help="UTF-8 text; stdin if absent")
    parser.add_argument("--ranges", action="store_true", help="add character offsets in the input")
    parser.add_argument("--backend", choices=("torch", "coreml"), default="torch")
    parser.add_argument(
        "--compute", choices=("cpu", "gpu", "all"), default="all", help="Core ML only"
    )
    parser.add_argument("--model", type=Path, help="checkpoint or Core ML directory")
    args = parser.parse_args(argv)
    raw = args.file.read_bytes() if args.file else sys.stdin.buffer.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        print("extract: input is not UTF-8", file=sys.stderr)
        return 1
    if args.backend == "torch":
        path = args.model or CHECKPOINT
        ready = (path / "question").is_dir()
    else:
        from coreml import COREML, load_coreml  # imported here: coremltools is slow to import

        path = args.model or COREML
        ready = (path / "settings.json").is_file()
    if not ready:
        print(
            f"extract: no {args.backend} model in {path}; train or convert first", file=sys.stderr
        )
        return 1
    if args.backend == "torch":
        tokenizer = load_tokenizer(path)
        taggers = torch_taggers(tokenizer, load(path))
    else:
        tokenizer, taggers = load_coreml(path, args.compute)
    questions, cut = extract(tokenizer, taggers, text)
    if cut:
        print(f"extract: {cut} unit(s) cut at {MAX_TOKENS} tokens", file=sys.stderr)
    if not args.ranges:
        questions = [{"question": q["question"], "options": q["options"]} for q in questions]
    print(json.dumps({"questions": questions}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
