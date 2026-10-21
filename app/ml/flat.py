"""The flat text that both models read: the segments of a text, each with its whitespace collapsed,
and its list marker normalised. Segments of one paragraph are joined by
one space, paragraphs by a blank line. `origin` maps every flat character to a character of the
original text, so that a flat span gives an exact substring of the original.
"""

from __future__ import annotations

import bisect
from dataclasses import dataclass

from segments import BLANK, ITEM, Segment, item_marker, segments

INPUT = "flat"


@dataclass(frozen=True)
class Flat:
    text: str
    origin: list[int]  # the original character of each flat character
    cuts: list[Segment]  # the segments of the original text
    ranges: list[tuple[int, int]]  # the flat range of each segment; a blank one is empty


def piece(text: str, cut: Segment) -> tuple[list[str], list[int]]:
    """The flat characters of one segment and their original positions."""
    chars: list[str] = []
    origin: list[int] = []
    start = cut.start
    if cut.kind == ITEM and (marker := item_marker(text[cut.start : cut.end])):
        word = marker.group(0).rstrip()
        chars = list("-" if word[0] in "-*•+" else "1.")
        origin = [cut.start, cut.start + len(word) - 1][: len(chars)]
        start += len(word)
    for at in range(start, cut.end):
        if not text[at].isspace():
            chars.append(text[at])
        elif chars and chars[-1] != " ":
            chars.append(" ")
        else:
            continue
        origin.append(at)
    return chars, origin


def flatten(text: str) -> Flat:
    cuts = segments(text)
    out: list[str] = []
    origin: list[int] = []
    ranges: list[tuple[int, int]] = []
    previous: Segment | None = None
    broken = False
    for cut in cuts:
        if cut.kind == BLANK:
            broken = True
            ranges.append((len(out), len(out)))
            continue
        if previous is not None:
            joint = "\n\n" if broken else " "
            out += joint
            origin += [previous.end] * len(joint)
        chars, where = piece(text, cut)
        ranges.append((len(out), len(out) + len(chars)))
        out += chars
        origin += where
        previous, broken = cut, False
    return Flat("".join(out), origin, cuts, ranges)


def to_flat(flat: Flat, position: int) -> int:
    """The first flat character at or after an original position."""
    return bisect.bisect_left(flat.origin, position)


def question_body(flat: Flat, start: int, end: int) -> tuple[str, int]:
    """The flat text of the original range start..end, and where it starts in the flat text."""
    first = to_flat(flat, start)
    return flat.text[first : to_flat(flat, end)], first
