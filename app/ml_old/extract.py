"""Extract the questions and their options from a text: `uv run extract [FILE]`."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

from chunks import B, Chunk, Encoded, I, encode, option_input, plan, slots
from flat import Flat, question_body
from metrics import Found
from model import (
    COMPUTE_UNITS,
    DEFAULT_COMPUTE,
    TorchBackend,
    load_crf,
    load_models,
    load_threshold,
    load_tokenizer,
    require_flat,
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
    cuts = enc.flat.cuts
    found = []
    for first, last in runs(tags):
        start, end = cuts[present[first][0]].start, cuts[present[last][0]].end
        left = start - cuts[present[0][0]].start if chunk.lo > 0 else FAR
        right = cuts[present[-1][0]].end - end if chunk.hi < len(enc.ids) else FAR
        if min(left, right) > 0:
            found.append((start, end, min(left, right)))
    return found


def questions(backend, enc: Encoded, windows=plan) -> list[tuple[int, int]]:
    """Question ranges in text order. Of overlapping questions from several windows the one
    farthest from its window edge stays."""
    found = [
        item
        for chunk in windows(enc)
        for item in chunk_questions(enc, chunk, backend.question_tags(enc, chunk))
    ]
    kept: list[tuple[int, int, int]] = []
    for start, end, edge in sorted(found, key=lambda item: -item[2]):
        if all(end <= other[0] or other[1] <= start for other in kept):
            kept.append((start, end, edge))
    return sorted((start, end) for start, end, _ in kept)


def options(tokenizer, backend, text: str, flat: Flat, start: int, end: int) -> tuple[str, ...]:
    """The options of the question text[start:end], in text order, as substrings of it. The
    option pass reads the flat question, its first OPTION_LENGTH tokens; a span on spaces of the
    flat text snaps inward to the characters that it has in text."""
    body, shift = question_body(flat, start, end)
    ids, offsets = option_input(tokenizer, body)
    tags = backend.tags("option", ids)
    real = [n for n, (a, b) in enumerate(offsets) if a != b]
    found: list[str] = []
    for first, last in runs([tags[n] for n in real]):
        a, b = offsets[real[first]][0], offsets[real[last]][1]
        while a < b and body[a].isspace():
            a += 1
        while a < b and body[b - 1].isspace():
            b -= 1
        if a == b:
            continue
        option = text[flat.origin[shift + a] : flat.origin[shift + b - 1] + 1]
        if option not in found:
            found.append(option)
    return tuple(found)


def predict(tokenizer, backend, text: str, windows=plan) -> list[Found]:
    enc = encode(tokenizer, text)
    return [
        (start, end, options(tokenizer, backend, text, enc.flat, start, end))
        for start, end in questions(backend, enc, windows)
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
    models, which hold their own tokenizer and settings. A directory made for another input is
    refused: its model would read the wrong text."""
    require_flat(path)
    tokenizer = load_tokenizer(path)
    if backend == "torch":
        return tokenizer, TorchBackend(load_models(path), load_threshold(path), load_crf(path))
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
    try:
        tokenizer, backend = load(path, args.backend, args.compute)
    except ValueError as error:
        sys.exit(f"extract: {error}")
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
