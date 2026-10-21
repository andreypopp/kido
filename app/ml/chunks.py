"""The inputs of the two passes: the token windows that the question model reads and the
question text that the option model reads.

A text is tokenized once. A chunk is a run of whole segments of at most ROOM tokens; the next
chunk starts at a paragraph boundary about OVERLAP tokens later. Training draws chunks at random
starts instead.
"""

from __future__ import annotations

import bisect
import random
from dataclasses import dataclass

import numpy as np

from flat import Flat, flatten
from segments import BLANK, Segment

LENGTH = 1024  # the question pass reads at most this many tokens
OPTION_LENGTH = 512  # the option pass reads at most this many tokens
ROOM = LENGTH - 2  # without [CLS] and [SEP]
OVERLAP = 512
OPTION_SHAPES = (128, OPTION_LENGTH)  # the option functions of Core ML
LONG = 2 * LENGTH  # the question function that only the 2,048 measurement builds
STEP_MAX = 768
INSIDE_SHARE = 0.1
O, B, I = 0, 1, 2  # noqa: E741
IGNORE = -100


@dataclass(frozen=True)
class Encoded:
    ids: list[int]
    flat: Flat
    begin: list[int]  # the first token of segment k, with the spaces before it
    head: list[int]  # the first token of segment k
    last: list[int]  # the token with the last non-space character of segment k
    cls: int
    sep: int


@dataclass(frozen=True)
class Chunk:
    first: int  # segment indexes, both included
    last: int
    lo: int  # token range in Encoded.ids
    hi: int


def encode(tokenizer, text: str) -> Encoded:
    flat = flatten(text)
    out = tokenizer(flat.text, return_offsets_mapping=True, add_special_tokens=False)
    ends = [end for _, end in out["offset_mapping"]]
    begin = []
    for first, _ in flat.ranges:
        if first > 0 and flat.text[first - 1] == " ":
            first -= 1
        begin.append(bisect.bisect_right(ends, first))
    begin[0:1] = [0] if flat.cuts else []
    head = [bisect.bisect_right(ends, first) for first, _ in flat.ranges]
    last = [
        max(h, bisect.bisect_right(ends, stop) - 1)
        for h, (_, stop) in zip(head, flat.ranges, strict=True)
    ]
    return Encoded(
        list(out["input_ids"]),
        flat,
        begin,
        head,
        last,
        tokenizer.cls_token_id,
        tokenizer.sep_token_id,
    )


def option_input(tokenizer, body: str) -> tuple[list[int], list[tuple[int, int]]]:
    """Token ids and character offsets of a question text; a special token has the offset (0, 0)."""
    out = tokenizer(body, return_offsets_mapping=True, truncation=True, max_length=OPTION_LENGTH)
    return out["input_ids"], [tuple(pair) for pair in out["offset_mapping"]]


def chunk_from(enc: Encoded, i: int) -> Chunk:
    count = len(enc.flat.cuts)

    def stop(j: int) -> int:
        return enc.begin[j + 1] if j + 1 < count else len(enc.ids)

    j = i
    while j + 1 < count and stop(j + 1) - enc.begin[i] <= ROOM:
        j += 1
    lo = enc.begin[i]
    return Chunk(i, j, lo, min(stop(j), lo + ROOM))


def paragraph_starts(cuts: list[Segment]) -> list[int]:
    return [
        k for k, s in enumerate(cuts) if s.kind != BLANK and (k == 0 or cuts[k - 1].kind == BLANK)
    ]


def plan(enc: Encoded) -> list[Chunk]:
    out: list[Chunk] = []
    paragraphs = set(paragraph_starts(enc.flat.cuts))
    i = 0
    while enc.flat.cuts:
        chunk = chunk_from(enc, i)
        out.append(chunk)
        if chunk.last + 1 >= len(enc.flat.cuts):
            break
        after = [
            k
            for k in range(i + 1, chunk.last + 1)
            if enc.begin[k] - enc.begin[i] >= OVERLAP and enc.flat.cuts[k].kind != BLANK
        ]
        paragraph = [
            k for k in after if k in paragraphs and enc.begin[k] - enc.begin[i] <= STEP_MAX
        ]
        i = (paragraph or after or [chunk.last + 1])[0]
    return out


def members(enc: Encoded, chunk: Chunk) -> list[int]:
    """The segments of the chunk that have a token and so a tag."""
    return [
        k
        for k in range(chunk.first, chunk.last + 1)
        if enc.flat.cuts[k].kind != BLANK and enc.head[k] < chunk.hi
    ]


def slots(enc: Encoded, chunk: Chunk) -> list[tuple[int, int, int]]:
    """(segment, first position, last position in ids_of(chunk)); the last is clamped."""
    return [
        (k, enc.head[k] - chunk.lo + 1, min(enc.last[k], chunk.hi - 1) - chunk.lo + 1)
        for k in members(enc, chunk)
    ]


def ids_of(enc: Encoded, chunk: Chunk) -> list[int]:
    return [enc.cls, *enc.ids[chunk.lo : chunk.hi], enc.sep]


def training_starts(enc: Encoded) -> list[int]:
    """Paragraph starts, and the later segments of a paragraph from OVERLAP tokens in, where
    the plan falls back to a segment start; so every segment is in some window."""
    cuts, begin = enc.flat.cuts, enc.begin
    starts = paragraph_starts(cuts)
    out = list(starts)
    for k, start in enumerate(starts):
        stop = starts[k + 1] if k + 1 < len(starts) else len(cuts)
        out += [
            j
            for j in range(start + 1, stop)
            if cuts[j].kind != BLANK and begin[j] - begin[start] >= OVERLAP
        ]
    return out


def sample_chunks(enc: Encoded, gold: list[tuple[int, int]], rng: random.Random) -> list[Chunk]:
    """One chunk for a text that fits, else as many chunks as the plan has, at random starts.
    A start is a training start, or in 10% of the draws a later segment of a gold question."""
    whole = plan(enc)
    if len(whole) <= 1:
        return whole
    starts = training_starts(enc)
    inside = [
        k
        for first, last in gold
        for k in range(first + 1, last + 1)
        if enc.flat.cuts[k].kind != BLANK
    ]
    return [
        chunk_from(enc, rng.choice(inside if inside and rng.random() < INSIDE_SHARE else starts))
        for _ in whole
    ]


def labels_of(enc: Encoded, chunk: Chunk, gold: list[tuple[int, int]]) -> list[int]:
    """Tags on the first token of each segment, else IGNORE. A gold question that starts before the
    chunk leaves its remaining segments as O; one that ends after it keeps its tags."""
    labels = [IGNORE] * (chunk.hi - chunk.lo + 2)
    present = slots(enc, chunk)
    for _, position, _ in present:
        labels[position] = O
    for first, last in gold:
        if not chunk.first <= first <= chunk.last:
            continue
        tag = B
        for k, position, _ in present:
            if first <= k <= last:
                labels[position] = tag
                tag = I
    return labels


def emissions(out: np.ndarray, chunk_slots: list[tuple[int, int, int]]) -> np.ndarray:
    """Slot scores: 3 columns at the first token, or 6: columns 0-2 there plus 3-5 at the last."""
    first = out[[head for _, head, _ in chunk_slots]]
    if out.shape[1] == 3:
        return first[:, :3]
    return first[:, :3] + out[[last for _, _, last in chunk_slots]][:, 3:]


def decode(logits: np.ndarray, threshold: float | None = None) -> list[int]:
    """The tag of each row. With a threshold a B stays only if its probability reaches it;
    otherwise the position takes the likelier of I and O."""
    tags = logits.argmax(-1)
    if threshold is not None:
        shifted = np.exp(logits - logits.max(-1, keepdims=True))
        weak = (tags == B) & (shifted[:, B] / shifted.sum(-1) < threshold)
        tags = np.where(weak, np.where(logits[:, I] > logits[:, O], I, O), tags)
    return tags.tolist()


def question_example(enc: Encoded, chunk: Chunk, gold: list[tuple[int, int]]) -> dict:
    """ids, labels (IGNORE except at slot first tokens) and the slot positions for the CRF."""
    present = slots(enc, chunk)
    return {
        "ids": ids_of(enc, chunk),
        "labels": labels_of(enc, chunk, gold),
        "heads": [head for _, head, _ in present],
        "lasts": [last for _, _, last in present],
        "inside": chunk.lo > 0,
    }
