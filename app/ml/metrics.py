"""Scores for predicted questions against gold questions, on character ranges."""

from __future__ import annotations

from dataclasses import dataclass

Found = tuple[int, int, tuple[str, ...]]  # start, end, options


@dataclass
class Counts:
    texts: int = 0
    exact_texts: int = 0
    count_exact: int = 0
    gold: int = 0
    predicted: int = 0
    matched: int = 0
    merges: int = 0
    splits: int = 0
    option_gold: int = 0
    option_predicted: int = 0
    option_matched: int = 0
    negative_texts: int = 0
    false_positive_texts: int = 0


def f1(matched: int, predicted: int, gold: int) -> float:
    if predicted == 0 and gold == 0:
        return 1.0
    precision = matched / predicted if predicted else 0.0
    recall = matched / gold if gold else 0.0
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def lenient_match(a: Found, b: Found, slack: int) -> bool:
    return abs(a[0] - b[0]) <= slack and abs(a[1] - b[1]) <= slack


def add_text(counts: Counts, gold: list[Found], predicted: list[Found]) -> None:
    counts.texts += 1
    counts.exact_texts += gold == predicted
    counts.count_exact += len(gold) == len(predicted)
    counts.gold += len(gold)
    counts.predicted += len(predicted)
    by_range = {(g[0], g[1]): g for g in gold}
    for found in predicted:
        match = by_range.get((found[0], found[1]))
        if match is None:
            counts.option_predicted += len(found[2])
            continue
        counts.matched += 1
        counts.option_gold += len(match[2])
        counts.option_predicted += len(found[2])
        remaining = list(match[2])
        for option in found[2]:
            if option in remaining:
                remaining.remove(option)
                counts.option_matched += 1
    matched_ranges = {(f[0], f[1]) for f in predicted}
    counts.option_gold += sum(len(g[2]) for g in gold if (g[0], g[1]) not in matched_ranges)
    for found in predicted:
        inside = [g for g in gold if found[0] <= g[0] and g[1] <= found[1]]
        counts.merges += len(inside) >= 2
    for g in gold:
        inside = [f for f in predicted if g[0] <= f[0] and f[1] <= g[1]]
        counts.splits += len(inside) >= 2
    if not gold:
        counts.negative_texts += 1
        counts.false_positive_texts += bool(predicted)


def summary(counts: Counts) -> dict[str, float | int]:
    return {
        "texts": counts.texts,
        "gold_questions": counts.gold,
        "predicted_questions": counts.predicted,
        "question_f1": round(f1(counts.matched, counts.predicted, counts.gold), 4),
        "count_exact": round(counts.count_exact / max(1, counts.texts), 4),
        "merges": counts.merges,
        "splits": counts.splits,
        "option_f1_end_to_end": round(
            f1(counts.option_matched, counts.option_predicted, counts.option_gold), 4
        ),
        "whole_output_exact": round(counts.exact_texts / max(1, counts.texts), 4),
        "false_positive_rate": round(
            counts.false_positive_texts / max(1, counts.negative_texts), 4
        ),
        "negative_texts": counts.negative_texts,
    }
