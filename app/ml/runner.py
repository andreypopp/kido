"""Run one training or evaluation command with explicit flags."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def run(command: list[str]) -> None:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(result.returncode)


def train_run(
    *,
    name: str,
    train: Path,
    output: Path,
    base_model: str,
    epochs: int,
    learning_rate: float,
    batch_size: int,
    max_length: int,
    warmup_fraction: float,
    seed: int,
    bold: bool,
) -> None:
    if (output / "training.json").exists():
        return
    command = [
        sys.executable,
        "train.py",
        "--backend",
        "ettin",
        "--base-model",
        base_model,
        "--train",
        str(train),
        "--epochs",
        str(epochs),
        "--learning-rate",
        str(learning_rate),
        "--batch-size",
        str(batch_size),
        "--max-length",
        str(max_length),
        "--warmup-fraction",
        str(warmup_fraction),
        "--seed",
        str(seed),
        "--output",
        str(output),
    ]
    if not bold:
        command.append("--no-bold")
    run(command)


def eval_run(*, eval: Path, output: Path) -> None:
    run(
        [
            sys.executable,
            "eval.py",
            "--model",
            str(output),
            "--eval",
            str(eval),
            "--output",
            str(output / "eval.json"),
        ]
    )


def train_and_eval(*, train: Path, eval: Path, output: Path, **kwargs: object) -> None:
    train_run(train=train, output=output, **kwargs)
    eval_run(eval=eval, output=output)
