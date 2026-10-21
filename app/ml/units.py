"""Units: the paragraphs of a normalised message, each on one line."""

import re

from normalise import Mapped, lines_of

ITEM = re.compile(r"\s*(?:[-*+•]|\d+[.)]|[A-Za-z][.)])\s")
CLOSERS = ")]\"'”"
DECISION = re.compile(
    r"\b(?:which|prefer|choose|choice|options?|alternatively|either|decide|decision|pick|"
    r"would you like|do you want|let me know|your call|up to you|should i|shall i|"
    r"want me to|confirm|approve|go ahead|proceed|recommend\w*|tell me|"
    r"you(?:['’]d)? (?:want|like|prefer|agree)|you['’]d rather|rather|unless you|"
    r"say (?:the word|if|when|so)|whether|waiting (?:on|for) you|go-ahead|ways? (?:to|out)|"
    r"two ways|the question is)\b",
    re.I,
)


def paragraphs(mapped: Mapped) -> list[list[tuple[int, int]]]:
    """Runs of non-blank lines, as (start, end) of each line."""
    runs: list[list[tuple[int, int]]] = [[]]
    for start, end in lines_of(mapped):
        if mapped.text[start:end].strip():
            runs[-1].append((start, end))
        elif runs[-1]:
            runs.append([])
    return [run for run in runs if run]


def units(mapped: Mapped) -> list[Mapped]:
    """A list paragraph joins the unit before it when that unit ends with ? or : (before closing
    brackets and quotes) or holds a list item."""
    groups: list[list[tuple[int, int]]] = []
    for run in paragraphs(mapped):
        if groups and ITEM.match(mapped.text[run[0][0] : run[0][1]]):
            before = [mapped.text[a:b] for a, b in groups[-1]]
            if before[-1].rstrip().rstrip(CLOSERS).endswith(("?", ":")) or any(
                map(ITEM.match, before)
            ):
                groups[-1] += run
                continue
        groups.append(run)
    return [mapped.slice(group[0][0], group[-1][1]).collapse() for group in groups]


def category(text: str) -> str:
    """ "question" for a unit with a "?", "pool" for one with a decision word, else "other". Only
    the first two categories are labelled, trained on and read by the model."""
    if "?" in text:
        return "question"
    return "pool" if DECISION.search(text) else "other"
