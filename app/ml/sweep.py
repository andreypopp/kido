"""Dev-only hyperparameter sweep: train, evaluate or collect the results."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from aggregate import values
from runner import eval_run, train_run
from runtime import MODEL

EPOCHS = (3, 6, 10)
LEARNING_RATES = (5e-5, 1e-4, 2e-4)


def configs() -> list[dict[str, object]]:
    return [
        {
            "name": f"sweep-e{epochs}-lr{learning_rate:g}",
            "epochs": epochs,
            "learning_rate": learning_rate,
        }
        for epochs in EPOCHS
        for learning_rate in LEARNING_RATES
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--train", action="store_true")
    parser.add_argument("--eval", action="store_true")
    parser.add_argument("--collect", action="store_true")
    args = parser.parse_args(argv)
    if args.train:
        for config in configs():
            train_run(
                name=str(config["name"]),
                train=Path("data/dev-train.jsonl"),
                output=Path("data/output") / str(config["name"]),
                base_model=MODEL,
                epochs=int(config["epochs"]),
                learning_rate=float(config["learning_rate"]),
                batch_size=16,
                max_length=1024,
                warmup_fraction=0.1,
                seed=0,
                bold=False,
            )
    if args.eval:
        for config in configs():
            eval_run(
                eval=Path("data/dev.jsonl"),
                output=Path("data/output") / str(config["name"]),
            )
    if args.collect:
        rows = []
        for config in configs():
            output = Path("data/output") / str(config["name"])
            evaluation = json.loads((output / "eval.json").read_text())
            real = values(evaluation["parts"]["real"])
            synthetic = values(evaluation["parts"]["synthetic"])
            row = {
                "epochs": config["epochs"],
                "learning_rate": config["learning_rate"],
                "real": {
                    "option_f1": real["option_f1"],
                    "question_f1": real["question_f1"],
                    "question_fpr": real["question_fpr"],
                    "unit_accuracy": real["unit_accuracy"],
                },
                "synthetic": {
                    "option_f1": synthetic["option_f1"],
                    "question_f1": synthetic["question_f1"],
                    "question_fpr": synthetic["question_fpr"],
                    "unit_accuracy": synthetic["unit_accuracy"],
                },
            }
            rows.append(row)
            print(json.dumps(row, sort_keys=True))
        best = max(
            rows,
            key=lambda row: (
                row["real"]["option_f1"],
                row["real"]["question_f1"],
                -row["real"]["question_fpr"],
            ),
        )
        Path("data/sweep.json").write_text(
            json.dumps({"rows": rows, "best": best}, indent=2) + "\n"
        )
        print(json.dumps({"best": best}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
