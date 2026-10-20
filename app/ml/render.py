"""Render terminal-like markdown and cut paragraph contexts like Paragraphs.swift."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import random
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import regex
from markdown_it import MarkdownIt

GRAPHEME = regex.compile(r"\X")
MARKER = re.compile(
    r"^\s*(?:\[[ xX]\]\s*|[-*•❯]\s+|\d+[.)]\s+|[A-Za-z][.)]\s+)"
)
PROMPT_LINE = re.compile(r"^([ >]) (\d+): (.*)$")
SEED = 0
REDACTION_VERSION = 2
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
        raise FileNotFoundError(f"missing input: {path}")
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def write_jsonl(path: Path, records: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")


def read_json(path: Path) -> object | None:
    if not path.exists():
        return None
    return json.loads(path.read_text())


def file_hash(path: Path) -> str | None:
    if not path.exists():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hash_records(records: list[dict[str, object]], field: str = "prompt") -> str:
    digest = hashlib.sha256()
    for record in sorted(records, key=lambda item: str(item["id"])):
        digest.update(str(record["id"]).encode())
        digest.update(json.dumps(record.get(field), sort_keys=True).encode())
    return digest.hexdigest()


def normalized(prompt: str, hover: bool = False) -> str:
    values = []
    for line in prompt.splitlines():
        match = PROMPT_LINE.match(line)
        marker = match.group(1) if match else ""
        text = match.group(3) if match else line
        prefix = marker + " " if hover and match else ""
        values.append(prefix + " ".join(text.split()))
    return "\n".join(values)


def detached(prompt: str) -> str:
    values = []
    for line in prompt.splitlines():
        match = PROMPT_LINE.match(line)
        if match:
            values.append(" " + " " + match.group(2) + ": " + match.group(3))
        else:
            values.append(line)
    return "\n".join(values)


def family_digest(prompt: str) -> str:
    return hashlib.sha256(normalized(prompt).encode()).hexdigest()


def exact_digest(prompt: str) -> str:
    return hashlib.sha256(normalized(prompt, hover=True).encode()).hexdigest()


def block_text(record: dict[str, object], index: int) -> str:
    start, end = record["ranges"][index]
    return " ".join(
        str(record["lines"][line]["text"]) for line in range(start, end + 1)
    )


def hovered_text(record: dict[str, object]) -> str:
    return block_text(record, int(record["hovered"]))


def hover_question(record: dict[str, object]) -> bool:
    return "?" in hovered_text(record)


def part_of(record: dict[str, object]) -> str:
    return str(record.get("part") or record.get("source") or "real")


def variant(record: dict[str, object], index: int) -> dict[str, object]:
    lines = tuple(Line((0, 0), str(item["text"])) for item in record["lines"])
    ranges = [tuple(pair) for pair in record["ranges"]]
    prompt = format_prompt(lines, ranges, index)
    return {
        **record,
        "id": record_id(str(record["session"]), str(record["source"]), prompt),
        "prompt": prompt,
        "hovered": index,
    }


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



PI_POSITIVES = 1000
PI_NEGATIVES = 2000
CLAUDE_POSITIVES = 700
CLAUDE_NEGATIVES = 1200
SCAN_LIMIT = 20000
PER_SESSION = 10000
POSITIVE_PER_SESSION = 200
NEGATIVE_PER_SESSION = 15
MAX_VARIANTS = 3


def record_id(session: str, source: str, prompt: str) -> str:
    return hashlib.sha256(f"{session}\0{source}\0{prompt}".encode()).hexdigest()[:20]


def _context_id(prompt: str) -> str:
    return family_digest(prompt)


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
    identifier = record_id(session, source, redacted.prompt)
    record: dict[str, object] = {
        "id": identifier,
        "session": session,
        "source": source,
        "context_id": _context_id(redacted.prompt),
        "prompt": redacted.prompt,
        "lines": prompt_lines(redacted.prompt),
        "hovered": redacted.hovered,
        "ranges": [list(pair) for pair in redacted.ranges],
        "width": width,
    }
    if ask is not None:
        record["ask"] = ask
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


def option_like(record: dict[str, object]) -> bool:
    ranges = record["ranges"]
    hovered = int(record["hovered"])
    text = block_text(record, hovered)
    if "?" in text or " or " in text or text.rstrip().endswith(":"):
        return True
    if hovered + 1 < len(ranges):
        following = str(record["lines"][ranges[hovered + 1][0]]["text"])
        return bool(MARKER.match(following)) or bool(re.match(r"^\s*\[[ xX]\]", following))
    return False


def hard_negative(record: dict[str, object]) -> bool:
    for line in record["lines"]:
        text = str(line["text"])
        if MARKER.match(text) or text.startswith("| ") or text.startswith("  "):
            return True
    return False


def derive_variants(
    record: dict[str, object], rng: random.Random, maximum: int = MAX_VARIANTS
) -> list[dict[str, object]]:
    ranges = [tuple(pair) for pair in record["ranges"]]
    hovered = int(record["hovered"])
    preferred: list[int] = []
    others: list[int] = []
    for index in range(len(ranges)):
        text = block_text(record, index)
        following = ""
        if index + 1 < len(ranges):
            following = str(record["lines"][ranges[index + 1][0]]["text"])
        if "?" in text or " or " in text or MARKER.match(following):
            preferred.append(index)
        else:
            others.append(index)
    rng.shuffle(preferred)
    rng.shuffle(others)
    order = [hovered]
    order += [index for index in preferred if index != hovered]
    order += [index for index in others if index != hovered]
    order = order[:maximum]
    return [
        {**variant(record, index), "variant": position}
        for position, index in enumerate(order)
    ]


def _pi_texts(
    root: Path, rng: random.Random, *, per_session: int = PER_SESSION, limit: int = SCAN_LIMIT
):
    files = sorted(root.rglob("*.jsonl"))
    rng.shuffle(files)
    counts: dict[str, int] = {}
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
                    if counts.get(session, 0) >= per_session:
                        continue
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
                        if counts.get(session, 0) >= per_session:
                            break
                        counts[session] = counts.get(session, 0) + 1
                        count += 1
                        yield session, "pi", text
        except OSError:
            continue


def _claude_texts(
    root: Path, rng: random.Random, *, per_session: int = PER_SESSION, limit: int = SCAN_LIMIT
):
    files = sorted(root.rglob("*.jsonl"))
    rng.shuffle(files)
    counts: dict[str, int] = {}
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
                    if counts.get(session, 0) >= per_session:
                        continue
                    message = item.get("message")
                    if item.get("type") != "assistant" or not isinstance(message, dict):
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
                        if counts.get(session, 0) >= per_session:
                            break
                        counts[session] = counts.get(session, 0) + 1
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
                                if isinstance(option, dict)
                                and isinstance(option.get("label"), str)
                            ]
                            if labels:
                                yield session, text, labels
        except OSError:
            continue


def _take(
    pool: list[tuple[str, str, str]],
    quota: int,
    positive: bool,
    rng: random.Random,
    user: str,
    prefer,
    prefer_quota: int,
    per_session: int,
) -> list[dict[str, object]]:
    used: set[int] = set()
    taken: list[dict[str, object]] = []
    counts: dict[str, int] = {}
    if prefer_quota > 0:
        for index, (session, source, text) in enumerate(pool):
            if len(taken) >= prefer_quota:
                break
            if counts.get(session, 0) >= per_session:
                continue
            record = _candidate_context(
                text, session, source, positive, sample_width(rng), rng, user
            )
            if record is not None and prefer(record):
                taken.append(record)
                used.add(index)
                counts[session] = counts.get(session, 0) + 1
    for index, (session, source, text) in enumerate(pool):
        if len(taken) >= quota:
            break
        if index in used:
            continue
        if counts.get(session, 0) >= per_session:
            continue
        record = _candidate_context(
            text, session, source, positive, sample_width(rng), rng, user
        )
        if record is not None:
            taken.append(record)
            counts[session] = counts.get(session, 0) + 1
    return taken


def _pool(pool: list[tuple[str, str, str]], positive: bool, rng: random.Random):
    values = [
        entry
        for entry in pool
        if ("?" in entry[2][-300:]) is positive
    ]
    rng.shuffle(values)
    return values


def build_dataset(
    root: Path,
    output: Path,
    user: str,
    *,
    quota_scale: float = 1.0,
    scan_limit: int = SCAN_LIMIT,
    per_session: int = PER_SESSION,
) -> dict[str, int]:
    rng = random.Random(SEED)
    claude_root = root / ".claude" / "projects"

    ask_records: list[dict[str, object]] = []
    for session, question, labels in _claude_asks(claude_root):
        width = sample_width(rng)
        rows = render_markdown(render_ask(question, labels), width)
        blocks = partition_blocks(logical_lines(rows))
        if not blocks:
            continue
        context = cut_context(rows, blocks[0].lines[0].rows[0])
        if context is None:
            continue
        record = context_record(
            session=session,
            source="ask",
            context=context,
            width=width,
            user=user,
            ask={"question": question, "labels": labels},
        )
        if record is not None:
            ask_records.append(record)

    pi_pool = list(
        _pi_texts(
            root / ".pi" / "agent" / "sessions",
            rng,
            per_session=per_session,
            limit=scan_limit,
        )
    )
    claude_pool = list(_claude_texts(claude_root, rng, per_session=per_session, limit=scan_limit))

    contexts: list[dict[str, object]] = []
    for pool, positives, negatives in (
        (pi_pool, PI_POSITIVES, PI_NEGATIVES),
        (claude_pool, CLAUDE_POSITIVES, CLAUDE_NEGATIVES),
    ):
        positives = int(positives * quota_scale)
        negatives = int(negatives * quota_scale)
        contexts += _take(
            _pool(pool, True, rng),
            positives,
            True,
            rng,
            user,
            option_like,
            positives // 2,
            POSITIVE_PER_SESSION,
        )
        contexts += _take(
            _pool(pool, False, rng),
            negatives,
            False,
            rng,
            user,
            hard_negative,
            negatives // 2,
            NEGATIVE_PER_SESSION,
        )

    records: list[dict[str, object]] = list(ask_records)
    for record in contexts:
        records.extend(derive_variants(record, rng))
    records.sort(key=lambda item: str(item["id"]))
    write_jsonl(output, records)

    def count(kind: str) -> int:
        return sum(1 for record in records if record["source"] == kind)

    return {
        "examples": len(records),
        "contexts": len({str(record["context_id"]) for record in records}),
        "labelled_contexts": len(contexts) + len(ask_records),
        "pi": count("pi"),
        "claude": count("claude"),
        "ask": count("ask"),
        "ask_calls": len(ask_records),
        "hover_question": sum(1 for record in records if hover_question(record)),
        "hover_other": sum(1 for record in records if not hover_question(record)),
        "sessions": len({str(record["session"]) for record in records}),
        "hash": hash_records(records),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home())
    parser.add_argument("--output", type=Path, default=Path("data/contexts.jsonl"))
    parser.add_argument("--user", default=getpass.getuser())
    parser.add_argument("--quota-scale", type=float, default=1.0)
    parser.add_argument("--scan-limit", type=int, default=SCAN_LIMIT)
    parser.add_argument("--per-session", type=int, default=PER_SESSION)
    args = parser.parse_args(argv)
    counts = build_dataset(
        args.root,
        args.output,
        args.user,
        quota_scale=args.quota_scale,
        scan_limit=args.scan_limit,
        per_session=args.per_session,
    )
    meta = {
        "config": {
            "seed": SEED,
            "width_min": WIDTH_MIN,
            "width_max": WIDTH_MAX,
            "context_before": CONTEXT_BEFORE,
            "context_after": CONTEXT_AFTER,
            "line_limit": LINE_LIMIT,
            "character_limit": CHARACTER_LIMIT,
            "scan_limit": args.scan_limit,
            "per_session": args.per_session,
            "max_variants": MAX_VARIANTS,
            "pi_positives": PI_POSITIVES,
            "pi_negatives": PI_NEGATIVES,
            "claude_positives": CLAUDE_POSITIVES,
            "claude_negatives": CLAUDE_NEGATIVES,
            "quota_scale": args.quota_scale,
            "redaction": {"version": REDACTION_VERSION, "home": True, "user": True},
        },
        "counts": counts,
    }
    Path("data/render-meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(counts, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
