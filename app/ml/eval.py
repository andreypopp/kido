"""Measure token F1, option spans, unit ranges and question false positives."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from render import MARKER, REAL_PARTS, part_of, prompt_lines, read_jsonl
from runtime import chosen_checkpoint, device
from validate import (
    TAGS,
    bio,
    example,
    option_kind,
    tags_to_spans,
    unit_from_classes,
    unit_indexes,
)

IGNORE = "IGNORE"
SHAPES = [512, 1024, 2048]
COMPUTE_UNITS = {
    "cpu": "CPU_ONLY",
    "gpu": "CPU_AND_GPU",
    "ane": "CPU_AND_NE",
    "all": "ALL",
}
DEFAULT_COMPUTE_UNITS = "gpu"


def compute_unit(name: str):
    import coremltools as ct

    return getattr(ct.ComputeUnit, COMPUTE_UNITS[name])


def gold_tags(offsets: list[list[int]], spans: list[tuple[int, int, str]]) -> list[str]:
    return [IGNORE if value == -100 else TAGS[value] for value in bio(offsets, spans)]


def token_length(tokenizer, text: str) -> int:
    return len(tokenizer(text, add_special_tokens=True)["input_ids"])


def shape_for(length: int) -> int:
    return next((shape for shape in SHAPES if length <= shape), SHAPES[-1])


def tokenize(tokenizer, prompt: str, max_length: int | None):
    options = {"return_offsets_mapping": True, "add_special_tokens": True}
    if max_length is not None:
        options.update(truncation=True, max_length=max_length)
    encoded = tokenizer(prompt, **options)
    return (
        encoded["input_ids"],
        encoded["attention_mask"],
        [list(pair) for pair in encoded["offset_mapping"]],
    )


def synthetic_prompt(tokenizer, target: int) -> str:
    sentence = "The build writes one line to the log. "
    text = ""
    while token_length(tokenizer, text) < target:
        text += sentence
    while token_length(tokenizer, text) > target:
        text = text.rsplit(" ", 1)[0]
    return text


def padded(ids: list[int], mask: list[int], shape: int, pad_id: int):
    pad = shape - len(ids)
    return (
        np.array([ids + [pad_id] * pad], dtype=np.int32),
        np.array([mask + [0] * pad], dtype=np.int32),
    )


class Torch:
    def __init__(self, path: Path):
        self.path = path
        self.model = None

    def load(self) -> None:
        from transformers import AutoModelForTokenClassification

        self.model = AutoModelForTokenClassification.from_pretrained(
            self.path, attn_implementation="sdpa"
        )
        self.model.to(device())
        self.model.eval()

    def logits(self, ids, mask) -> np.ndarray:
        import torch

        with torch.no_grad():
            outputs = self.model(
                input_ids=torch.tensor([ids], device=self.model.device),
                attention_mask=torch.tensor([mask], device=self.model.device),
            )
        return outputs.logits[0].cpu().numpy()


class CoreML:
    def __init__(
        self,
        path: Path,
        compute_units: str = DEFAULT_COMPUTE_UNITS,
        pad_id: int | None = None,
        compiled: bool = False,
    ):
        self.path = path
        self.compute_units = compute_units
        self.pad_id = pad_id
        self.compiled = compiled
        self.models = {}
        import coremltools
        from coremltools.models import CompiledMLModel

        self._coremltools = coremltools
        self._compiled_model = CompiledMLModel

    def load(self, shapes: list[int]) -> None:
        for shape in shapes:
            if shape in self.models:
                continue
            unit = compute_unit(self.compute_units)
            if self.compiled:
                self.models[shape] = self._compiled_model(
                    str(self.path), compute_units=unit, function_name=f"shape_{shape}"
                )
            else:
                self.models[shape] = self._coremltools.models.MLModel(
                    str(self.path), compute_units=unit, function_name=f"shape_{shape}"
                )

    def predict(self, shape: int, ids, mask) -> np.ndarray:
        self.load([shape])
        prediction = self.models[shape].predict(
            {"input_ids": ids.astype(np.int32), "attention_mask": mask.astype(np.int32)}
        )
        return np.asarray(prediction["logits"])[0]

    def logits(self, ids, mask) -> np.ndarray:
        shape = shape_for(len(ids))
        arrays = padded(ids[:shape], mask[:shape], shape, self.pad_id)
        return self.predict(shape, arrays[0], arrays[1])[: len(ids)]


def tags_from_logits(values) -> list[str]:
    return [TAGS[index] for index in values.argmax(axis=-1).tolist()]


def predict(
    logits, tokenizer, prompt: str, max_length: int
) -> tuple[list[list[int]], list[str]]:
    ids, mask, offsets = tokenize(tokenizer, prompt, max_length)
    return offsets, tags_from_logits(logits(ids, mask))


def load_checkpoint(path: Path):
    from transformers import AutoTokenizer

    meta = json.loads((path / "training.json").read_text())
    return (
        bool(meta["bold"]),
        int(meta["max_length"]),
        AutoTokenizer.from_pretrained(path),
    )


def evaluate(
    eval_path: Path, logits, bold: bool, max_length: int, tokenizer
) -> dict[str, object]:
    cases = []
    for record in read_jsonl(eval_path):
        prompt, gold_spans = example(record, bold)
        offsets, predicted_tags = predict(logits, tokenizer, prompt, max_length)
        cases.append(make_case(record, prompt, gold_spans, offsets, predicted_tags))
    return metrics(cases)


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


def contains(unit: tuple[int, int] | None, range_: list[int]) -> bool:
    return unit is not None and unit[0] <= range_[0] and unit[1] >= range_[1]


def line_at(prompt: str, position: int) -> dict[str, object] | None:
    return next(
        (
            row
            for row in prompt_lines(prompt)
            if int(row["start"]) <= position < int(row["end"])
        ),
        None,
    )


def size_bucket(value: int) -> str:
    if value <= 2:
        return str(value)
    return "3-5" if value <= 5 else "6+"


def unit_text(prompt: str, unit: tuple[int, int] | None) -> str:
    if unit is None:
        return ""
    return " ".join(
        str(row["text"])
        for row in prompt_lines(prompt)
        if unit[0] <= int(row["index"]) - 1 <= unit[1]
    )


def error_analysis(cases: list[dict[str, object]]) -> dict[str, int]:
    result: Counter[str] = Counter()
    punctuation = set(".,:;!?)]}\"'")
    for case in cases:
        prompt = str(case["prompt"])
        gold = list(case["gold_options"].elements())
        predicted = list(case["predicted_options"].elements())
        used: set[int] = set()
        result["gold_options"] += len(gold)
        result["predicted_options"] += len(predicted)
        for start, end in gold:
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
            overlapping = [
                index
                for index, pair in enumerate(predicted)
                if index not in used and pair[0] < end and start < pair[1]
            ]
            if not overlapping:
                result["missed"] += 1
                result[f"missed_{option_kind(prompt, start)}"] += 1
                continue
            index = max(
                overlapping,
                key=lambda value: min(end, predicted[value][1])
                - max(start, predicted[value][0]),
            )
            used.add(index)
            pred_start, pred_end = predicted[index]
            result["boundary_errors"] += 1
            for name, gold_value, pred_value in (
                ("start", start, pred_start),
                ("end", end, pred_end),
            ):
                difference = pred_value - gold_value
                result[f"boundary_{name}_exact"] += int(difference == 0)
                result[f"boundary_{name}_early"] += int(difference < 0)
                result[f"boundary_{name}_late"] += int(difference > 0)
                result[f"boundary_{name}_diff_{size_bucket(abs(difference))}"] += 1
            prefix = prompt[pred_start:start]
            suffix = prompt[end:pred_end]
            if MARKER.match(prefix):
                result["boundary_marker_included"] += 1
            if any(character in punctuation for character in prefix + suffix):
                result["boundary_punctuation_included"] += 1
        unit = case["gold_unit"]
        for index, (start, end) in enumerate(predicted):
            if index in used:
                continue
            line = span_line_index(prompt, start)
            if inside_unit(unit, line):
                result["spurious_inside_gold_unit"] += 1
            else:
                result["spurious_negative_context"] += 1
            if case["predicted_question"] and span_inside_unit(
                prompt, (start, end), case["predicted_unit"]
            ):
                result["spurious_visible"] += 1
            else:
                result["spurious_hidden"] += 1
        if case["gold_unit"] != case["predicted_unit"]:
            result["unit_errors"] += 1
            gold_unit = case["gold_unit"]
            predicted_unit = case["predicted_unit"]
            if gold_unit is None:
                result["unit_spurious"] += 1
            elif predicted_unit is None:
                result["unit_missed"] += 1
            else:
                first, last = unit_indexes(case["ranges"], gold_unit)
                pred_first, pred_last = unit_indexes(case["ranges"], predicted_unit)
                if pred_first >= first and pred_last <= last:
                    result["unit_too_short"] += 1
                    result["unit_missing_paragraphs"] += (
                        pred_first - first + last - pred_last
                    )
                elif pred_first <= first and pred_last >= last:
                    result["unit_too_long"] += 1
                    result["unit_extra_paragraphs"] += (
                        first - pred_first + pred_last - last
                    )
                else:
                    result["unit_shifted"] += 1
        if case["gold_question"] and not case["predicted_question"]:
            result["missed_questions"] += 1
        if case["predicted_question"] and not case["gold_question"]:
            result["false_questions"] += 1
            if "?" in unit_text(prompt, case["predicted_unit"]):
                result["false_questions_with_question_mark"] += 1
            else:
                result["false_questions_without_question_mark"] += 1
    result["spurious"] = (
        result["spurious_inside_gold_unit"] + result["spurious_negative_context"]
    )
    return dict(result)


def metrics(cases: list[dict[str, object]]) -> dict[str, object]:
    parts: dict[str, list[dict[str, object]]] = defaultdict(list)
    for case in cases:
        parts[str(case["part"])].append(case)
    result = metrics_only(cases)
    result["parts"] = {name: metrics_only(values) for name, values in sorted(parts.items())}
    real = [case for case in cases if case["part"] in REAL_PARTS]
    if real:
        result["parts"]["real"] = metrics_only(real)
    result["errors"] = error_analysis(cases)
    result["errors_by_part"] = {
        name: error_analysis(values) for name, values in sorted(parts.items())
    }
    if real:
        result["errors_by_part"]["real"] = error_analysis(real)
    return result


def span_line_index(prompt: str, position: int) -> int | None:
    row = line_at(prompt, position)
    return int(row["index"]) - 1 if row is not None else None


def inside_unit(unit: tuple[int, int] | None, line: int | None) -> bool:
    return unit is not None and line is not None and unit[0] <= line <= unit[1]


def span_inside_unit(
    prompt: str, span: tuple[int, int], unit: tuple[int, int] | None
) -> bool:
    if unit is None:
        return False
    return inside_unit(unit, span_line_index(prompt, span[0])) and inside_unit(
        unit, span_line_index(prompt, max(span[0], span[1] - 1))
    )


def visible_options(
    case: dict[str, object],
) -> tuple[Counter, Counter]:
    prompt = str(case["prompt"])
    predicted = Counter()
    gold = Counter()
    if case["predicted_question"]:
        predicted.update(
            span
            for span in case["predicted_options"].elements()
            if span_inside_unit(prompt, span, case["predicted_unit"])
        )
    if case["gold_question"]:
        gold.update(
            span
            for span in case["gold_options"].elements()
            if span_inside_unit(prompt, span, case["gold_unit"])
        )
    return gold, predicted


def prf(tp: int, predicted: int, gold: int) -> dict[str, float]:
    precision = tp / predicted if predicted else 0.0
    recall = tp / gold if gold else 0.0
    return {
        "precision": precision,
        "recall": recall,
        "f1": 2 * precision * recall / (precision + recall) if precision + recall else 0.0,
    }


def metrics_only(cases: list[dict[str, object]]) -> dict[str, object]:
    token_counts: dict[str, dict[str, int]] = defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0})
    option_tp = option_pred = option_gold = 0
    visible_tp = visible_pred = visible_gold = 0
    unit_correct = unit_total = 0
    unit_positive_correct = unit_positive_total = 0
    unit_negative_correct = unit_negative_total = 0
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
        visible_gold_options, visible_predicted_options = visible_options(case)
        visible_tp += sum((visible_gold_options & visible_predicted_options).values())
        visible_pred += sum(visible_predicted_options.values())
        visible_gold += sum(visible_gold_options.values())
        unit_total += 1
        correct = case["gold_unit"] == case["predicted_unit"]
        unit_correct += correct
        if case["gold_question"]:
            unit_positive_total += 1
            unit_positive_correct += correct
        else:
            unit_negative_total += 1
            unit_negative_correct += correct
            negatives += 1
            false_positives += bool(case["predicted_question"])
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
        "option": prf(option_tp, option_pred, option_gold),
        "option_visible": {
            **prf(visible_tp, visible_pred, visible_gold),
            "tp": visible_tp,
            "predicted": visible_pred,
            "gold": visible_gold,
        },
        "unit_accuracy": unit_correct / unit_total if unit_total else 0.0,
        "unit_accuracy_positive": (
            unit_positive_correct / unit_positive_total if unit_positive_total else 0.0
        ),
        "unit_accuracy_negative": (
            unit_negative_correct / unit_negative_total if unit_negative_total else 0.0
        ),
        "unit_examples_positive": unit_positive_total,
        "unit_examples_negative": unit_negative_total,
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
    gold_unit = unit_from_classes(prompt, record["label"]["lines"], ranges, hovered)
    predicted_unit = unit_from_classes(
        prompt, line_classes(prompt, offsets, predicted_tags), ranges, hovered
    )
    return {
        "part": part_of(record),
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
        "ranges": ranges,
        "prompt": prompt,
    }


def eval_ettin(args: argparse.Namespace) -> dict[str, object]:
    bold, max_length, tokenizer = load_checkpoint(args.model)
    backend = Torch(args.model)
    backend.load()
    return evaluate(args.eval, backend.logits, bold, max_length, tokenizer)


def eval_coreml(args: argparse.Namespace) -> dict[str, object]:
    checkpoint = args.checkpoint or chosen_checkpoint()
    bold, max_length, tokenizer = load_checkpoint(checkpoint)
    backend = CoreML(args.model, args.compute, tokenizer.pad_token_id)
    return evaluate(args.eval, backend.logits, bold, max_length, tokenizer)


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
    parser.add_argument(
        "--backend", choices=["ettin", "createml", "coreml"], default="ettin"
    )
    parser.add_argument("--compute", choices=list(COMPUTE_UNITS), default="gpu")
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if args.backend == "ettin":
        result = eval_ettin(args)
    elif args.backend == "createml":
        result = eval_createml(args)
    else:
        result = eval_coreml(args)
    if args.output:
        output = args.output
    elif args.backend == "coreml":
        output = Path("data/eval-coreml.json")
    else:
        output = args.model / "eval.json"
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
