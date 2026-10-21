"""Scores of the taggers on labelled units: question and option F1, exact match, false positives."""

from label import gold_of
from tagging import MAX_TOKENS, OPTION_TRAILING, Span, project, token_count

Unit = list[tuple[Span, tuple[Span, ...]]]  # (question span, option spans in the question)


def project_gold(
    tokenizer, text: str, gold: Unit
) -> list[tuple[Span, Span, tuple[Span, ...]] | None]:
    """For each gold question: its span in the text, its projected span and its projected options,
    or None when the tokens cut it off."""
    out = []
    for span, options in gold:
        question = project(tokenizer, text, [span])
        kept = tuple(project(tokenizer, text[span[0] : span[1]], list(options), OPTION_TRAILING))
        out.append((span, question[0], kept) if question else None)
    return out


def changed(gold: Unit, held: list) -> int:
    """How many gold questions and options the tokens change or lose."""
    count = 0
    for (span, options), item in zip(gold, held, strict=True):
        count += (
            1 + len(options)
            if item is None
            else (item[1] != span) + len(set(options) - set(item[2]))
        )
    return count


def f1(found: set, wanted: set) -> float:
    hit = len(found & wanted)
    return 2 * hit / (len(found) + len(wanted)) if found or wanted else 1.0


def questions_of(units: list[Unit]) -> set:
    return {(n, q) for n, unit in enumerate(units) for q, _ in unit}


def options_of(units: list[Unit]) -> set:
    return {(n, q, o) for n, unit in enumerate(units) for q, options in unit for o in options}


def overlap_hits(found: list[Span], wanted: list[Span]) -> int:
    """How many found spans overlap a wanted span that no other found span matched."""
    used: set[int] = set()
    for a, b in sorted(found):
        for j, (c, d) in enumerate(sorted(wanted)):
            if j not in used and a < d and c < b:
                used.add(j)
                break
    return len(used)


def overlap_f1(pred: list[Unit], gold: list[Unit]) -> float:
    hits = sum(
        overlap_hits([q for q, _ in p], [q for q, _ in g]) for p, g in zip(pred, gold, strict=True)
    )
    total = sum(map(len, pred)) + sum(map(len, gold))
    return 2 * hits / total if total else 1.0


def ceiling(originals: list[Unit], held: list) -> dict[str, float]:
    """F1 of the gold as the tokens hold it against the gold itself, for questions and options:
    the best that a perfect tagger can score on exact spans."""
    wanted_q = {(n, q) for n, unit in enumerate(originals) for q, _ in unit}
    wanted_o = {
        (n, q, o) for n, unit in enumerate(originals) for q, options in unit for o in options
    }
    got_q, got_o = set(), set()
    for n, (unit, items) in enumerate(zip(originals, held, strict=True)):
        for (q, _), item in zip(unit, items, strict=True):
            if item:
                got_q.add((n, q) if item[1] == q else (n, item[1]))
                got_o |= {(n, q, o) for o in item[2]}
    return {
        "ceiling_question_f1": f1(got_q, wanted_q),
        "ceiling_option_f1": f1(got_o, wanted_o),
    }


def part(gold: list[Unit], pred: list[Unit], inner: list[Unit]) -> dict[str, float]:
    return {
        "units": len(gold),
        "question_f1": f1(questions_of(pred), questions_of(gold)),
        "question_f1_overlap": overlap_f1(pred, gold),
        "option_f1": f1(options_of(pred), options_of(gold)),
        "option_f1_in_gold": f1(options_of(inner), options_of(gold)),
        "exact": sum(p == g for p, g in zip(pred, gold, strict=True)) / max(1, len(gold)),
    }


def rate(flags: list[bool]) -> float:
    return sum(flags) / len(flags) if flags else 0.0


def evaluate(tokenizer, taggers: dict, records: list[dict]) -> dict[str, dict]:
    """Scores of all units, of the units with 2 or more questions and of those with a choice,
    against the gold as the tokens hold it. The "all" part also has the false positive rates,
    the number of gold spans that the tokens change and the units over the token limit."""
    texts = [r["text"] for r in records]
    originals = [gold_of(r) for r in records]
    held = [project_gold(tokenizer, t, g) for t, g in zip(texts, originals, strict=True)]
    gold = [[(q, options) for _, q, options in filter(None, unit)] for unit in held]
    spans = taggers["question"](texts)
    asked = [t[a:b] for t, found in zip(texts, spans, strict=True) for a, b in found]
    options = iter(taggers["option"](asked, OPTION_TRAILING))
    pred = [[((a, b), tuple(next(options))) for a, b in found] for found in spans]
    gold_questions = [
        t[a:b] for t, unit in zip(texts, held, strict=True) for (a, b), _, _ in filter(None, unit)
    ]
    options = iter(taggers["option"](gold_questions, OPTION_TRAILING))
    inner = [[(q, tuple(next(options))) for q, _ in unit] for unit in gold]
    parts = {
        "all": lambda g: True,
        "multi": lambda g: len(g) >= 2,
        "choice": lambda g: any(options for _, options in g),
    }
    out = {}
    for name, keep in parts.items():
        chosen = [i for i, g in enumerate(gold) if keep(g)]
        out[name] = part(*([x[i] for i in chosen] for x in (gold, pred, inner)))
    empty = [(t, bool(p)) for t, g, p in zip(texts, originals, pred, strict=True) if not g]
    out["all"] |= {
        "fpr": rate([found for _, found in empty]),
        "fpr_question_mark": rate([found for t, found in empty if "?" in t]),
        "fpr_plain": rate([found for t, found in empty if "?" not in t]),
        **ceiling(originals, held),
        "gold_changed_by_tokens": sum(map(changed, originals, held)),
        "over_max_tokens": sum(token_count(tokenizer, t) > MAX_TOKENS for t in texts),
    }
    return out
