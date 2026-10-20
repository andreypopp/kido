"""Small dev-only hyperparameter sweep for the Ettin tagger."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

CONFIGS = [(epochs, lr) for epochs in (10, 20) for lr in (1e-4, 2e-4)]


def run(command: list[str]) -> None:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(result.returncode)


def main() -> int:
    rows = []
    for bold in (True, False):
        for epochs, lr in CONFIGS:
            name = f"sweep-{'bold' if bold else 'nobold'}-e{epochs}-lr{lr:g}"
            output = Path("data/output") / name
            command = [
                sys.executable,
                "train.py",
                "--backend",
                "ettin",
                "--train",
                "data/dev-train.jsonl",
                "--eval",
                "data/dev.jsonl",
                "--epochs",
                str(epochs),
                "--learning-rate",
                str(lr),
                "--batch-size",
                "8",
                "--output",
                str(output),
            ]
            if not bold:
                command.append("--no-bold")
            run(command)
            run(
                [
                    sys.executable,
                    "eval.py",
                    "--model",
                    str(output),
                    "--eval",
                    "data/dev.jsonl",
                    "--output",
                    str(output / "eval.json"),
                ]
            )
            evaluation = json.loads((output / "eval.json").read_text())
            row = {
                "bold": bold,
                "epochs": epochs,
                "learning_rate": lr,
                "question_f1": evaluation["token_f1"].get("question", {}).get("f1", 0.0),
                "option_exact_f1": evaluation["option"]["f1"],
                "option_token_f1": evaluation["token_f1"].get("option", {}).get("f1", 0.0),
                "unit_accuracy": evaluation["unit_accuracy"],
            }
            rows.append(row)
            print(json.dumps(row, sort_keys=True))
    best = max(rows, key=lambda row: (row["option_exact_f1"], row["question_f1"]))
    Path("data/sweep.json").write_text(json.dumps({"rows": rows, "best": best}, indent=2) + "\n")
    print(json.dumps({"best": best}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
