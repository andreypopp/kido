"""The first attempt's checkpoint, scored with the new metrics. Deleted after phase 3."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import torch
from transformers import AutoModelForTokenClassification, AutoTokenizer

from jsonl import read_jsonl
from metrics import Counts, Found, add_text, summary
from paths import output_path
from questions import questions_of
from segments import segments
from split import is_synthetic

CHECKPOINT = Path("data-paragraphs/output/phase2-nobold-s0")
TAGS = ["O", "B-QUESTION", "I-QUESTION", "B-OPTION", "I-OPTION"]
MAX_LENGTH = 1024


def line_classes(
    offsets: list[tuple[int, int]], tags: list[str], rows: list[tuple[int, int]]
) -> list[str]:
    votes = [{"question": 0, "option": 0} for _ in rows]
    for tag, (start, end) in zip(tags, offsets, strict=True):
        if tag == "O" or start == end:
            continue
        overlaps = [min(end, b) - max(start, a) for a, b in rows]
        best = max(range(len(rows)), key=overlaps.__getitem__)
        if overlaps[best] > 0:
            votes[best][tag.split("-", 1)[1].lower()] += 1
    return [
        "question"
        if v["question"] > v["option"]
        else "option"
        if v["option"] > v["question"]
        else "other"
        for v in votes
    ]


def units(classes: list[str], blank: list[bool]) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    first = last = None
    for index, value in enumerate(classes):
        if value != "other":
            first = index if first is None else first
            last = index
        elif first is not None and not blank[index]:
            runs.append((first, last))  # type: ignore[arg-type]
            first = last = None
    if first is not None:
        runs.append((first, last))  # type: ignore[arg-type]
    return runs


def predict(model, tokenizer, text: str, device) -> list[Found]:
    text_rows = text.split("\n")
    row_starts = [sum(len(r) + 1 for r in text_rows[:i]) for i in range(len(text_rows))]
    prompt_rows, prompt = [], ""
    for index, row in enumerate(text_rows):
        prefix = f"  {index + 1}: "
        prompt_rows.append((len(prompt) + len(prefix), len(prompt) + len(prefix) + len(row)))
        prompt += prefix + row + ("\n" if index + 1 < len(text_rows) else "")
    encoded = tokenizer(prompt, return_offsets_mapping=True, truncation=True, max_length=MAX_LENGTH)
    with torch.no_grad():
        logits = model(
            input_ids=torch.tensor([encoded["input_ids"]], device=device),
            attention_mask=torch.tensor([encoded["attention_mask"]], device=device),
        ).logits[0]
    tags = [TAGS[i] for i in logits.argmax(-1).tolist()]
    offsets = [tuple(pair) for pair in encoded["offset_mapping"]]
    classes = line_classes(offsets, tags, prompt_rows)  # type: ignore[arg-type]
    option_spans = []
    current = None
    for tag, (start, end) in zip(tags, offsets, strict=True):
        if tag.endswith("OPTION") and start != end:
            if tag.startswith("B-") or current is None:
                if current:
                    option_spans.append(current)
                current = [start, end]
            else:
                current[1] = end
        elif current:
            option_spans.append(current)
            current = None
    if current:
        option_spans.append(current)
    options: list[tuple[int, str]] = []
    for start, end in option_spans:
        for index, (a, b) in enumerate(prompt_rows):
            if a <= start and end <= b:
                at = row_starts[index] + start - a
                options.append((at, text[at : at + end - start]))
    found: list[Found] = []
    cuts = [s for s in segments(text) if s.kind != "blank"]
    for first, last in units(classes, [not r.strip() for r in text_rows]):
        low, high = row_starts[first], row_starts[last] + len(text_rows[last])
        inside = [s for s in cuts if low <= s.start and s.end <= high]
        if not inside:
            continue
        groups, group = [], []
        for segment in inside:
            group.append(segment)
            row = max(i for i, start in enumerate(row_starts) if start <= segment.start)
            if text[segment.start : segment.end].endswith("?") and classes[row] == "question":
                groups.append(group)
                group = []
        if group:
            if groups:
                groups[-1] += group
            else:
                groups.append(group)
        for members in groups:
            start, end = members[0].start, members[-1].end
            found.append((start, end, tuple(o for at, o in options if start <= at < end)))
    return found


def main() -> int:
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    tokenizer = AutoTokenizer.from_pretrained(CHECKPOINT)
    model = AutoModelForTokenClassification.from_pretrained(CHECKPOINT).to(device).eval()
    report = {}
    for part in ("eval-real", "eval-negative", "eval-ask", "synthetic"):
        records = [
            r
            for r in read_jsonl(output_path("eval"))
            if (part == "synthetic" and is_synthetic(r)) or r["part"] == part
        ]
        counts = Counts()
        for record in records:
            text = str(record["text"])
            gold = [(q.start, q.end, q.options) for q in questions_of(text, record["label"])]  # type: ignore[arg-type]
            add_text(counts, gold, predict(model, tokenizer, text, device))
        report[part] = summary(counts)
    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
