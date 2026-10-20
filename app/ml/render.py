"""Render terminal-like markdown and cut paragraph contexts like Paragraphs.swift."""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import regex
from markdown_it import MarkdownIt

GRAPHEME = regex.compile(r"\X")
MARKER = re.compile(r"^\s*(?:[-*•]\s+|\d+[.)]\s+|[A-Za-z]\)\s+)")
PROMPT_LINE = re.compile(r"^([ >]) (\d+): (.*)$")
SEED = 0
TARGET_CONTEXTS = 460
CONTEXT_BEFORE = 2
CONTEXT_AFTER = 2
LINE_LIMIT = 60
CHARACTER_LIMIT = 6000
WIDTH_MIN = 60
WIDTH_MAX = 220


@dataclass(frozen=True)
class Row:
    text: str
    wrapped: bool


@dataclass(frozen=True)
class Line:
    rows: tuple[int, int]
    text: str


@dataclass(frozen=True)
class Block:
    lines: tuple[Line, ...]
    text: str
    start: int
    end: int


@dataclass(frozen=True)
class Context:
    lines: tuple[Line, ...]
    ranges: tuple[tuple[int, int], ...]
    hovered: int
    prompt: str


def character_count(text: str) -> int:
    return len(GRAPHEME.findall(text))


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


def _inline(token) -> str:
    out: list[str] = []
    for child in token.children or []:
        kind = child.type
        if kind == "text":
            out.append(child.content)
        elif kind == "code_inline":
            out.append(child.content)
        elif kind == "strong_open" or kind == "strong_close":
            out.append("**")
        elif kind in ("softbreak",):
            out.append(" ")
        elif kind in ("hardbreak",):
            out.append("\n")
        elif kind == "image":
            out.append(child.content)
        elif kind == "text_special":
            out.append(child.content)
        elif kind.endswith("_open") or kind.endswith("_close"):
            continue
        else:
            out.append(child.content)
    return "".join(out)


def _trim(text: str) -> str:
    return text.rstrip(" \t")


def render_markdown(markdown: str, width: int) -> list[Row]:
    md = MarkdownIt("commonmark").enable("table")
    tokens = md.parse(markdown)
    rows_out: list[Row] = []
    lists: list[dict[str, object]] = []
    items: list[str] = []
    quotes = 0
    in_table = False
    cells: list[str] = []
    table_row: list[str] = []

    def add(text: str, wrapped: bool) -> None:
        rows_out.append(Row(text, wrapped))

    def blank() -> None:
        if rows_out and rows_out[-1].text != "":
            add("", False)

    def prefix() -> tuple[str, str]:
        quote = "│ " * quotes
        if items:
            item = quote + items[-1]
            return item, " " * text_width(item)
        if quotes:
            return quote, " " * text_width(quote)
        return "", ""

    def emit(text: str, *, wrappable: bool = True) -> None:
        first, continuation = prefix()
        parts = text.split("\n") if "\n" in text else [text]
        for part in parts:
            if not wrappable:
                add(first + part, False)
                continue
            chunks = wrap_cells(part, width - text_width(first))
            for index, chunk in enumerate(chunks):
                add((first if index == 0 else continuation) + chunk, index < len(chunks) - 1)

    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token.type == "blockquote_open":
            quotes += 1
        elif token.type == "blockquote_close":
            quotes = max(0, quotes - 1)
            blank()
        elif token.type == "bullet_list_open":
            lists.append({"ordered": False, "marker": token.markup or "-", "next": 1})
        elif token.type == "ordered_list_open":
            start = token.attrGet("start") or 1
            lists.append({"ordered": True, "marker": token.markup or ".", "next": int(start)})
        elif token.type in ("bullet_list_close", "ordered_list_close"):
            if lists:
                lists.pop()
            if items:
                items.pop()
            if not lists:
                blank()
        elif token.type == "list_item_open":
            entry = lists[-1]
            if entry["ordered"]:
                marker = f"{entry['next']}{entry['marker']}"
                entry["next"] = int(entry["next"]) + 1
            else:
                marker = str(entry["marker"])
            items.append("  " * (len(lists) - 1) + marker + " ")
        elif token.type == "list_item_close":
            if items:
                items.pop()
        elif token.type == "heading_close":
            blank()
        elif token.type == "paragraph_close":
            if not items and not quotes:
                blank()
        elif token.type == "inline":
            text = _inline(token)
            if in_table:
                cells.append(text)
            else:
                emit(text)
        elif token.type in ("fence", "code_block"):
            first, _ = prefix()
            for code_line in token.content.splitlines():
                add(first + "  " + code_line, False)
            blank()
        elif token.type == "table_open":
            in_table = True
            blank()
        elif token.type == "tr_open":
            table_row = []
        elif token.type in ("th_open", "td_open"):
            cells = []
        elif token.type in ("th_close", "td_close"):
            table_row.append("".join(cells))
            cells = []
        elif token.type == "tr_close":
            add("| " + " | ".join(table_row) + " |", False)
        elif token.type == "table_close":
            in_table = False
            blank()
        elif token.type == "html_block":
            pass
        index += 1

    while rows_out and rows_out[-1].text == "" and not rows_out[-1].wrapped:
        rows_out.pop()
    return rows_out


def logical_lines(rows: list[Row]) -> list[Line]:
    lines: list[Line] = []
    start = 0
    while start < len(rows):
        end = start
        while end + 1 < len(rows) and rows[end].wrapped:
            end += 1
        texts = [rows[index].text for index in range(start, end + 1)]
        texts[-1] = _trim(texts[-1])
        lines.append(Line((start, end), _trim("".join(texts))))
        start = end + 1
    return lines


def partition_blocks(lines: list[Line]) -> list[Block]:
    blocks: list[Block] = []
    start = 0
    while start < len(lines):
        if not lines[start].text.strip(" \t"):
            start += 1
            continue
        end = start
        while end + 1 < len(lines) and lines[end + 1].text.strip(" \t"):
            end += 1
        blocks.append(
            Block(
                tuple(lines[start : end + 1]),
                "\n".join(line.text for line in lines[start : end + 1]),
                start,
                end,
            )
        )
        start = end + 1
    return blocks


def cut_context(rows: list[Row], row: int) -> Context | None:
    lines = logical_lines(rows)
    blocks = partition_blocks(lines)
    hovered = next(
        (
            index
            for index, block in enumerate(blocks)
            if block.lines[0].rows[0] <= row <= block.lines[-1].rows[1]
        ),
        None,
    )
    if hovered is None:
        return None
    low = hovered
    high = hovered
    total_lines = len(blocks[hovered].lines)
    total_characters = character_count(blocks[hovered].text)
    added_before = 0
    added_after = 0

    def add(before: bool) -> bool:
        nonlocal low, high, total_lines, total_characters, added_before, added_after
        if before and added_before >= CONTEXT_BEFORE:
            return False
        if not before and added_after >= CONTEXT_AFTER:
            return False
        index = low - 1 if before else high + 1
        if index < 0 or index >= len(blocks):
            return False
        gap = (
            blocks[low].start - blocks[index].end - 1
            if before
            else blocks[index].start - blocks[high].end - 1
        )
        added_lines = len(blocks[index].lines) + gap
        added_characters = character_count(blocks[index].text) + gap
        if (
            total_lines + added_lines > LINE_LIMIT
            or total_characters + added_characters > CHARACTER_LIMIT
        ):
            return False
        if before:
            low = index
            added_before += 1
        else:
            high = index
            added_after += 1
        total_lines += added_lines
        total_characters += added_characters
        return True

    while added_before < CONTEXT_BEFORE or added_after < CONTEXT_AFTER:
        before = added_before <= added_after
        if add(before) or add(not before):
            continue
        break

    start = blocks[low].start
    end = blocks[high].end
    selected = tuple(lines[start : end + 1])
    ranges = tuple(
        (blocks[index].start - start, blocks[index].end - start)
        for index in range(low, high + 1)
    )
    hover = hovered - low
    return Context(selected, ranges, hover, format_prompt(selected, ranges, hover))


def format_prompt(
    lines: tuple[Line, ...] | list[Line],
    ranges: tuple[tuple[int, int], ...],
    hovered: int,
) -> str:
    first, last = ranges[hovered]
    return "\n".join(
        f"{'>' if first <= index <= last else ' '} {index + 1}: {line.text}"
        for index, line in enumerate(lines)
    )


def read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def write_jsonl(path: Path, records: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")


def render_ask(question: str, labels: list[str]) -> str:
    options = "\n".join(f"{index}. **{label}**" for index, label in enumerate(labels, start=1))
    return f"{question}\n\n{options}"


def sample_width(rng: random.Random) -> int:
    return rng.randint(WIDTH_MIN, WIDTH_MAX)


def choose_hover(rows: list[Row], positive: bool, rng: random.Random) -> int | None:
    blocks = partition_blocks(logical_lines(rows))
    if not blocks:
        return None
    if positive:
        matching = [block for block in blocks if "?" in block.text[-300:]]
    else:
        matching = [block for block in blocks if "?" not in block.text]
    if not matching:
        return None
    block = matching[-1] if positive else rng.choice(matching)
    return block.lines[0].rows[0]


def prompt_lines(prompt: str) -> list[dict[str, object]]:
    lines: list[dict[str, object]] = []
    offset = 0
    for raw in prompt.split("\n"):
        match = PROMPT_LINE.match(raw)
        if match is None:
            raise ValueError(f"bad prompt line: {raw!r}")
        text = match.group(3)
        start = offset + match.start(3)
        lines.append(
            {
                "index": int(match.group(2)),
                "text": text,
                "start": start,
                "end": start + len(text),
            }
        )
        offset += len(raw) + 1
    return lines


def redact_context(context: Context, user: str) -> Context:
    from redact import redact

    texts = [redact(line.text, user=user) for line in context.lines]
    rebuilt: list[Line] = []
    for line, text in zip(context.lines, texts, strict=True):
        rebuilt.append(Line(line.rows, text))
    selected = tuple(rebuilt)
    return Context(
        selected,
        context.ranges,
        context.hovered,
        format_prompt(selected, context.ranges, context.hovered),
    )


def ask_label(record: dict[str, object]) -> dict[str, object] | None:
    from redact import redact

    prompt = str(record["prompt"])
    lines = prompt_lines(prompt)
    ranges = [tuple(pair) for pair in record["ranges"]]
    hovered = int(record["hovered"])
    if hovered + 1 >= len(ranges):
        return None
    question_range = ranges[hovered]
    option_range = ranges[hovered + 1]
    labels = record.get("ask", {}).get("labels", [])
    if not isinstance(labels, list) or len(labels) != option_range[1] - option_range[0] + 1:
        return None
    classes = ["other"] * len(lines)
    for index in range(question_range[0], question_range[1] + 1):
        classes[index] = "question"
    for index in range(option_range[0], option_range[1] + 1):
        classes[index] = "option"
    options: list[dict[str, object]] = []
    for offset, label in enumerate(labels):
        value = redact(str(label), user=__import__("getpass").getuser())
        line = lines[option_range[0] + offset]["text"]
        if line.count(value) != 1:
            return None
        options.append({"line": option_range[0] + offset + 1, "text": value})
    return {"lines": classes, "options": options}


def context_record(
    *,
    session: str,
    source: str,
    context: Context,
    width: int,
    user: str,
    ask: dict[str, object] | None = None,
    label: dict[str, object] | None = None,
) -> dict[str, object] | None:
    redacted = redact_context(context, user)
    identifier = __import__("hashlib").sha256(
        f"{session}\0{source}\0{redacted.prompt}".encode()
    ).hexdigest()[:20]
    record: dict[str, object] = {
        "id": identifier,
        "session": session,
        "source": source,
        "prompt": redacted.prompt,
        "lines": prompt_lines(redacted.prompt),
        "hovered": redacted.hovered,
        "ranges": [list(pair) for pair in redacted.ranges],
        "width": width,
    }
    if ask is not None:
        record["ask"] = ask
    if ask is not None:
        gold = ask_label(record)
        if gold is None:
            return None
        record["gold"] = gold
    if label is not None:
        record["label"] = label
    return record


def _candidate_context(
    markdown: str,
    session: str,
    source: str,
    positive: bool,
    width: int,
    rng: random.Random,
    user: str,
    *,
    ask: dict[str, object] | None = None,
    label: dict[str, object] | None = None,
) -> dict[str, object] | None:
    rows = render_markdown(markdown, width)
    row = choose_hover(rows, positive, rng)
    if row is None:
        return None
    context = cut_context(rows, row)
    if context is None:
        return None
    return context_record(
        session=session,
        source=source,
        context=context,
        width=width,
        user=user,
        ask=ask,
        label=label,
    )


def _pi_texts(root: Path, rng: random.Random, limit: int):
    files = sorted(root.rglob("*.jsonl"))
    rng.shuffle(files)
    per_session: dict[str, int] = {}
    count = 0
    for path in files:
        session = path.stem
        try:
            with path.open(encoding="utf-8", errors="replace") as handle:
                for raw in handle:
                    if count >= limit:
                        return
                    if '"message"' not in raw and '"type":"session"' not in raw:
                        continue
                    try:
                        item = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if item.get("type") == "session" and isinstance(item.get("id"), str):
                        session = item["id"]
                    if per_session.get(session, 0) >= 2:
                        break
                    message = item.get("message")
                    if item.get("type") != "message" or not isinstance(message, dict):
                        continue
                    if message.get("role") != "assistant":
                        continue
                    content = message.get("content")
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "text":
                            continue
                        text = block.get("text")
                        if not isinstance(text, str) or len(text) < 300:
                            continue
                        if per_session.get(session, 0) >= 2:
                            continue
                        per_session[session] = per_session.get(session, 0) + 1
                        count += 1
                        yield session, "pi", text
        except OSError:
            continue


def _claude_texts(root: Path, rng: random.Random, limit: int):
    files = sorted(root.rglob("*.jsonl"))
    rng.shuffle(files)
    per_session: dict[str, int] = {}
    count = 0
    for path in files:
        session = path.stem
        try:
            with path.open(encoding="utf-8", errors="replace") as handle:
                for raw in handle:
                    if count >= limit:
                        return
                    if '"assistant"' not in raw and '"sessionId"' not in raw:
                        continue
                    try:
                        item = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(item.get("sessionId"), str):
                        session = item["sessionId"]
                    if per_session.get(session, 0) >= 2:
                        break
                    message = item.get("message")
                    if item.get("type") != "assistant" or not isinstance(message, dict):
                        continue
                    content = message.get("content")
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "text":
                            text = block.get("text")
                            if not isinstance(text, str) or len(text) < 300:
                                continue
                            if per_session.get(session, 0) >= 2:
                                continue
                            per_session[session] = per_session.get(session, 0) + 1
                            count += 1
                            yield session, "claude", text
        except OSError:
            continue


def _claude_asks(root: Path):
    files = sorted(root.rglob("*.jsonl"))
    for path in files:
        session = path.stem
        try:
            with path.open(encoding="utf-8", errors="replace") as handle:
                for raw in handle:
                    try:
                        item = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(item.get("sessionId"), str):
                        session = item["sessionId"]
                    message = item.get("message")
                    if item.get("type") != "assistant" or not isinstance(message, dict):
                        continue
                    content = message.get("content")
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if (
                            block.get("type") != "tool_use"
                            or block.get("name") != "AskUserQuestion"
                        ):
                            continue
                        payload = block.get("input")
                        if not isinstance(payload, dict):
                            continue
                        questions = payload.get("questions")
                        if not isinstance(questions, list):
                            continue
                        for question in questions:
                            if not isinstance(question, dict):
                                continue
                            text = question.get("question")
                            options = question.get("options")
                            if not isinstance(text, str) or not isinstance(options, list):
                                continue
                            labels = [
                                option["label"]
                                for option in options
                                if isinstance(option, dict) and isinstance(option.get("label"), str)
                            ]
                            if labels:
                                yield session, text, labels
        except OSError:
            continue


def build_dataset(
    root: Path, output: Path, user: str, *, total: int = TARGET_CONTEXTS
) -> dict[str, int]:
    rng = random.Random(SEED)
    asks = list(_claude_asks(root / ".claude" / "projects"))
    ask_records: list[dict[str, object]] = []
    for ask_index, (session, question, labels) in enumerate(asks):
        width = sample_width(rng)
        record = _candidate_context(
            render_ask(question, labels),
            session,
            "ask",
            True,
            width,
            rng,
            user,
            ask={"question": question, "labels": labels},
        )
        if record is not None:
            ask_records.append(record)
        if ask_index >= 99:
            break

    target = max(total, len(ask_records) + 20)
    positive_text = max(0, target // 2 - len(ask_records))
    negative_text = target - len(ask_records) - positive_text

    candidates: dict[str, list[tuple[str, str, str]]] = {"positive": [], "negative": []}
    pi_root = root / ".pi" / "agent" / "sessions"
    for session, source, text in _pi_texts(pi_root, rng, 8000):
        kind = "positive" if "?" in text[-300:] else "negative"
        candidates[kind].append((session, source, text))
    claude_root = root / ".claude" / "projects"
    for session, source, text in _claude_texts(claude_root, rng, 2500):
        kind = "positive" if "?" in text[-300:] else "negative"
        candidates[kind].append((session, source, text))

    records: list[dict[str, object]] = []
    for kind, wanted in (("positive", positive_text), ("negative", negative_text)):
        pool = candidates[kind]
        rng.shuffle(pool)
        taken = 0
        for session, source, text in pool:
            if taken >= wanted:
                break
            record = _candidate_context(
                text, session, source, kind == "positive", sample_width(rng), rng, user
            )
            if record is None:
                continue
            records.append(record)
            taken += 1

    records.extend(ask_records)
    records.sort(key=lambda item: str(item["id"]))
    write_jsonl(output, records)

    def count(kind: str) -> int:
        return sum(1 for record in records if record["source"] == kind)

    positive = sum(
        1
        for record in records
        if record["source"] == "ask"
        or any(
            "?" in str(record["lines"][index]["text"])
            for index in range(
                int(record["ranges"][int(record["hovered"])][0]),
                int(record["ranges"][int(record["hovered"])][1]) + 1,
            )
        )
    )
    return {
        "contexts": len(records),
        "pi": count("pi"),
        "claude": count("claude"),
        "ask": count("ask"),
        "ask_calls": len(asks),
        "positive": positive,
        "negative": len(records) - positive,
        "sessions": len({str(record["session"]) for record in records}),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home())
    parser.add_argument("--output", type=Path, default=Path("data/contexts.jsonl"))
    parser.add_argument("--user", default=__import__("getpass").getuser())
    parser.add_argument("--total", type=int, default=TARGET_CONTEXTS)
    args = parser.parse_args(argv)
    counts = build_dataset(args.root, args.output, args.user, total=args.total)
    print(json.dumps(counts, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
