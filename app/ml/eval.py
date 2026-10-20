"""Measure token F1, option spans, unit ranges and question false positives."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

import torch

from render import prompt_lines, read_jsonl
from runtime import device
from validate import TAGS, bio, example, tags_to_spans

IGNORE = "IGNORE"


def gold_tags(offsets: list[list[int]], spans: list[tuple[int, int, str]]) -> list[str]:
    return [IGNORE if value == -100 else TAGS[value] for value in bio(offsets, spans)]


def predict(
    model, tokenizer, prompt: str, max_length: int
) -> tuple[list[list[int]], list[str]]:
    encoded = tokenizer(
        prompt,
        return_offsets_mapping=True,
        add_special_tokens=True,
        truncation=True,
        max_length=max_length,
    )
    with torch.no_grad():
        outputs = model(
            input_ids=torch.tensor([encoded["input_ids"]], device=model.device),
            attention_mask=torch.tensor([encoded["attention_mask"]], device=model.device),
        )
    tags = [TAGS[index] for index in outputs.logits[0].argmax(dim=-1).tolist()]
    return [list(pair) for pair in encoded["offset_mapping"]], tags


def line_classes(
    prompt: str, offsets: list[list[int]], tags: list[str]
) -> list[str]:
    rows = prompt_lines(prompt)
    counts = [{"question": 0, "option": 0} for _ in rows]
    for tag, (start, end) in zip(tags, offsets, strict=True):
        if tag in (IGNORE, "O"):
            continue
        value = tag.split("-", 1)[1].lower()
        best = None
        for index, row in enumerate(rows):
            overlap = min(end, int(row["end"])) - max(start, int(row["start"]))
            if overlap > 0 and (best is None or overlap > best[0]):
                best = (overlap, index)
        if best is not None:
            counts[best[1]][value] += 1
    return [
        "question"
        if values["question"] > values["option"]
        else "option"
        if values["option"] > values["question"]
        else "other"
        for values in counts
    ]


def unit_from_classes(
    classes: list[str], ranges: list[list[int]]
) -> tuple[int, int] | None:
    tagged = [
        index
        for index, value in enumerate(classes)
        if value != "other" and any(pair[0] <= index <= pair[1] for pair in ranges)
    ]
    if not tagged:
        return None
    first, last = tagged[0], tagged[-1]
    low = next(index for index, pair in enumerate(ranges) if pair[0] <= first <= pair[1])
    high = next(index for index, pair in enumerate(ranges) if pair[0] <= last <= pair[1])
    return (ranges[low][0], ranges[high][1])


def contains(unit: tuple[int, int] | None, range_: list[int]) -> bool:
    return unit is not None and unit[0] <= range_[0] and unit[1] >= range_[1]


OPTION_MARKER = re.compile(
    r"^\s*(?:[-*•]\s+|\d+[.)]\s+|[A-Za-z]\)\s+)?"
)


def normalise_option(prompt: str, start: int, end: int) -> str:
    value = prompt[start:end].strip()
    for _ in range(2):
        match = OPTION_MARKER.match(value)
        if match is None or match.end() == 0:
            break
        value = value[match.end() :].strip()
    return " ".join(value.replace("**", "").split())


def error_analysis(cases: list[dict[str, object]]) -> dict[str, int]:
    from render import prompt_lines

    result = {
        "gold_options": 0,
        "exact_range": 0,
        "off_by_whitespace_marker": 0,
        "partly_overlapping": 0,
        "missed": 0,
        "spurious_inside_gold_unit": 0,
        "spurious_negative_context": 0,
    }
    for case in cases:
        prompt = str(case["prompt"])
        gold = list(case["gold_options"].elements())
        predicted = list(case["predicted_options"].elements())
        used: set[int] = set()
        for start, end in gold:
            result["gold_options"] += 1
            exact = next(
                (
                    index
                    for index, pair in enumerate(predicted)
                    if index not in used and pair == (start, end)
                ),
                None,
            )
            if exact is not None:
                used.add(exact)
                result["exact_range"] += 1
                continue
            value = normalise_option(prompt, start, end)
            near = next(
                (
                    index
                    for index, pair in enumerate(predicted)
                    if index not in used
                    and normalise_option(prompt, pair[0], pair[1]) == value
                ),
                None,
            )
            if near is not None:
                used.add(near)
                result["off_by_whitespace_marker"] += 1
                continue
            partial = next(
                (
                    index
                    for index, pair in enumerate(predicted)
                    if index not in used and pair[0] < end and start < pair[1]
                ),
                None,
            )
            if partial is not None:
                used.add(partial)
                result["partly_overlapping"] += 1
            else:
                result["missed"] += 1
        rows = prompt_lines(prompt)
        unit = case["gold_unit"]
        for index, (start, _end) in enumerate(predicted):
            if index in used:
                continue
            line = next(
                (
                    int(row["index"])
                    for row in rows
                    if int(row["start"]) <= start < int(row["end"])
                ),
                None,
            )
            if unit is not None and line is not None and unit[0] <= line <= unit[1]:
                result["spurious_inside_gold_unit"] += 1
            else:
                result["spurious_negative_context"] += 1
    return result


def metrics(cases: list[dict[str, object]]) -> dict[str, object]:
    parts: dict[str, list[dict[str, object]]] = defaultdict(list)
    for case in cases:
        parts[str(case["part"])].append(case)
    result = metrics_only(cases)
    result["parts"] = {name: metrics_only(values) for name, values in sorted(parts.items())}
    result["errors"] = error_analysis(cases)
    return result


def metrics_only(cases: list[dict[str, object]]) -> dict[str, object]:
    token_counts: dict[str, dict[str, int]] = defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0})
    option_tp = option_pred = option_gold = 0
    unit_correct = unit_total = 0
    negatives = false_positives = 0
    for case in cases:
        for tag in ("QUESTION", "OPTION"):
            counts = token_counts[tag.lower()]
            for predicted_tag, gold_tag in zip(
                case["predicted_tags"], case["gold_tags"], strict=True
            ):
                if gold_tag == IGNORE:
                    continue
                predicted_hit = predicted_tag.endswith(tag)
                gold_hit = gold_tag.endswith(tag)
                if predicted_hit and gold_hit:
                    counts["tp"] += 1
                elif predicted_hit:
                    counts["fp"] += 1
                elif gold_hit:
                    counts["fn"] += 1
        option_tp += sum((case["gold_options"] & case["predicted_options"]).values())
        option_pred += sum(case["predicted_options"].values())
        option_gold += sum(case["gold_options"].values())
        unit_total += 1
        unit_correct += case["gold_unit"] == case["predicted_unit"]
        if case["gold_question"] is False:
            negatives += 1
            false_positives += bool(case["predicted_question"])
    precision = option_tp / option_pred if option_pred else 0.0
    recall = option_tp / option_gold if option_gold else 0.0
    return {
        "examples": len(cases),
        "token_f1": {
            name: {
                "f1": (
                    2 * counts["tp"] / (2 * counts["tp"] + counts["fp"] + counts["fn"])
                    if counts["tp"] + counts["fp"] + counts["fn"]
                    else 0.0
                ),
                **counts,
            }
            for name, counts in token_counts.items()
        },
        "option": {
            "precision": precision,
            "recall": recall,
            "f1": 2 * precision * recall / (precision + recall) if precision + recall else 0.0,
        },
        "unit_accuracy": unit_correct / unit_total if unit_total else 0.0,
        "question_false_positive_rate": false_positives / negatives if negatives else 0.0,
        "negatives": negatives,
    }


def trim_span(prompt: str, start: int, end: int) -> tuple[int, int]:
    while start < end and (prompt[start].isspace() or prompt[start] == "*"):
        start += 1
    while end > start and (prompt[end - 1].isspace() or prompt[end - 1] == "*"):
        end -= 1
    return start, end


def make_case(
    record: dict[str, object],
    prompt: str,
    gold_spans: list[tuple[int, int, str]],
    offsets: list[list[int]],
    predicted_tags: list[str],
) -> dict[str, object]:
    ranges = [list(pair) for pair in record["ranges"]]
    hovered = int(record["hovered"])
    predicted_spans = tags_to_spans(predicted_tags, offsets)
    gold_unit = unit_from_classes(record["label"]["lines"], ranges)
    predicted_unit = unit_from_classes(
        line_classes(prompt, offsets, predicted_tags), ranges
    )
    return {
        "part": "ask" if record.get("source") == "ask" else str(record.get("source", "real")),
        "gold_tags": gold_tags(offsets, gold_spans),
        "predicted_tags": predicted_tags,
        "gold_options": Counter(
            trim_span(prompt, start, end)
            for start, end, value in gold_spans
            if value == "option"
        ),
        "predicted_options": Counter(
            trim_span(prompt, start, end)
            for start, end, value in predicted_spans
            if value == "option"
        ),
        "gold_unit": gold_unit,
        "predicted_unit": predicted_unit,
        "gold_question": contains(gold_unit, ranges[hovered]),
        "predicted_question": contains(predicted_unit, ranges[hovered]),
        "prompt": prompt,
    }


def eval_ettin(args: argparse.Namespace) -> dict[str, object]:
    from transformers import AutoModelForTokenClassification, AutoTokenizer

    meta = json.loads((args.model / "training.json").read_text())
    bold = bool(meta["bold"])
    max_length = int(meta["max_length"])
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForTokenClassification.from_pretrained(args.model, attn_implementation="sdpa")
    model.to(device())
    model.eval()
    cases = []
    for record in read_jsonl(args.eval):
        prompt, gold_spans = example(record, bold)
        offsets, predicted_tags = predict(model, tokenizer, prompt, max_length)
        cases.append(make_case(record, prompt, gold_spans, offsets, predicted_tags))
    return metrics(cases)


def eval_createml(args: argparse.Namespace) -> dict[str, object]:
    meta = json.loads((args.model / "training.json").read_text())
    bold = bool(meta["bold"])
    predictions = json.loads((args.model / "predictions.json").read_text())
    texts = json.loads((args.model / "eval-text.json").read_text())
    records = {str(record["id"]): record for record in read_jsonl(args.eval)}
    cases = []
    for prediction, text in zip(predictions, texts, strict=True):
        record = records[str(text["id"])]
        prompt, gold_spans = example(record, bold)
        offsets = [[item["start"], item["end"]] for item in text["offsets"]]
        cases.append(make_case(record, prompt, gold_spans, offsets, prediction))
    return metrics(cases)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eval", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--backend", choices=["ettin", "createml"], default="ettin")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    result = eval_ettin(args) if args.backend == "ettin" else eval_createml(args)
    output = args.output or (args.model / "eval.json")
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
