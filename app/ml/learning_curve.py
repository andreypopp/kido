"""Train Ettin and Create ML on nested session subsets of the training split."""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

from render import SEED, read_jsonl, write_jsonl
from runner import run


def subset(records: list[dict[str, object]], fraction: float) -> list[dict[str, object]]:
    sessions = sorted({str(record["session"]) for record in records})
    random.Random(SEED).shuffle(sessions)
    wanted = max(1, round(len(sessions) * fraction))
    keep = set(sessions[:wanted])
    return [record for record in records if str(record["session"]) in keep]


def main() -> int:
    sweep = json.loads(Path("data/sweep.json").read_text())
    best = sweep["best"]
    epochs = int(best["epochs"])
    learning_rate = float(best["learning_rate"])
    records = read_jsonl(Path("data/train.jsonl"))
    fractions = {25: 0.25, 50: 0.5, 100: 1.0}
    subsets = {}
    for name, fraction in fractions.items():
        values = subset(records, fraction)
        subsets[name] = values
        write_jsonl(Path(f"data/train-{name}.jsonl"), values)
    output: dict[str, object] = {
        "config": {"epochs": epochs, "learning_rate": learning_rate, "batch_size": 8},
        "sessions": {
            name: len({str(record["session"]) for record in values})
            for name, values in subsets.items()
        },
        "rows": [],
    }
    for name in fractions:
        for bold in (True, False):
            for seed in range(3):
                tag = f"curve-{name}-{'bold' if bold else 'nobold'}-s{seed}"
                directory = Path("data/output") / tag
                evaluation_path = directory / "eval.json"
                if not evaluation_path.exists():
                    command = [
                        sys.executable, "train.py", "--backend", "ettin",
                        "--train", f"data/train-{name}.jsonl",
                        "--epochs", str(epochs), "--learning-rate", str(learning_rate),
                        "--batch-size", "8", "--seed", str(seed), "--output", str(directory),
                    ]
                    if not bold:
                        command.append("--no-bold")
                    run(command)
                    run([
                        sys.executable, "eval.py", "--model", str(directory),
                        "--eval", "data/eval.jsonl", "--output", str(evaluation_path),
                    ])
                evaluation = json.loads(evaluation_path.read_text())
                output["rows"].append({
                    "fraction": name,
                    "bold": bold,
                    "seed": seed,
                    "question_f1": evaluation["token_f1"].get("question", {}).get("f1", 0.0),
                    "option_exact_f1": evaluation["option"]["f1"],
                    "unit_accuracy": evaluation["unit_accuracy"],
                })
                Path("data/learning-curve.json").write_text(json.dumps(output, indent=2) + "\n")
                print(json.dumps(output["rows"][-1], sort_keys=True))
    for name in fractions:
        for bold in (True, False):
            tag = f"curve-{name}-createml-{'bold' if bold else 'nobold'}"
            directory = Path("data/output") / tag
            evaluation_path = directory / "eval.json"
            if not evaluation_path.exists():
                command = [
                    sys.executable, "train.py", "--backend", "createml",
                    "--train", f"data/train-{name}.jsonl", "--eval", "data/eval.jsonl",
                    "--output", str(directory),
                ]
                if not bold:
                    command.append("--no-bold")
                run(command)
                run([
                    sys.executable, "eval.py", "--backend", "createml", "--model", str(directory),
                    "--eval", "data/eval.jsonl", "--output", str(evaluation_path),
                ])
            evaluation = json.loads(evaluation_path.read_text())
            output["rows"].append({
                "fraction": name,
                "bold": bold,
                "seed": 0,
                "question_f1": evaluation["token_f1"].get("question", {}).get("f1", 0.0),
                "option_exact_f1": evaluation["option"]["f1"],
                "unit_accuracy": evaluation["unit_accuracy"],
            })
            Path("data/learning-curve.json").write_text(json.dumps(output, indent=2) + "\n")
            print(json.dumps(output["rows"][-1], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
