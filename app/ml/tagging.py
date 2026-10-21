"""BIO tags over tokens, and the character spans they stand for."""

OUT, BEGIN, INSIDE = 0, 1, 2
IGNORE = -100
MAX_TOKENS = 512
OPTION_TRAILING = ",.?;:"
CLOSING = {")": "(", "]": "[", "”": "“", '"': '"', "'": "'"}
OPENING = {"(": ")", "[": "]", "“": "”", '"': '"', "'": "'"}

Span = tuple[int, int]


def encode(tokenizer, text: str) -> tuple[list[int], list[Span]]:
    """Token ids and character offsets, at most MAX_TOKENS, with the special tokens at (0, 0).
    An offset never has a space at its edge."""
    encoded = tokenizer(text, truncation=True, max_length=MAX_TOKENS, return_offsets_mapping=True)
    offsets = []
    for start, end in encoded["offset_mapping"]:
        while start < end and text[start].isspace():
            start += 1
        offsets.append((start, end) if start < end else (0, 0))
    return encoded["input_ids"], offsets


def token_count(tokenizer, text: str) -> int:
    return len(tokenizer(text)["input_ids"])


def tags_for(offsets: list[Span], spans: list[Span]) -> list[int]:
    """BEGIN on the first token of each span, INSIDE on the rest, IGNORE on special tokens."""
    tags = [IGNORE if end == 0 else OUT for _, end in offsets]
    for first, last in spans:
        inside = [i for i, (s, e) in enumerate(offsets) if e > s and s < last and e > first]
        for position, i in enumerate(inside):
            tags[i] = BEGIN if position == 0 else INSIDE
    return tags


def unbalanced(part: str, char: str, mate: str) -> bool:
    """char is a bracket or quote of part that its mate does not match."""
    if char == mate:
        return part.count(char) % 2 == 1
    return part.count(char) > part.count(mate)


def trim(text: str, span: Span) -> Span:
    """A token can hold a bracket or a quote after a "?". Cut a closing one at the end of the span
    that has no opener inside it, and an opening one at the start that has no closer."""
    start, end = span
    while end - start > 1 and text[end - 1] in CLOSING:
        if not unbalanced(text[start:end], text[end - 1], CLOSING[text[end - 1]]):
            break
        end -= 1
    while end - start > 1 and text[start] in OPENING:
        if not unbalanced(text[start:end], text[start], OPENING[text[start]]):
            break
        start += 1
    return start, end


def cut_trailing(text: str, span: Span, trailing: str) -> Span:
    """The span without the characters of `trailing` at its end. A token can hold a comma or a
    full stop with the word before it."""
    start, end = span
    while end - start > 1 and text[end - 1] in trailing:
        end -= 1
    return start, end


def spans_of(text: str, offsets: list[Span], tags: list[int], trailing: str = "") -> list[Span]:
    """BEGIN INSIDE* runs as character spans, without brackets, quotes and `trailing` characters
    that the tokens added at the edges. An INSIDE after no run starts nothing."""
    found: list[Span] = []
    start = last = None
    for (s, e), tag in zip(offsets, tags, strict=True):
        if e == 0:
            continue
        if tag == INSIDE and start is not None:
            last = e
            continue
        if start is not None:
            found.append(cut_trailing(text, trim(text, (start, last)), trailing))
        start, last = (s, e) if tag == BEGIN else (None, None)
    if start is not None:
        found.append(cut_trailing(text, trim(text, (start, last)), trailing))
    return found


def project(tokenizer, text: str, spans: list[Span], trailing: str = "") -> list[Span]:
    """The spans as the tokens can hold them: what the tags of the spans decode to."""
    _, offsets = encode(tokenizer, text)
    return spans_of(text, offsets, tags_for(offsets, spans), trailing)
