"""Generate template examples with exact labels for the phase 0 pipeline proof."""

from __future__ import annotations

import argparse
import getpass
import json
import random
from pathlib import Path

from render import (
    SEED,
    context_record,
    cut_context,
    logical_lines,
    partition_blocks,
    render_markdown,
    sample_width,
    write_jsonl,
)
from split import deduplicate
from validate import label_errors

FILLER = [
    "The build finished without errors.",
    "I checked the logs and the cache is warm.",
    "This paragraph is context from an earlier turn.",
    "The next paragraph is not part of the question.",
    "A short note about the current task.",
]
TRAIN = [
    ("Which option should I use?", ["alpha one", "beta two"], "ordered"),
    ("Pick a color for the header.", ["green", "amber", "slate"], "bullet"),
    ("Should I use alpha or beta for the build?", ["alpha", "beta"], "inline"),
    ("What is the fastest way to build the project?", [], "plain"),
    ("The build uses the cached compiler and writes to the build directory.", [], "prose"),
    ("Follow these steps to reproduce the failure.", ["run the build", "read the log"], "steps"),
    ("The file list is below.", ["main.swift", "render.py"], "files"),
]
EVAL = [
    ("Choose a database for the test run.", ["sqlite", "postgres"], "lettered"),
    ("Do you want the long report or the short note?", ["long report", "short note"], "inline2"),
    ("How should the cache be cleared?", [], "plain2"),
    ("The release notes follow this paragraph.", [], "prose2"),
    ("Run the checks in this order.", ["unit checks", "end-to-end checks"], "ordered2"),
    ("The artifacts are listed here.", ["build.log", "test.log"], "files2"),
]
MARKERS = {
    "ordered": ("{}. ", False),
    "steps": ("{}. ", False),
    "bullet": ("- ", True),
    "files": ("- ", True),
    "lettered": ("{}) ", "letter"),
    "ordered2": ("{}. ", False),
    "files2": ("- ", True),
}


def unit_markdown(question: str, options: list[str], kind: str) -> tuple[str, list[str]]:
    if kind in ("inline", "inline2", "plain", "plain2", "prose", "prose2") or not options:
        return question, []
    marker, style = MARKERS[kind]
    lines = []
    for index, option in enumerate(options):
        if style == "letter":
            prefix = marker.format(chr(ord("a") + index))
        elif style:
            prefix = marker
        else:
            prefix = marker.format(index + 1)
        lines.append(prefix + option)
    separator = "  \n" if style == "letter" else "\n"
    return question + "\n\n" + separator.join(lines), lines


def make_example(
    rng: random.Random, template: tuple[str, list[str], str], positive: bool, session: str
) -> dict[str, object]:
    question, options, kind = template
    unit, _ = unit_markdown(question, options, kind)
    before = "\n\n".join(rng.sample(FILLER, rng.randint(1, 2)))
    after = "\n\n".join(rng.sample(FILLER, rng.randint(1, 2)))
    markdown = before + "\n\n" + unit + "\n\n" + after
    width = sample_width(rng)
    rows = render_markdown(markdown, width)
    blocks = partition_blocks(logical_lines(rows))
    target = question.strip()
    hovered_block = next((block for block in blocks if block.text.strip() == target), None)
    if hovered_block is None:
        raise RuntimeError(f"synthetic question block not found: {template!r}")
    context = cut_context(rows, hovered_block.lines[0].rows[0])
    if context is None:
        raise RuntimeError("synthetic context is empty")
    ranges = context.ranges
    hovered = context.hovered
    classes = ["other"] * len(context.lines)
    option_entries: list[dict[str, object]] = []
    if positive:
        question_range = ranges[hovered]
        for index in range(question_range[0], question_range[1] + 1):
            classes[index] = "question"
        if options and kind not in ("inline", "inline2"):
            option_range = ranges[hovered + 1]
            for index in range(option_range[0], option_range[1] + 1):
                classes[index] = "option"
            for offset, option in enumerate(options):
                option_entries.append({"line": option_range[0] + offset + 1, "text": option})
        elif options:
            for option in options:
                option_entries.append({"line": question_range[0] + 1, "text": option})
    label = {"lines": classes, "options": option_entries}
    record = context_record(
        session=session,
        source="synthetic",
        context=context,
        width=width,
        user=getpass.getuser(),
        label=label,
    )
    if record is None:
        raise RuntimeError("synthetic record is empty")
    errors = label_errors(str(record["prompt"]), record["label"])
    if errors:
        raise RuntimeError(f"synthetic label invalid: {errors[:3]}")
    return record


def build(output: Path, train_count: int = 240, eval_count: int = 80) -> dict[str, int]:
    rng = random.Random(SEED)
    train: list[dict[str, object]] = []
    evaluation: list[dict[str, object]] = []
    for index in range(train_count):
        positive = index % 2 == 0
        template = TRAIN[(index // 2) % len(TRAIN)]
        train.append(
            make_example(rng, template, positive, f"synthetic-train-{index // 4}")
        )
    for index in range(eval_count):
        positive = index % 2 == 0
        template = EVAL[(index // 2) % len(EVAL)]
        evaluation.append(
            make_example(rng, template, positive, f"synthetic-eval-{index // 4}")
        )
    train, train_exact, train_near = deduplicate(train, near=False)
    evaluation, eval_exact, eval_near = deduplicate(evaluation, near=False)
    write_train = output / "train.jsonl"
    write_eval = output / "eval.jsonl"
    write_jsonl(write_train, train)
    write_jsonl(write_eval, evaluation)
    return {
        "train": len(train),
        "eval": len(evaluation),
        "train_exact_duplicates": train_exact,
        "train_near_duplicates": train_near,
        "eval_exact_duplicates": eval_exact,
        "eval_near_duplicates": eval_near,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("data/synthetic"))
    parser.add_argument("--train-count", type=int, default=240)
    parser.add_argument("--eval-count", type=int, default=80)
    args = parser.parse_args(argv)
    print(json.dumps(build(args.output, args.train_count, args.eval_count), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
