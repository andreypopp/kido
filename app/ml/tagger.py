"""Tag one paragraph context from a file or stdin with the chosen checkpoint."""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from bench import latency, measure_load
from eval import (
    COMPUTE_UNITS,
    SHAPES,
    CoreML,
    Torch,
    contains,
    line_at,
    line_classes,
    load_checkpoint,
    padded,
    shape_for,
    tags_from_logits,
    tokenize,
    trim_span,
)
from render import MARKER, Line, partition_blocks, prompt_lines
from runtime import PACKAGE, chosen_checkpoint
from validate import option_kind, tags_to_spans, unit_from_classes


def parse(text: str) -> tuple[list[str], list[list[int]], list[int]]:
    lines: list[str] = []
    maps: list[list[int]] = []
    marked: list[int] = []
    offset = 0
    for raw in text.splitlines(keepends=True):
        body = raw.rstrip("\r\n")
        chars: list[str] = []
        sources: list[int] = []
        index = 0
        if body.startswith(">"):
            marked.append(len(lines))
            index = 1
            if body[1:2] == " ":
                index = 2
        while index < len(body):
            if body.startswith("**", index):
                index += 2
                continue
            chars.append(body[index])
            sources.append(offset + index)
            index += 1
        lines.append("".join(chars))
        maps.append(sources)
        offset += len(raw)
    return lines, maps, marked


def assemble(
    lines: list[str],
    maps: list[list[int]],
    low: int,
    high: int,
    hover_start: int,
    hover_end: int,
) -> tuple[str, list[int | None]]:
    prompt: list[str] = []
    mapping: list[int | None] = []
    for position, index in enumerate(range(low, high + 1)):
        prefix = f"{'>' if hover_start <= index <= hover_end else ' '} {position + 1}: "
        prompt.append(prefix)
        mapping.extend([None] * len(prefix))
        for char, source in zip(lines[index], maps[index], strict=True):
            prompt.append(char)
            mapping.append(source)
        if index != high:
            prompt.append("\n")
            mapping.append(None)
    return "".join(prompt), mapping


def read_context(text: str, hover: int | None, tokenizer):
    lines, maps, marked = parse(text)
    if not lines:
        raise ValueError("empty context")
    rows = [Line((0, 0), value) for value in lines]
    blocks = partition_blocks(rows)
    if not blocks:
        raise ValueError("empty context")
    if hover is not None:
        position = hover - 1
        if not 0 <= position < len(lines):
            raise ValueError(f"line {hover} is outside the context")
    elif marked:
        position = marked[0]
    else:
        raise ValueError("no hovered line: mark one with '>' or use --hover N")
    hovered_block = next(
        (
            index
            for index, block in enumerate(blocks)
            if block.start <= position <= block.end
        ),
        None,
    )
    if hovered_block is None:
        raise ValueError(f"line {position + 1} is blank")
    low, high = 0, len(blocks) - 1
    while True:
        start, end = blocks[low].start, blocks[high].end
        prompt, mapping = assemble(
            lines,
            maps,
            start,
            end,
            blocks[hovered_block].start,
            blocks[hovered_block].end,
        )
        ids, mask, offsets = tokenize(tokenizer, prompt, None)
        if len(ids) <= SHAPES[-1]:
            break
        if low == high:
            raise ValueError(
                f"the hovered paragraph is longer than {SHAPES[-1]} tokens"
            )
        if hovered_block - low >= high - hovered_block:
            low += 1
        else:
            high -= 1
    ranges = [
        [block.start - start, block.end - start] for block in blocks[low : high + 1]
    ]
    return (
        prompt,
        mapping,
        ranges,
        hovered_block - low,
        len(blocks) - (high - low + 1),
        shape_for(len(ids)),
        ids,
        mask,
        offsets,
    )


def input_span(mapping: list[int | None], start: int, end: int) -> tuple[int, int]:
    while start < end and mapping[start] is None:
        start += 1
    while end > start and mapping[end - 1] is None:
        end -= 1
    if start >= end or mapping[start] is None or mapping[end - 1] is None:
        raise ValueError("option outside the input text")
    return mapping[start], mapping[end - 1] + 1


def summarise(
    prompt: str,
    offsets: list[list[int]],
    tags: list[str],
    ranges: list[list[int]],
    hovered: int,
    mapping: list[int | None],
) -> dict[str, object]:
    classes = line_classes(prompt, offsets, tags)
    unit = unit_from_classes(prompt, classes, ranges, hovered)
    first, last = unit or ranges[hovered]
    span = contains(unit, ranges[hovered])
    rows = prompt_lines(prompt)
    spans = tags_to_spans(tags, offsets)
    option_lines = {
        int(row["index"]) - 1
        for start, end, value in spans
        if value == "option"
        for row in rows
        if int(row["start"]) <= start < int(row["end"])
        and MARKER.match(str(row["text"]))
    }
    question = " ".join(
        text
        for index, row in enumerate(rows)
        if first <= index <= last
        and index not in option_lines
        and (text := str(row["text"]))
    )
    options = []
    for start, end, value in spans:
        if value != "option":
            continue
        start, end = trim_span(prompt, start, end)
        source = input_span(mapping, start, end)
        row = line_at(prompt, start)
        options.append(
            {
                "text": prompt[start:end],
                "start": source[0],
                "end": source[1],
                "line": int(row["index"]) if row is not None else None,
                "kind": option_kind(prompt, start),
            }
        )
    return {
        "question": (question or None) if span else None,
        "options": [option["text"] for option in options],
        "isQuestion": span,
        "firstLine": first + 1,
        "lastLine": last + 1,
        "optionRanges": options,
        "lines": [
            {"line": int(row["index"]), "class": classes[index], "text": row["text"]}
            for index, row in enumerate(rows)
        ],
        "tags": [
            {"start": start, "end": end, "tag": tag}
            for tag, (start, end) in zip(tags, offsets, strict=True)
        ],
    }


def quiet() -> None:
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    logging.getLogger("coremltools").setLevel(logging.ERROR)
    logging.getLogger(
        "torch.distributed.elastic.multiprocessing.redirects"
    ).setLevel(logging.ERROR)
    from transformers.utils import logging as transformers_logging

    transformers_logging.disable_progress_bar()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", type=Path)
    parser.add_argument("--backend", choices=["torch", "coreml"], default="torch")
    parser.add_argument("--compute", choices=list(COMPUTE_UNITS), default="gpu")
    parser.add_argument("--hover", type=int, metavar="N")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--bench", type=int, metavar="N")
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--model", type=Path, default=PACKAGE)
    args = parser.parse_args(argv)
    quiet()
    if args.file:
        with args.file.open("r", encoding="utf-8", newline="") as handle:
            text = handle.read()
    else:
        text = sys.stdin.read()
    checkpoint = args.checkpoint or chosen_checkpoint()
    _, max_length, tokenizer = load_checkpoint(checkpoint)
    try:
        prompt, mapping, ranges, hovered, dropped, shape, ids, mask, offsets = read_context(
            text, args.hover, tokenizer
        )
    except ValueError as error:
        print(f"tagger: {error}", file=sys.stderr)
        return 1
    if args.backend == "torch":
        backend = Torch(checkpoint)
    else:
        backend = CoreML(args.model, args.compute, tokenizer.pad_token_id)
    length = len(ids)
    if args.backend == "coreml":
        ids, mask = padded(ids, mask, shape, tokenizer.pad_token_id)

        def predict():
            return backend.predict(shape, ids, mask)

        def load():
            backend.load([shape])

    else:

        def predict():
            return backend.logits(ids, mask)

        def load():
            backend.load()

    load_ms = measure_load(load, predict)
    if args.bench:
        result = latency(predict, args.bench)
        print(
            json.dumps(
                {
                    "backend": args.backend,
                    "compute": args.compute,
                    "load_ms": load_ms,
                    **result,
                    "runs": args.bench,
                },
                sort_keys=True,
            )
        )
        return 0
    tags = tags_from_logits(predict()[:length])
    result = summarise(prompt, offsets, tags, ranges, hovered, mapping)
    result["shape"] = shape
    result["droppedParagraphs"] = dropped
    if args.json:
        print(json.dumps(result, indent=2))
        return 0
    for row in result["lines"]:
        print(f"{row['line']:>3} {row['class']:<8} {row['text']}")
    print(f"question: {result['question']}")
    for option in result["optionRanges"]:
        print(
            f"option [{option['start']}:{option['end']}] "
            f"line {option['line']} ({option['kind']}): {option['text']!r}"
        )
    print(f"unit: lines {result['firstLine']}-{result['lastLine']}")
    print(f"isQuestion: {json.dumps(result['isQuestion'])}")
    if dropped:
        print(f"dropped paragraphs: {dropped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
