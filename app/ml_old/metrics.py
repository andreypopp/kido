"""Scores for predicted questions against gold questions, on character ranges."""

from __future__ import annotations

import bisect
from dataclasses import dataclass, field

from segments import BLANK, Segment

Found = tuple[int, int, tuple[str, ...]]  # start, end, options
ERRORS = (
    "merge",
    "split",
    "boundary",
    "missed_option",
    "spurious_option",
    "false_question",
    "missed_question",
)


@dataclass
class Counts:
    texts: int = 0
    exact_texts: int = 0
    count_exact: int = 0
    gold: int = 0
    predicted: int = 0
    matched: int = 0
    overlap_not_exact: int = 0
    unmatched_options: int = 0
    lenient_matched: int = 0
    option_gold: int = 0
    option_predicted: int = 0
    option_matched: int = 0
    gold_option_texts: int = 0
    gold_option_gold: int = 0
    gold_option_predicted: int = 0
    gold_option_matched: int = 0
    negative_texts: int = 0
    false_positive_texts: int = 0
    errors: dict[str, int] = field(default_factory=lambda: dict.fromkeys(ERRORS, 0))


def f1(matched: int, predicted: int, gold: int) -> float:
    if predicted == 0 and gold == 0:
        return 1.0
    precision = matched / predicted if predicted else 0.0
    recall = matched / gold if gold else 0.0
    return 2 * precision * recall / (precision + recall) if precision + recall else 0.0


def overlap(a: Found, b: Found) -> bool:
    return a[0] < b[1] and b[0] < a[1]


def shared(wanted: tuple[str, ...], got: tuple[str, ...]) -> int:
    remaining = list(wanted)
    count = 0
    for option in got:
        if option in remaining:
            remaining.remove(option)
            count += 1
    return count


def lenient_pairs(gold: list[Found], predicted: list[Found], cuts: list[Segment]) -> int:
    """Gold questions that a predicted question matches within one segment at each end."""
    real = [cut for cut in cuts if cut.kind != BLANK]
    starts, ends = [c.start for c in real], [c.end for c in real]
    unused = [(bisect.bisect_left(starts, p[0]), bisect.bisect_left(ends, p[1])) for p in predicted]
    count = 0
    for g in gold:
        first, last = bisect.bisect_left(starts, g[0]), bisect.bisect_left(ends, g[1])
        for pair in unused:
            if abs(pair[0] - first) <= 1 and abs(pair[1] - last) <= 1:
                unused.remove(pair)
                count += 1
                break
    return count


def add_text(
    counts: Counts,
    gold: list[Found],
    predicted: list[Found],
    cuts: list[Segment],
    in_gold: list[tuple[str, ...]] | None = None,
) -> None:
    """Add one text. in_gold, if given, is the option pass alone on each gold question."""
    counts.texts += 1
    counts.exact_texts += gold == predicted
    counts.count_exact += len(gold) == len(predicted)
    counts.gold += len(gold)
    counts.predicted += len(predicted)
    counts.lenient_matched += lenient_pairs(gold, predicted, cuts)
    by_range = {(g[0], g[1]): g for g in gold}
    counts.option_gold += sum(len(g[2]) for g in gold)
    for found in predicted:
        counts.option_predicted += len(found[2])
        match = by_range.get((found[0], found[1]))
        if match is not None:
            counts.matched += 1
            hit = shared(match[2], found[2])
            counts.option_matched += hit
            counts.errors["missed_option"] += len(match[2]) - hit
            counts.errors["spurious_option"] += len(found[2]) - hit
    if in_gold is not None:
        counts.gold_option_texts += 1
        for g, got in zip(gold, in_gold, strict=True):
            counts.gold_option_gold += len(g[2])
            counts.gold_option_predicted += len(got)
            counts.gold_option_matched += shared(g[2], got)
    for found in predicted:
        inside = [g for g in gold if found[0] <= g[0] and g[1] <= found[1]]
        counts.errors["merge"] += len(inside) >= 2
        counts.errors["false_question"] += not any(overlap(found, g) for g in gold)
    exact = {(f[0], f[1]) for f in predicted}
    for g in gold:
        inside = [f for f in predicted if g[0] <= f[0] and f[1] <= g[1]]
        counts.errors["split"] += len(inside) >= 2
        touching = [f for f in predicted if overlap(f, g)]
        counts.errors["missed_question"] += not touching
        if (g[0], g[1]) not in exact:
            counts.unmatched_options += len(g[2])
            counts.overlap_not_exact += bool(touching)
        if len(touching) == 1 and (touching[0][0], touching[0][1]) != (g[0], g[1]):
            counts.errors["boundary"] += sum(overlap(touching[0], h) for h in gold) == 1
    if not gold:
        counts.negative_texts += 1
        counts.false_positive_texts += bool(predicted)


def summary(counts: Counts) -> dict[str, object]:
    return {
        "texts": counts.texts,
        "gold_questions": counts.gold,
        "predicted_questions": counts.predicted,
        "question_f1": round(f1(counts.matched, counts.predicted, counts.gold), 4),
        "question_f1_lenient": round(f1(counts.lenient_matched, counts.predicted, counts.gold), 4),
        "count_exact": round(counts.count_exact / max(1, counts.texts), 4),
        "option_f1_in_gold": round(
            f1(counts.gold_option_matched, counts.gold_option_predicted, counts.gold_option_gold), 4
        )
        if counts.gold_option_texts
        else None,
        "option_f1_end_to_end": round(
            f1(counts.option_matched, counts.option_predicted, counts.option_gold), 4
        ),
        "whole_output_exact": round(counts.exact_texts / max(1, counts.texts), 4),
        "false_positive_rate": round(counts.false_positive_texts / counts.negative_texts, 4)
        if counts.negative_texts
        else None,
        "negative_texts": counts.negative_texts,
        "errors": dict(counts.errors),
        "accounting": {
            "gold_questions": counts.gold,
            "exact": counts.matched,
            "overlap_not_exact": counts.overlap_not_exact,
            "absent": counts.errors["missed_question"],
            "gold_options": counts.option_gold,
            "options_matched": counts.option_matched,
            "options_missed_in_exact_questions": counts.errors["missed_option"],
            "options_in_unmatched_questions": counts.unmatched_options,
        },
    }
