"""Cut a text into segments by layout and punctuation.

A segment is a (start, end, kind) range in Unicode code points. A unit is a run of non-blank
rows with one continuation indent: a blank row, a list marker, a fence or a row with another
indent starts a new unit. A paragraph unit is cut into sentences. A list item is one segment,
cut only after a question mark. Code rows, table rows and blank rows are one segment each.
fixtures/segments.json holds the cases that every port must give the same ranges for.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

BLANK, CODE, TABLE, ITEM, SENTENCE = "blank", "code", "table", "item", "sentence"
CLAUDE_MARKER = "⏺ "
LIST_ITEM = re.compile(r"(?:[-*•+]|\d+[.)]|[A-Za-z][.)])[ \t]+(?=\S)")
FENCE = re.compile(r"(?:```|~~~)")
BOX = ("│", "┌", "├", "└")
TERMINATOR = re.compile(r"[.!?]+[\"')\]”’]*(?=\s|$)")
DOTTED_INITIALS = re.compile(r"(?:[A-Za-z]\.)+[A-Za-z]")


@dataclass(frozen=True)
class Segment:
    start: int
    end: int
    kind: str  # BLANK, CODE, TABLE, ITEM or SENTENCE


def body_of(row: str) -> str:
    return row.removeprefix(CLAUDE_MARKER) if row.startswith(CLAUDE_MARKER) else row


def indent_of(row: str) -> int:
    marked = len(CLAUDE_MARKER) if row.startswith(CLAUDE_MARKER) else 0
    body = body_of(row)
    return marked + len(body) - len(body.lstrip(" \t"))


def item_marker(row: str) -> re.Match[str] | None:
    return LIST_ITEM.match(body_of(row).lstrip(" \t"))


def is_fence(row: str) -> bool:
    return bool(FENCE.match(body_of(row).strip()))


def is_table(row: str) -> bool:
    return body_of(row).strip().startswith(BOX)


def sentence_ends(span: str, marks: str = ".?!") -> list[int]:
    """Offsets in span where a sentence ends and the next one starts."""
    ends: list[int] = []
    for match in TERMINATOR.finditer(span):
        if match.group(0)[0] not in marks:
            continue
        after = span[match.end() :].lstrip()
        if not after or not (after[0].isupper() or after[0].isdigit()):
            continue
        words = span[: match.start()].split()
        word = words[-1] if words else ""
        if sum(character.isalnum() for character in word) < 2 or DOTTED_INITIALS.fullmatch(word):
            continue
        ends.append(match.end())
    return ends


def segments(text: str) -> list[Segment]:
    rows: list[tuple[int, str]] = []
    offset = 0
    for row in text.split("\n"):
        rows.append((offset, row))
        offset += len(row) + 1

    def span(index: int) -> tuple[int, int]:
        start, row = rows[index]
        return start + len(row) - len(body_of(row).lstrip(" \t")), start + len(row.rstrip())

    base = next((indent_of(row) for _, row in rows if row.strip()), 0)
    out: list[Segment] = []
    in_fence = False
    after_blank = True
    index = 0
    while index < len(rows):
        start, row = rows[index]
        first, end = span(index)
        if not row.strip():
            out.append(Segment(start, start, BLANK))
            after_blank = True
            index += 1
            continue
        fence = is_fence(row)
        code_block = after_blank and indent_of(row) > base and not item_marker(row)
        if fence or in_fence or code_block or is_table(row):
            if fence:
                in_fence = not in_fence
            kind = TABLE if is_table(row) and not in_fence and not fence else CODE
            out.append(Segment(first, end, kind))
            after_blank = False
            index += 1
            while code_block and index < len(rows) and rows[index][1].strip():
                if indent_of(rows[index][1]) <= base:
                    break
                first, end = span(index)
                out.append(Segment(first, end, CODE))
                index += 1
            continue
        after_blank = False
        marker = item_marker(row)
        unit = indent_of(row) + (marker.end() if marker else 0)
        last = index
        while last + 1 < len(rows):
            following = rows[last + 1][1]
            if (
                not following.strip()
                or item_marker(following)
                or is_fence(following)
                or is_table(following)
                or indent_of(following) != (unit if marker else indent_of(row))
            ):
                break
            last += 1
        end = rows[last][0] + len(rows[last][1].rstrip())
        begin, kind = first, ITEM if marker else SENTENCE
        for cut in sentence_ends(text[first:end], "?" if marker else ".?!"):
            out.append(Segment(begin, first + cut, kind))
            begin, kind = first + cut, SENTENCE
            while text[begin].isspace():
                begin += 1
        out.append(Segment(begin, end, kind))
        index = last + 1
    return out
