"""Summarise seed runs as mean and standard deviation per eval part."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

PARTS = ("ask", "real", "synthetic")


def values(evaluation: dict[str, object]) -> dict[str, float]:
    return {
        "question_f1": evaluation["token_f1"]["question"]["f1"],
        "option_token_f1": evaluation["token_f1"]["option"]["f1"],
        "option_precision": evaluation["option"]["precision"],
        "option_recall": evaluation["option"]["recall"],
        "option_f1": evaluation["option"]["f1"],
        "option_visible_f1": evaluation["option_visible"]["f1"],
        "option_visible_precision": evaluation["option_visible"]["precision"],
        "option_visible_recall": evaluation["option_visible"]["recall"],
        "unit_accuracy": evaluation["unit_accuracy"],
        "unit_accuracy_positive": evaluation["unit_accuracy_positive"],
        "unit_accuracy_negative": evaluation["unit_accuracy_negative"],
        "unit_examples_positive": evaluation["unit_examples_positive"],
        "unit_examples_negative": evaluation["unit_examples_negative"],
        "question_fpr": evaluation["question_false_positive_rate"],
        "negatives": evaluation["negatives"],
    }


def summarize(runs: list[dict[str, object]]) -> dict[str, object]:
    samples: dict[str, list[dict[str, float]]] = {part: [] for part in PARTS + ("union",)}
    for run in runs:
        evaluation = json.loads(Path(str(run["eval"])).read_text())
        for part in PARTS:
            samples[part].append(values(evaluation["parts"][part]))
        samples["union"].append(values(evaluation))
    metrics = {}
    for part, part_samples in samples.items():
        metrics[part] = {
            name: {
                "mean": statistics.mean(sample[name] for sample in part_samples),
                "sd": statistics.stdev(sample[name] for sample in part_samples)
                if len(part_samples) > 1
                else 0.0,
            }
            for name in part_samples[0]
        }
    return {"count": len(runs), "parts": metrics}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("data/train-seeds.json"))
    parser.add_argument("--output", type=Path, default=Path("data/eval-summary.json"))
    args = parser.parse_args(argv)
    data = json.loads(args.input.read_text())
    groups = {}
    for bold in (False, True):
        runs = [run for run in data["runs"] if bool(run["bold"]) == bold]
        if runs:
            groups["bold" if bold else "nobold"] = summarize(runs)
    ask_errors = {}
    for run in data["runs"]:
        evaluation = json.loads(Path(str(run["eval"])).read_text())
        ask_errors[str(run["name"])] = evaluation["errors_by_part"]["ask"]
    result = {
        "config": data["config"],
        "chosen": data["chosen"],
        "decisions": data["decisions"],
        "groups": groups,
        "ask_errors": ask_errors,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({name: group["count"] for name, group in groups.items()}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
