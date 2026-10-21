"""Choose the B-Q probability threshold of a checkpoint on the real dev set and store it:
`threshold.py --model data/model`.

The rule: the largest score (mean of real-dev question F1 and option F1 end to end) among the
thresholds with a combined real-dev false-positive rate of at most 2%; if its question F1 is
more than 0.05 under that of t=0.5, the largest score among those with at most 5%.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from evaluate import dev_score, score_backend
from extract import load
from jsonl import read_jsonl, write_json
from model import save_threshold
from paths import REPORTS, output_path

GRID = (None, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95)
STRICT, LOOSE, LOSS = 0.02, 0.05, 0.05
PARTS = ("dev-real", "dev-real-no-question-mark", "dev-real-with-question-mark")


def choose(curve: list[dict]) -> dict | None:
    """The row for the rule above, or None if no threshold meets the loose limit."""
    rows = [row for row in curve if row["threshold"] is not None]
    reference = next(row for row in rows if row["threshold"] == 0.5)
    for limit in (STRICT, LOOSE):
        eligible = [row for row in rows if row["fpr"] <= limit]
        if not eligible:
            continue
        best = max(eligible, key=lambda row: (row["score"], -row["threshold"]))
        if limit == LOOSE or reference["question_f1"] - best["question_f1"] <= LOSS:
            return best
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=REPORTS / "threshold.json")
    args = parser.parse_args(argv)
    records = read_jsonl(output_path("dev"))
    tokenizer, backend = load(args.model)
    curve = []
    for threshold in GRID:
        backend.threshold = threshold
        scores = score_backend(records, tokenizer, backend)
        real = scores["dev-real"]
        curve.append(
            {
                "threshold": threshold,
                "question_f1": real["question_f1"],
                "option_f1_end_to_end": real["option_f1_end_to_end"],
                "score": dev_score(scores)["score"],
                "fpr": real["false_positive_rate"],
                "fpr_no_question_mark": scores["dev-real-no-question-mark"]["false_positive_rate"],
                "fpr_with_question_mark": scores["dev-real-with-question-mark"][
                    "false_positive_rate"
                ],
                "negatives": {p: scores[p]["negative_texts"] for p in PARTS},
            }
        )
        print(curve[-1], flush=True)
    chosen = choose(curve)
    write_json(args.output, {"curve": curve, "chosen": chosen})
    if chosen is not None:
        save_threshold(args.model, chosen["threshold"])
    print("chosen", chosen)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
