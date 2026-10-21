"""Training examples of the two passes from labelled texts."""

from __future__ import annotations

import random
from dataclasses import dataclass

from chunks import IGNORE, B, Encoded, I, O, encode, option_input
from questions import Question, option_ranges, questions_of
from segments import BLANK, Segment

PERTURBED_SHARE = 0.2


@dataclass
class Item:
    text: str
    enc: Encoded
    questions: list[Question]
    options: list[dict]

    @property
    def gold(self) -> list[tuple[int, int]]:
        return [(q.first, q.last) for q in self.questions]


def option_example(tokenizer, text: str, start: int, end: int, spans: list[tuple[int, int]]):
    ids, offsets = option_input(tokenizer, text[start:end])
    labels = [IGNORE if a == b else O for a, b in offsets]
    for first, last in spans:
        tag = B
        for n, (a, b) in enumerate(offsets):
            if a != b and a < last - start and b > first - start:
                labels[n], tag = tag, I
    return {"ids": ids, "labels": labels}


def option_spans(text: str, question: Question, start: int, end: int) -> list[tuple[int, int]]:
    """The gold options that lie inside text[start:end]."""
    spans = option_ranges(text, question.start, question.options)
    return [(a, b) for a, b in spans if start <= a and b <= end]


def make_item(tokenizer, record: dict[str, object]) -> Item:
    text = str(record["text"])
    questions = questions_of(text, record["label"])  # type: ignore[arg-type]
    options = [
        option_example(tokenizer, text, q.start, q.end, option_spans(text, q, q.start, q.end))
        for q in questions
    ]
    return Item(text, encode(tokenizer, text), questions, options)


def moves(cuts: list[Segment], gold: list[tuple[int, int]], index: int) -> list[tuple[int, int]]:
    """The question with one segment added or removed at either end. An added segment belongs to
    no other question."""
    first, last = gold[index]
    real = [k for k, cut in enumerate(cuts) if cut.kind != BLANK]
    owned = {k for a, b in gold for k in range(a, b + 1)}
    before = [k for k in real if k < first][-1:]
    after = [k for k in real if k > last][:1]
    inner = [k for k in real if first <= k <= last]
    found = [(k, last) for k in before if k not in owned]
    found += [(first, k) for k in after if k not in owned]
    if len(inner) > 1:
        found += [(inner[1], last), (first, inner[-2])]
    return found


def perturbed_examples(tokenizer, items: list[Item], rng: random.Random) -> list[dict]:
    """About 20% of the gold questions, each with one segment added or removed at one end."""
    options = [
        (item, index, found)
        for item in items
        for index in range(len(item.questions))
        if (found := moves(item.enc.cuts, item.gold, index))
    ]
    share = round(PERTURBED_SHARE * sum(len(item.questions) for item in items))
    out = []
    for item, index, found in rng.sample(options, min(share, len(options))):
        first, last = rng.choice(found)
        start, end = item.enc.cuts[first].start, item.enc.cuts[last].end
        spans = option_spans(item.text, item.questions[index], start, end)
        out.append(option_example(tokenizer, item.text, start, end, spans))
    return out
