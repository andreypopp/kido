"""Extract the questions and their options from a text: `uv run extract [FILE]`."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

from chunks import B, Chunk, Encoded, I, encode, ids_of, option_input, plan, slots
from metrics import Found
from model import (
    COMPUTE_UNITS,
    DEFAULT_COMPUTE,
    TorchBackend,
    load_models,
    load_threshold,
    load_tokenizer,
)
from paths import COREML, MODEL

FAR = 10**9


def runs(tags: list[int]) -> list[tuple[int, int]]:
    """Inclusive index ranges: B I*. An I that does not follow B or I starts nothing."""
    found: list[tuple[int, int]] = []
    start = None
    for index, tag in enumerate(tags):
        if tag == I and start is not None:
            continue
        if start is not None:
            found.append((start, index - 1))
        start = index if tag == B else None
    if start is not None:
        found.append((start, len(tags) - 1))
    return found


def chunk_questions(enc: Encoded, chunk: Chunk, tags: list[int]) -> list[tuple[int, int, int]]:
    """(start, end, distance from the chunk edge) of the questions that the chunk found. One that
    touches a cut edge of the chunk is dropped."""
    present = slots(enc, chunk)
    cuts = enc.cuts
    found = []
    for first, last in runs([tags[position] for _, position in present]):
        start, end = cuts[present[first][0]].start, cuts[present[last][0]].end
        left = start - cuts[present[0][0]].start if chunk.lo > 0 else FAR
        right = cuts[present[-1][0]].end - end if chunk.hi < len(enc.ids) else FAR
        if min(left, right) > 0:
            found.append((start, end, min(left, right)))
    return found


def questions(tokenizer, backend, text: str, windows=plan) -> list[tuple[int, int]]:
    """Question ranges in text order. Of overlapping questions from several windows the one
    farthest from its window edge stays."""
    enc = encode(tokenizer, text)
    found = [
        item
        for chunk in windows(enc)
        for item in chunk_questions(enc, chunk, backend.tags("question", ids_of(enc, chunk)))
    ]
    kept: list[tuple[int, int, int]] = []
    for start, end, edge in sorted(found, key=lambda item: -item[2]):
        if all(end <= other[0] or other[1] <= start for other in kept):
            kept.append((start, end, edge))
    return sorted((start, end) for start, end, _ in kept)


def options(tokenizer, backend, text: str, start: int, end: int) -> tuple[str, ...]:
    """The options of the question text[start:end], in text order, as substrings of it. Only the
    first OPTION_LENGTH tokens of the question are read."""
    body = text[start:end]
    ids, offsets = option_input(tokenizer, body)
    tags = backend.tags("option", ids)
    real = [n for n, (a, b) in enumerate(offsets) if a != b]
    found: list[str] = []
    for first, last in runs([tags[n] for n in real]):
        option = body[offsets[real[first]][0] : offsets[real[last]][1]].strip()
        if option and option not in found:
            found.append(option)
    return tuple(found)


def predict(tokenizer, backend, text: str, windows=plan) -> list[Found]:
    return [
        (start, end, options(tokenizer, backend, text, start, end))
        for start, end in questions(tokenizer, backend, text, windows)
    ]


def contract(text: str, found: list[Found], *, ranges: bool = False) -> dict[str, object]:
    return {
        "questions": [
            {"question": text[start:end], "options": list(opts)}
            | ({"range": [start, end]} if ranges else {})
            for start, end, opts in found
        ]
    }


def load(path: Path, backend: str = "torch", compute: str = DEFAULT_COMPUTE):
    """The tokenizer and the backend of a directory: a PyTorch checkpoint, or converted Core ML
    models, which hold their own tokenizer and settings."""
    tokenizer = load_tokenizer(path)
    if backend == "torch":
        return tokenizer, TorchBackend(load_models(path), load_threshold(path))
    from coreml_runtime import CoreMLBackend  # imports coremltools, which torch runs avoid

    return tokenizer, CoreMLBackend(path, compute)


def timed(call, runs: int) -> dict[str, float]:
    """Milliseconds of the first call, which loads the function, then p50 and p95 of the runs."""
    started = time.perf_counter()
    call()
    first = (time.perf_counter() - started) * 1000
    times = []
    for _ in range(runs):
        started = time.perf_counter()
        call()
        times.append((time.perf_counter() - started) * 1000)
    return {
        "first_ms": round(first, 1),
        "p50_ms": round(float(np.percentile(times, 50)), 2),
        "p95_ms": round(float(np.percentile(times, 95)), 2),
        "runs": runs,
    }


def positive(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return value


def read_input(file: Path | None) -> str:
    """UTF-8 text from a file or stdin, with its line ends unchanged so that ranges hold."""
    data = file.read_bytes() if file else sys.stdin.buffer.read()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(
            f"the input is not valid UTF-8 ({error.reason} at byte {error.start})"
        ) from None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", type=Path, help="plain text; stdin if absent")
    parser.add_argument("--backend", choices=["torch", "coreml"], default="torch")
    parser.add_argument("--model", type=Path, default=MODEL, help="the PyTorch checkpoint")
    parser.add_argument("--coreml", type=Path, default=COREML, help="the converted models")
    parser.add_argument("--compute", choices=COMPUTE_UNITS, default=DEFAULT_COMPUTE)
    parser.add_argument("--ranges", action="store_true", help="add the character range")
    parser.add_argument("--bench", type=positive, metavar="N", help="time N extractions")
    args = parser.parse_args(argv)
    try:
        text = read_input(args.file)
    except ValueError as error:
        sys.exit(f"extract: {error}")
    started = time.perf_counter()
    path = args.model if args.backend == "torch" else args.coreml
    tokenizer, backend = load(path, args.backend, args.compute)
    if args.bench:
        load_ms = round((time.perf_counter() - started) * 1000, 1)
        result = timed(lambda: predict(tokenizer, backend, text), args.bench)
        print(json.dumps({"load_ms": load_ms, **result}))
        return 0
    found = predict(tokenizer, backend, text)
    print(json.dumps(contract(text, found, ranges=args.ranges), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
