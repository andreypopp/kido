"""Plain paragraphs and list items of a message, from transcript markdown or from screen text."""

import re
from dataclasses import dataclass

from markdown_it import MarkdownIt

MARKDOWN = MarkdownIt("commonmark").enable("table")
FOOTNOTE = re.compile(r"\s*\[\^[^\]]+\]:")
FRONT_MATTER_END = re.compile(r"---\s*|\.\.\.\s*")
SCREEN_DROP = re.compile(r"\s*(?:#{1,6}(?:\s|$)|[>▎]|[|┌└├│┃╭╰]|(?:[-*_=]\s*){3,}$|[─━═]+$)")
FENCE = re.compile(r"\s*(?:```|~~~)")
MARKER = re.compile(r"\s*(⏺ )")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
AUTOLINK = re.compile(r"<[A-Za-z][A-Za-z0-9+.-]*:[^\s>]*>")
EMPHASIS = (
    re.compile(r"</?[A-Za-z][^>]*>"),
    re.compile(r"\*\*|~~|(?<!\w)__(?=\S)|(?<=\S)__(?!\w)"),
    re.compile(r"(?<![\w*])\*(?=[^\s*])|(?<=[^\s*])\*(?![\w*])"),
    re.compile(r"(?<!\w)_(?=[^\s_])|(?<=[^\s_])_(?!\w)"),
)


@dataclass(frozen=True)
class Mapped:
    """text, and for each character its index in the input."""

    text: str
    origin: list[int]

    def slice(self, start: int, end: int) -> "Mapped":
        return Mapped(self.text[start:end], self.origin[start:end])

    def keep(self, mask: list[bool]) -> "Mapped":
        pairs = [(c, o) for c, o, k in zip(self.text, self.origin, mask, strict=True) if k]
        return Mapped("".join(c for c, _ in pairs), [o for _, o in pairs])

    def collapse(self) -> "Mapped":
        """One line: every whitespace run is one space, with no space at the edges."""
        text, origin = [], []
        for char, index in zip(self.text, self.origin, strict=True):
            if char.isspace():
                if text and text[-1] != " ":
                    text.append(" ")
                    origin.append(index)
            else:
                text.append(char)
                origin.append(index)
        if text and text[-1] == " ":
            text.pop()
            origin.pop()
        return Mapped("".join(text), origin)


def lines_of(mapped: Mapped) -> list[tuple[int, int]]:
    """(start, end) of each line, without its newline."""
    bounds, start = [], 0
    for line in mapped.text.split("\n"):
        bounds.append((start, start + len(line)))
        start += len(line) + 1
    return bounds


def screen_mask(mapped: Mapped) -> list[bool]:
    mask = [True] * len(mapped.text)
    fenced = False
    for start, end in lines_of(mapped):
        line = mapped.text[start:end]
        if FENCE.match(line):
            fenced = not fenced
            drop = True
        else:
            drop = fenced or bool(SCREEN_DROP.match(line))
        if drop:
            mask[start:end] = [False] * (end - start)
        elif marker := MARKER.match(line):
            mask[start + marker.start(1) : start + marker.end(1)] = [False, False]
    return mask


def inline_drops(line: str) -> list[int]:
    """Indexes of the characters of the inline markup in a line. Code spans and autolink URLs
    keep their text."""
    protected = [False] * len(line)
    drops: set[int] = set()

    def drop(start: int, end: int) -> None:
        if not any(protected[start:end]):
            drops.update(range(start, end))

    for span in CODE_SPAN.finditer(line):
        protected[span.start(2) : span.end(2)] = [True] * len(span.group(2))
        drops.update(range(span.start(1), span.end(1)))
        drops.update(range(span.end(2), span.end()))
    for link in AUTOLINK.finditer(line):
        drop(link.start(), link.start() + 1)
        drop(link.end() - 1, link.end())
        protected[link.start() : link.end()] = [True] * len(link.group())
    for image in IMAGE.finditer(line):
        drop(image.start(), image.end())
    for link in LINK.finditer(line):
        drop(link.start(), link.start(1))
        drop(link.end(1), link.end())
    for pattern in EMPHASIS:
        for found in pattern.finditer(line):
            drop(found.start(), found.end())
    return sorted(drops)


def is_pseudo_heading(inline) -> bool:
    """A paragraph that is one strong-emphasis span, with an optional colon after it, and no "?":
    a bold question is a question."""
    children = [
        c for c in inline.children if c.type != "text" or c.content.strip() not in ("", ":")
    ]
    return (
        "?" not in inline.content
        and len(children) >= 2
        and children[0].type == "strong_open"
        and children[-1].type == "strong_close"
        and all(c.type != "strong_close" for c in children[1:-1])
    )


def prose_lines(lines: list[str]) -> set[int]:
    """Lines of the paragraphs that are not in block quotes and are not pseudo-headings; a list
    item can hold them."""
    kept, quoted, listed = set(), 0, 0
    tokens = MARKDOWN.parse("\n".join(lines))
    for number, token in enumerate(tokens):
        if token.type == "blockquote_open":
            quoted += 1
        elif token.type == "blockquote_close":
            quoted -= 1
        elif token.type in ("bullet_list_open", "ordered_list_open"):
            listed += 1
        elif token.type in ("bullet_list_close", "ordered_list_close"):
            listed -= 1
        elif token.type == "paragraph_open" and not quoted and token.map:
            heading = not listed and is_pseudo_heading(tokens[number + 1])
            if not heading and not FOOTNOTE.match(lines[token.map[0]]):
                kept.update(range(*token.map))
    return kept


def front_matter_lines(lines: list[str]) -> int:
    if lines and lines[0].strip() == "---":
        for number, line in enumerate(lines[1:], 1):
            if FRONT_MATTER_END.fullmatch(line):
                return number + 1
    return 0


def normalise(text: str, *, screen: bool) -> Mapped:
    """The paragraphs and list items of a message, with the lines of the others empty."""
    mapped = Mapped(text, list(range(len(text))))
    if screen:
        mapped = mapped.keep(screen_mask(mapped))
    bounds = lines_of(mapped)
    lines = [mapped.text[a:b].replace("\r", " ") for a, b in bounds]
    front = front_matter_lines(lines)
    lines[:front] = [""] * front
    kept = prose_lines(lines)
    mask = [True] * len(mapped.text)
    for number, (start, end) in enumerate(bounds):
        if number not in kept:
            mask[start:end] = [False] * (end - start)
            continue
        for index in [] if screen else inline_drops(lines[number]):
            mask[start + index] = False
    return mapped.keep(mask)
