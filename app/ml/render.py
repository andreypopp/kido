"""Read pi and Claude Code transcripts and render assistant messages like the TUIs."""

from __future__ import annotations

import json
import re
from collections.abc import Iterator
from dataclasses import dataclass, field, replace
from pathlib import Path

import regex
from markdown_it import MarkdownIt

from redact import redact
from segments import CLAUDE_MARKER

GRAPHEME = regex.compile(r"\X")


def cell_width(character: str) -> int:
    wide = False
    for scalar in map(ord, character):
        if (
            scalar == 0x200D
            or 0xFE00 <= scalar <= 0xFE0F
            or 0x0300 <= scalar <= 0x036F
            or 0x1AB0 <= scalar <= 0x1AFF
            or 0x1DC0 <= scalar <= 0x1DFF
            or 0x20D0 <= scalar <= 0x20FF
            or 0xFE20 <= scalar <= 0xFE2F
        ):
            continue
        if (
            0x1100 <= scalar <= 0x115F
            or 0x2329 <= scalar <= 0x232A
            or 0x2E80 <= scalar <= 0xA4CF
            or 0xAC00 <= scalar <= 0xD7A3
            or 0xF900 <= scalar <= 0xFAFF
            or 0xFE10 <= scalar <= 0xFE19
            or 0xFE30 <= scalar <= 0xFE6F
            or 0xFF00 <= scalar <= 0xFF60
            or 0xFFE0 <= scalar <= 0xFFE6
            or 0x1F300 <= scalar <= 0x1F64F
            or 0x1F900 <= scalar <= 0x1F9FF
            or 0x20000 <= scalar <= 0x3FFFD
        ):
            wide = True
    return 2 if wide else 1


def text_width(text: str) -> int:
    if text.isascii():
        return len(text)
    return sum(cell_width(character) for character in GRAPHEME.findall(text))


def wrap_cells(text: str, width: int) -> list[str]:
    if not text:
        return [""]
    width = max(1, width)
    chunks: list[str] = []
    current: list[str] = []
    used = 0
    for character in GRAPHEME.findall(text):
        size = cell_width(character)
        if current and used + size > width:
            chunks.append("".join(current))
            current = [character]
            used = size
        else:
            current.append(character)
            used += size
    chunks.append("".join(current))
    return chunks


@dataclass(frozen=True)
class Message:
    session: str
    text: str


@dataclass(frozen=True)
class Style:
    marker: str
    gutter: str
    nest: int
    heading_prefix: bool
    code_fences: bool
    center_header: bool
    link_urls: bool
    auto_blank: bool
    table_slack: int
    widest_first: bool


PI = Style("", "", 4, True, True, False, False, True, 0, False)
CLAUDE = Style(CLAUDE_MARKER, "  ", 2, False, False, True, True, False, 3, True)
STYLES = {"pi": PI, "claude": CLAUDE}


def wrap_words(text: str, width: int) -> list[str]:
    """Greedy word wrap on cell widths; a word wider than a row is cut at the row end."""
    if text_width(text) <= width:
        return [text.rstrip()]
    width = max(1, width)
    rows: list[str] = []
    current = ""
    used = 0
    for token in re.findall(r"\s+|\S+", text):
        size = text_width(token)
        space = token.isspace()
        if size > width and not space:
            if current:
                rows.append(current)
                current, used = "", 0
            pieces = wrap_cells(token, width)
            rows.extend(pieces[:-1])
            current, used = pieces[-1], text_width(pieces[-1])
        elif used + size > width and used > 0:
            rows.append(current)
            current, used = ("", 0) if space else (token, size)
        else:
            current += token
            used += size
    if current:
        rows.append(current)
    return [row.rstrip() for row in rows] or [""]


def wrap_lines(lines: list[str], width: int) -> list[str]:
    return [row for line in lines for part in line.split("\n") for row in wrap_words(part, width)]


@dataclass
class Block:
    kind: str
    text: str = ""
    level: int = 0
    lang: str = ""
    ordered: bool = False
    start: int = 1
    hidden: bool = False
    gap: bool = False
    items: list[list[Block]] = field(default_factory=list)
    children: list[Block] = field(default_factory=list)
    table: list[list[str]] = field(default_factory=list)


def _inline(token, urls: bool) -> str:
    out: list[str] = []
    hrefs: list[str] = []
    for child in token.children or []:
        kind = child.type
        if kind == "link_open":
            hrefs.append(child.attrGet("href") or "")
            out.append("\0")
        elif kind == "link_close":
            href = hrefs.pop()
            head, _, label = "".join(out).rpartition("\0")
            bare = label in (href, href.removeprefix("mailto:"), href.split("://", 1)[-1])
            shown = (href if bare else f"{label} ({href})") if urls else label
            out = [head, shown]
        elif kind in ("softbreak", "hardbreak"):
            out.append("\n")
        elif kind in ("text", "code_inline", "image", "html_inline", "text_special"):
            out.append(child.content)
    return "".join(out)


def _parse(
    tokens: list, lines: list[str], urls: bool, index: int, close: str | None
) -> tuple[list[Block], int]:
    blocks: list[Block] = []
    previous_end: int | None = None
    while index < len(tokens):
        token = tokens[index]
        if token.type == close:
            return blocks, index + 1
        if token.type == "paragraph_open":
            block = Block("paragraph", _inline(tokens[index + 1], urls), hidden=token.hidden)
            index += 3
        elif token.type == "heading_open":
            block = Block("heading", _inline(tokens[index + 1], urls), level=int(token.tag[1]))
            index += 3
        elif token.type in ("fence", "code_block"):
            info = (token.info or "").split()
            block = Block("code", token.content.rstrip("\n"), lang=info[0] if info else "")
            index += 1
        elif token.type in ("bullet_list_open", "ordered_list_open"):
            block = Block(
                "list",
                ordered=token.type == "ordered_list_open",
                start=int(token.attrGet("start") or 1),
            )
            index += 1
            while tokens[index].type == "list_item_open":
                item, index = _parse(tokens, lines, urls, index + 1, "list_item_close")
                block.items.append(item)
            index += 1
        elif token.type == "blockquote_open":
            children, index = _parse(tokens, lines, urls, index + 1, "blockquote_close")
            block = Block("quote", children=children)
        elif token.type == "hr":
            block = Block("hr")
            index += 1
        elif token.type == "table_open":
            block = Block("table")
            row: list[str] = []
            while tokens[index].type != "table_close":
                if tokens[index].type == "tr_open":
                    row = []
                elif tokens[index].type == "inline":
                    row.append(_inline(tokens[index], urls))
                elif tokens[index].type == "tr_close":
                    block.table.append(row)
                index += 1
            index += 1
        elif token.type == "html_block":
            block = Block("html", token.content.strip())
            index += 1
        else:
            index += 1
            continue
        if blocks and previous_end is not None and token.map is not None:
            blocks[-1].gap = token.map[0] > previous_end
        if token.map is not None:
            previous_end = token.map[1]
            while previous_end > token.map[0] + 1 and not lines[previous_end - 1].strip():
                previous_end -= 1
        blocks.append(block)
    return blocks, index


def _table(rows: list[list[str]], width: int, style: Style) -> list[str]:
    columns = len(rows[0])
    available = width - (3 * columns + 1) - style.table_slack
    if available < columns:
        return wrap_lines([" | ".join(row) for row in rows], width)
    natural = [
        max(text_width(row[i]) if i < len(row) else 0 for row in rows) for i in range(columns)
    ]
    longest = [
        max(
            [
                min(30, max((text_width(word) for word in row[i].split()), default=1))
                for row in rows
                if i < len(row)
            ]
        )
        for i in range(columns)
    ]
    least = [max(1, size) for size in longest]
    if sum(least) > available:
        least = [1] * columns
    if sum(natural) <= available:
        sizes = [max(a, b) for a, b in zip(natural, least, strict=True)]
    elif style.widest_first:
        sizes = list(natural)
        while sum(sizes) > available:
            widest = max(range(columns), key=sizes.__getitem__)
            sizes[widest] -= 1
    else:
        potential = sum(max(0, n - m) for n, m in zip(natural, least, strict=True))
        extra = max(0, available - sum(least))
        sizes = [
            m + (int(max(0, n - m) / potential * extra) if potential else 0)
            for n, m in zip(natural, least, strict=True)
        ]
        spare = available - sum(sizes)
        while spare > 0:
            grew = False
            for i in range(columns):
                if spare > 0 and sizes[i] < natural[i]:
                    sizes[i] += 1
                    spare -= 1
                    grew = True
            if not grew:
                break

    def cells(row: list[str], header: bool) -> list[str]:
        wrapped = [wrap_words(row[i] if i < len(row) else "", sizes[i]) for i in range(columns)]
        out = []
        for line in range(max(len(cell) for cell in wrapped)):
            parts = []
            for i, cell in enumerate(wrapped):
                text = cell[line] if line < len(cell) else ""
                pad = sizes[i] - text_width(text)
                left = pad // 2 if header and style.center_header else 0
                parts.append(" " * left + text + " " * (pad - left))
            out.append("│ " + " │ ".join(parts) + " │")
        return out

    def rule(left: str, middle: str, right: str) -> str:
        return left + "─" + ("─" + middle + "─").join("─" * size for size in sizes) + "─" + right

    out = [rule("┌", "┬", "┐"), *cells(rows[0], True), rule("├", "┼", "┤")]
    for index, row in enumerate(rows[1:]):
        out.extend(cells(row, False))
        if index < len(rows) - 2:
            out.append(rule("├", "┼", "┤"))
    return [*out, rule("└", "┴", "┘")]


def _render_blocks(blocks: list[Block], width: int, style: Style) -> list[str]:
    lines: list[str] = []
    for index, block in enumerate(blocks):
        following = blocks[index + 1].kind if index + 1 < len(blocks) else None
        spaced = style.auto_blank and following is not None and not block.gap
        if block.kind == "paragraph":
            lines.extend(wrap_lines([block.text], width))
            spaced = spaced and following != "list"
        elif block.kind == "heading":
            prefix = "#" * block.level + " " if style.heading_prefix and block.level >= 3 else ""
            lines.extend(wrap_lines([prefix + block.text], width))
        elif block.kind == "code":
            code = block.text.split("\n")
            if style.code_fences:
                lines.extend(
                    wrap_lines([f"```{block.lang}", *["  " + row for row in code], "```"], width)
                )
            else:
                lines.extend(wrap_lines(code, width))
            spaced = spaced and style.code_fences
        elif block.kind == "list":
            lines.extend(_render_list(block, 0, width, style))
            spaced = False
        elif block.kind == "quote":
            inner = _render_blocks(block.children, width - 2, style)
            while inner and inner[-1] == "":
                inner.pop()
            lines.extend("│ " + row for row in wrap_lines(inner, width - 2))
        elif block.kind == "hr":
            lines.append("─" * min(width, 80))
        elif block.kind == "table":
            lines.extend(_table(block.table, width, style))
        else:
            lines.extend(wrap_lines([block.text], width))
        if spaced or (block.gap and following is not None):
            lines.append("")
    return lines


def _render_list(block: Block, depth: int, width: int, style: Style) -> list[str]:
    lines: list[str] = []
    indent = " " * (style.nest * depth)
    loose = any(
        child.kind == "paragraph" and not child.hidden for item in block.items for child in item
    )
    for number, item in enumerate(block.items, start=block.start):
        marker = f"{number}. " if block.ordered else "- "
        first = indent + marker
        rest = indent + " " * len(marker)
        item_width = max(1, width - len(first))
        started = False
        for position, child in enumerate(item):
            if child.kind == "list":
                lines.extend(_render_list(child, depth + 1, width, style))
                started = True
                if child.gap and position + 1 < len(item):
                    lines.append("")
                continue
            rows = _render_blocks([replace(child, gap=False)], item_width, style)
            for row in rows:
                lines.append((rest if started else first) + row)
                started = True
            if child.gap and position + 1 < len(item):
                lines.append("")
        if not started:
            lines.append(first)
        if loose and number - block.start < len(block.items) - 1:
            lines.append("")
    return lines


def render_markdown(markdown: str, width: int, style: Style) -> list[str]:
    """The rows a TUI draws for one assistant text block, one string per row."""
    text = markdown.strip().replace("\t", "   ")
    tokens = MarkdownIt("commonmark").enable("table").parse(text)
    blocks, _ = _parse(tokens, text.split("\n"), style.link_urls, 0, None)
    inner = width - len(style.gutter)
    rows = [row.rstrip() for row in _render_blocks(blocks, inner, style)]
    while rows and not rows[-1]:
        rows.pop()
    rows = [(style.gutter + row).rstrip() for row in rows]
    if rows and style.marker:
        rows[0] = style.marker + rows[0][len(style.gutter) :]
    return rows


def render_text(markdown: str, width: int, style: Style, user: str) -> str:
    rendered = "\n".join(render_markdown(redact(markdown, user=user), width, style))
    return redact(rendered, user=user)


def _records(root: Path, needle: str) -> Iterator[tuple[Path, int, str, dict[str, object]]]:
    """(file, line number, session, record) of every record whose raw line holds needle."""
    for path in sorted(root.rglob("*.jsonl")):
        session = path.stem
        try:
            with path.open(encoding="utf-8", errors="replace") as handle:
                for number, raw in enumerate(handle, start=1):
                    if needle not in raw and '"session"' not in raw:
                        continue
                    try:
                        item = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") == "session" and isinstance(item.get("id"), str):
                        session = item["id"]
                    if isinstance(item.get("sessionId"), str):
                        session = item["sessionId"]
                    yield path, number, session, item
        except OSError:
            continue


def transcript_messages(root: Path, source: str) -> Iterator[Message]:
    """Every assistant text block under root, in file and line order.

    source is "pi" (root = ~/.pi/agent/sessions) or "claude" (root = ~/.claude/projects).
    """
    for _, _, session, item in _records(root, '"text"'):
        message = item.get("message")
        if not isinstance(message, dict):
            continue
        if source == "pi":
            assistant = item.get("type") == "message" and message.get("role") == "assistant"
        else:
            assistant = item.get("type") == "assistant"
        content = message.get("content")
        if assistant and isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text")
                    if isinstance(text, str) and text.strip():
                        yield Message(session, text.strip())


def ask_blocks(root: Path) -> Iterator[tuple[str, object]]:
    """(session, input) of every AskUserQuestion call, whatever the input."""
    for _, _, session, item in _records(root, "AskUserQuestion"):
        message = item.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        for block in content if isinstance(content, list) else []:
            if isinstance(block, dict) and block.get("name") == "AskUserQuestion":
                yield session, block.get("input")


def ask_sessions(root: Path) -> set[str]:
    return {session for session, _ in ask_blocks(root)}


def ask_questions(root: Path) -> Iterator[tuple[str, str, list[str]]]:
    """(session, question, option labels) of every AskUserQuestion question that has options."""
    for session, payload in ask_blocks(root):
        for entry in payload.get("questions", []) if isinstance(payload, dict) else []:
            options = entry.get("options") if isinstance(entry, dict) else None
            labels = (
                [
                    option["label"]
                    for option in options
                    if isinstance(option, dict) and isinstance(option.get("label"), str)
                ]
                if isinstance(options, list)
                else []
            )
            if isinstance(entry, dict) and isinstance(entry.get("question"), str) and labels:
                yield session, entry["question"], labels
