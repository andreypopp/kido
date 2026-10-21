"""Score models on the dev or the eval set, through the code path of the extract command.

Gold labels become ranges with their options in text order and the predictions come from
extract.predict; the comparison is on character ranges. Every part is also scored without the
`open` questions: each gold open question and each prediction that overlaps one are removed.
"""

from __future__ import annotations

import argparse
import json
import statistics
from collections.abc import Callable
from pathlib import Path

from chunks import OPTION_LENGTH, O
from corpus import is_multi_candidate
from examples import option_example, option_spans
from extract import load, options, predict
from flat import Flat, flatten
from jsonl import file_digest, read_json, read_jsonl, write_json
from metrics import Counts, Found, add_text, overlap, summary
from model import WEIGHTS, load_tokenizer
from paths import output_path
from provenance import code_state, input_hashes
from questions import OPEN, ordered_options, questions_of
from segments import segments
from split import is_synthetic

Record = dict[str, object]
Predict = Callable[[Record], list[Found]]
OptionsIn = Callable[[Record, Flat, int, int], tuple[str, ...]]
FPR_LIMIT = 0.02


def part_names(record: Record) -> list[str]:
    if record["split"] == "dev":
        if is_synthetic(record):
            return ["dev", "dev-synthetic"]
        names = ["dev", "dev-real"]
        if not record["label"]["questions"]:  # type: ignore[index]
            names += ["dev-real-with-question-mark"] * bool(record["question_segments"])
            names += ["dev-real-no-question-mark"] * (not record["question_segments"])
        return names
    if is_synthetic(record):
        names = ["synthetic"] + ([] if record["shared_template"] else ["synthetic-unshared"])
        return names + ["synthetic-no-inline"] * ("inline" not in record["forms"])
    names = [str(record["part"])]
    if record["part"] in ("eval-real", "eval-negative") and not record["label"]["questions"]:  # type: ignore[index]
        names += ["eval-negatives"]
        names += ["eval-negatives-with-question-mark"] * bool(record["question_segments"])
        names += ["eval-negatives-no-question-mark"] * (not record["question_segments"])
    if record["part"] == "eval-real":
        names += ["eval-real-multi"] * is_multi_candidate(record)
        names += ["eval-real-unanimous"] * (record["agree"] == 3)
    return names


def gold_of(record: Record) -> list[tuple[Found, str]]:
    text = str(record["text"])
    questions = questions_of(text, ordered_options(text, record["label"]))  # type: ignore[arg-type]
    return [((q.start, q.end, q.options), q.kind) for q in questions]


def without_open(
    gold: list[tuple[Found, str]], predicted: list[Found], in_gold: list[tuple[str, ...]] | None
) -> tuple[list[Found], list[Found], list[tuple[str, ...]] | None]:
    dropped = [found for found, kind in gold if kind == OPEN]
    keep = [n for n, (_, kind) in enumerate(gold) if kind != OPEN]
    return (
        [gold[n][0] for n in keep],
        [p for p in predicted if not any(overlap(p, d) for d in dropped)],
        [in_gold[n] for n in keep] if in_gold is not None else None,
    )


def score(
    records: list[Record], predict_record: Predict, options_in: OptionsIn | None
) -> dict[str, dict[str, object]]:
    counts: dict[str, Counts] = {}
    for record in records:
        gold = gold_of(record)
        flat = flatten(str(record["text"]))
        in_gold = [options_in(record, flat, g[0], g[1]) for (g, _) in gold] if options_in else None
        predicted = predict_record(record)
        cuts = segments(str(record["text"]))
        views = {"": ([g for g, _ in gold], predicted, in_gold)}
        views["/no-open"] = without_open(gold, predicted, in_gold)
        for name in part_names(record):
            for suffix, (g, p, i) in views.items():
                add_text(counts.setdefault(name + suffix, Counts()), g, p, cuts, i)
    return {key: summary(value) for key, value in sorted(counts.items())}


def percentiles(sizes: list[int]) -> dict[str, int]:
    ordered = sorted(sizes)
    pick = lambda share: ordered[min(len(ordered) - 1, int(len(ordered) * share))]  # noqa: E731
    return {
        "questions": len(ordered),
        "p50": pick(0.5),
        "p90": pick(0.9),
        "p99": pick(0.99),
        "max": ordered[-1],
        "over_option_length": sum(size > OPTION_LENGTH for size in ordered),
    }


class Replay:
    def __init__(self, labels: list[int]) -> None:
        self.labels = labels

    def tags(self, task: str, ids: list[int]) -> list[int]:
        return [max(label, O) for label in self.labels]


def oracle(tokenizer, records: list[Record]) -> dict[str, dict[str, object]]:
    """The option pass fed the gold tags: what token boundaries alone cost."""

    def options_in(record: Record, flat: Flat, start: int, end: int) -> tuple[str, ...]:
        text = str(record["text"])
        question = next(q for q in questions_of(text, record["label"]) if q.start == start)  # type: ignore[arg-type]
        example = option_example(
            tokenizer, flat, start, end, option_spans(text, question, start, end)
        )
        return options(tokenizer, Replay(example["labels"]), text, flat, start, end)

    result = score(records, lambda record: [g for g, _ in gold_of(record)], options_in)
    return {part: {"option_f1_in_gold": s["option_f1_in_gold"]} for part, s in result.items()}


def score_backend(
    records: list[Record], tokenizer, backend, predict_text=predict
) -> dict[str, dict[str, object]]:
    """Score a backend; predict_text(tokenizer, backend, text) gives the predictions."""
    return score(
        records,
        lambda record: predict_text(tokenizer, backend, str(record["text"])),
        lambda record, flat, start, end: options(
            tokenizer, backend, str(record["text"]), flat, start, end
        ),
    )


def score_model(path: Path, records: list[Record]) -> dict[str, object]:
    tokenizer, backend = load(path)
    predicted_sizes: list[int] = []

    def size(text: str, found: Found) -> int:
        return len(tokenizer(text[found[0] : found[1]])["input_ids"])

    def sized_predict(tokenizer, backend, text: str) -> list[Found]:
        found = predict(tokenizer, backend, text)
        predicted_sizes.extend(size(text, f) for f in found)
        return found

    scores = score_backend(records, tokenizer, backend, sized_predict)
    gold_sizes = [size(str(r["text"]), g) for r in records for g, _ in gold_of(r)]
    return {
        "train": read_json(path / "train.json"),
        "crf": backend.crf is not None,
        "question_threshold": None if backend.crf is not None else backend.threshold,
        "weights": {str(p.relative_to(path)): file_digest(p) for p in sorted(path.rglob(WEIGHTS))},
        "scores": scores,
        "question_tokens": {
            "gold": percentiles(gold_sizes),
            "predicted": percentiles(predicted_sizes) if predicted_sizes else None,
        },
    }


def dev_score(scores: dict[str, dict[str, object]]) -> dict[str, object]:
    """The selection score: the mean of question F1 and option F1 end to end on the real dev."""
    real, synthetic = scores["dev-real"], scores["dev-synthetic"]
    return {
        "fpr": real["false_positive_rate"],
        "score": round((real["question_f1"] + real["option_f1_end_to_end"]) / 2, 4),  # type: ignore[operator]
        "synthetic_score": round(
            (synthetic["question_f1"] + synthetic["option_f1_end_to_end"]) / 2,
            4,  # type: ignore[operator]
        ),
    }


def aggregate(runs: list[object]) -> object:
    """Mean and SD of each number over runs that have the same shape."""
    first = runs[0]
    if isinstance(first, dict):
        return {key: aggregate([run[key] for run in runs]) for key in first}  # type: ignore[index]
    if first is None:
        return None
    values = [float(run) for run in runs]  # type: ignore[arg-type]
    sd = statistics.stdev(values) if len(values) > 1 else 0.0
    return {"mean": round(statistics.mean(values), 4), "sd": round(sd, 4)}


def same_but_seed(models: list[dict[str, object]]) -> bool:
    settings = [{**m["train"]["settings"], "seed": 0, "output": ""} for m in models]  # type: ignore[index]
    seeds = {m["train"]["settings"]["seed"] for m in models}  # type: ignore[index]
    return all(s == settings[0] for s in settings) and len(seeds) == len(models)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split", choices=["dev", "eval"], required=True)
    parser.add_argument("--model", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, help="the first N records, for a smoke run")
    args = parser.parse_args(argv)
    records = read_jsonl(output_path(args.split))[: args.limit]
    models = {str(path): score_model(path, records) for path in args.model}
    report: dict[str, object] = {
        "split": args.split,
        "limit": args.limit,
        "inputs": input_hashes(**{args.split: output_path(args.split)}),
        "code": code_state(),
        "models": models,
        "option_oracle": oracle(load_tokenizer(args.model[0]), records),
    }
    if len(models) > 1 and same_but_seed(list(models.values())):
        report["mean_sd"] = aggregate([m["scores"] for m in models.values()])
    if args.split == "dev":
        selection = {k: dev_score(m["scores"]) for k, m in models.items()}  # type: ignore[index]
        report["selection"] = selection
        if "mean_sd" in report:
            mean = aggregate(list(selection.values()))
            report["selection_mean"] = mean | {"eligible": mean["fpr"]["mean"] < FPR_LIMIT}  # type: ignore[index,operator]
    write_json(args.output, report)
    print(json.dumps({"models": len(models), "texts": len(records)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
