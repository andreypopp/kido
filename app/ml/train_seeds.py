"""Train, evaluate or collect the seed runs of the chosen configuration."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from runner import eval_run, train_run


def parse_seeds(text: str) -> list[int]:
    return [int(value) for value in text.split(",") if value.strip()]


def experiment(path: Path) -> dict[str, object]:
    return json.loads(path.read_text())


def run_list(
    exp: dict[str, object], nobold: list[int], bold: list[int]
) -> list[dict[str, object]]:
    runs = []
    for variant, seeds in (("nobold", nobold), ("bold", bold)):
        for seed in seeds:
            name = f"phase2-{variant}-s{seed}"
            output = Path("data/output") / name
            runs.append(
                {
                    "name": name,
                    "bold": variant == "bold",
                    "seed": seed,
                    "output": str(output),
                    "eval": str(output / "eval.json"),
                }
            )
    return runs


def config(
    exp: dict[str, object], nobold: list[int], bold: list[int]
) -> dict[str, object]:
    sweep = exp["sweep"]
    training = exp["training"]
    return {
        "base_model": exp["base_model"],
        "epochs": sweep["epochs"],
        "learning_rate": sweep["learning_rate"],
        "batch_size": training["batch_size"],
        "max_length": training["max_length"],
        "warmup_fraction": training["warmup_fraction"],
        "seeds": {"nobold": nobold, "bold": bold},
    }


def chosen_name(exp: dict[str, object]) -> str:
    chosen = exp["chosen"]
    return f"phase2-{chosen['variant']}-s{chosen['seed']}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["train", "eval", "collect"], required=True)
    parser.add_argument("--experiment", type=Path, default=Path("data/experiment.json"))
    parser.add_argument("--nobold-seeds", default="0,1,2")
    parser.add_argument("--bold-seeds", default="0")
    parser.add_argument("--train", type=Path, default=Path("data/train.jsonl"))
    parser.add_argument("--eval-data", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--output", type=Path, default=Path("data/train-seeds.json"))
    args = parser.parse_args(argv)
    exp = experiment(args.experiment)
    nobold = parse_seeds(args.nobold_seeds)
    bold = parse_seeds(args.bold_seeds)
    runs = run_list(exp, nobold, bold)
    if args.stage == "train":
        settings = config(exp, nobold, bold)
        for run in runs:
            train_run(
                name=str(run["name"]),
                train=args.train,
                output=Path(str(run["output"])),
                base_model=str(settings["base_model"]),
                epochs=int(settings["epochs"]),
                learning_rate=float(settings["learning_rate"]),
                batch_size=int(settings["batch_size"]),
                max_length=int(settings["max_length"]),
                warmup_fraction=float(settings["warmup_fraction"]),
                seed=int(run["seed"]),
                bold=bool(run["bold"]),
            )
    elif args.stage == "eval":
        for run in runs:
            eval_run(eval=args.eval_data, output=Path(str(run["output"])))
    else:
        existing = [
            run for run in runs if (Path(str(run["output"])) / "training.json").exists()
        ]
        args.output.write_text(
            json.dumps(
                {
                    "config": config(exp, nobold, bold),
                    "chosen": chosen_name(exp),
                    "decisions": exp["decisions"],
                    "runs": existing,
                },
                indent=2,
            )
            + "\n"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
