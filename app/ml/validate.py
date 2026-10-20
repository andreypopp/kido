"""Validate labels and project them to exact character spans and BIO tags."""

from __future__ import annotations

from render import MARKER, character_count, prompt_lines

TAGS = ["O", "B-QUESTION", "I-QUESTION", "B-OPTION", "I-OPTION"]
TAG_IDS = {tag: index for index, tag in enumerate(TAGS)}
CLASSES = {"question", "option", "other"}


def _normalise(text: str) -> str:
    return " ".join(text.lower().split())


def schema_errors(raw: object) -> list[str]:
    if not isinstance(raw, dict):
        return ["label is not an object"]
    errors: list[str] = []
    lines = raw.get("lines")
    if not isinstance(lines, list):
        errors.append("lines is not a list")
    else:
        for index, value in enumerate(lines):
            if not isinstance(value, str) or value not in CLASSES:
                errors.append(f"line {index + 1}: bad class {value!r}")
    options = raw.get("options", [])
    if not isinstance(options, list):
        errors.append("options is not a list")
    else:
        for index, option in enumerate(options):
            if not isinstance(option, dict):
                errors.append(f"option {index + 1}: not an object")
                continue
            line = option.get("line")
            text = option.get("text")
            if not isinstance(line, int) or isinstance(line, bool):
                errors.append(f"option {index + 1}: line is not an integer")
            if not isinstance(text, str) or not text:
                errors.append(f"option {index + 1}: text is empty or not a string")
                continue
            if character_count(text) < 3:
                errors.append(f"option {index + 1}: shorter than 3 characters")
            if MARKER.match(text) or "**" in text:
                errors.append(f"option {index + 1}: contains a marker or bold markup")
    return errors


def label_errors(prompt: str, raw: object) -> list[str]:
    errors = schema_errors(raw)
    if errors:
        return errors
    assert isinstance(raw, dict)
    lines = prompt_lines(prompt)
    classes = raw["lines"]
    if len(classes) != len(lines):
        return [f"expected {len(lines)} line classes, got {len(classes)}"]
    options = raw.get("options", [])
    seen: set[str] = set()
    for option in options:
        normalised = _normalise(str(option["text"]))
        if normalised in seen:
            errors.append(f"option {option['text']!r}: duplicate")
        seen.add(normalised)
    unit = [index for index, value in enumerate(classes) if value != "other"]
    if unit:
        first, last = unit[0], unit[-1]
        for index in range(first, last + 1):
            if classes[index] == "other" and lines[index]["text"].strip():
                errors.append(f"line {index + 1}: unit is not contiguous")
        if "question" not in [classes[index] for index in unit]:
            errors.append("unit has no question line")
        option_lines = {index for index in unit if classes[index] == "option"}
        covered = {int(option["line"]) - 1 for option in options}
        if option_lines - covered:
            errors.append(f"option line {sorted(option_lines - covered)[0] + 1}: no exact option")
        for option in options:
            line = int(option["line"])
            if not 1 <= line <= len(lines):
                errors.append(f"option line {line}: out of range")
                continue
            if not first + 1 <= line <= last + 1:
                errors.append(f"option line {line}: not adjacent to the unit")
            text = lines[line - 1]["text"]
            if text.count(str(option["text"])) != 1:
                errors.append(
                    f"option line {line}: {option['text']!r} appears "
                    f"{text.count(str(option['text']))} times"
                )
    elif options:
        errors.append("options given without a question unit")
    return errors


def spans_from_label(prompt: str, raw: dict[str, object]) -> list[tuple[int, int, str]]:
    lines = prompt_lines(prompt)
    spans: list[tuple[int, int, str]] = []
    for index, value in enumerate(raw["lines"]):
        if value == "question":
            spans.append((int(lines[index]["start"]), int(lines[index]["end"]), "question"))
    for option in raw.get("options", []):
        line = int(option["line"])
        text = str(option["text"])
        start = int(lines[line - 1]["start"]) + int(lines[line - 1]["text"].index(text))
        spans.append((start, start + len(text), "option"))
    spans.sort()
    return spans


def strip_bold(
    prompt: str, spans: list[tuple[int, int, str]]
) -> tuple[str, list[tuple[int, int, str]]]:
    out: list[str] = []
    positions = [0] * (len(prompt) + 1)
    index = 0
    while index < len(prompt):
        positions[index] = len(out)
        if prompt.startswith("**", index):
            positions[index + 1] = len(out)
            positions[index + 2] = len(out)
            index += 2
        else:
            out.append(prompt[index])
            index += 1
            positions[index] = len(out)
    text = "".join(out)
    return text, [(positions[start], positions[end], value) for start, end, value in spans]


def example(record: dict[str, object], bold: bool) -> tuple[str, list[tuple[int, int, str]]]:
    prompt = str(record["prompt"])
    spans = spans_from_label(prompt, record["label"])
    return (prompt, spans) if bold else strip_bold(prompt, spans)


def bio(
    offsets: list[list[int]] | list[tuple[int, int]],
    spans: list[tuple[int, int, str]],
) -> list[int]:
    labels = [-100 if start == end else TAG_IDS["O"] for start, end in offsets]
    assigned: list[tuple[int, str] | None] = [None] * len(offsets)
    for span_index, (start, end, value) in enumerate(spans):
        for index, (token_start, token_end) in enumerate(offsets):
            if token_start == token_end or token_end <= start or token_start >= end:
                continue
            current = assigned[index]
            if current is None or (value == "option" and current[1] != "option"):
                assigned[index] = (span_index, value)
    previous: int | None = None
    for index, value in enumerate(assigned):
        if value is None:
            previous = None
            continue
        span_index, name = value
        prefix = "B" if span_index != previous else "I"
        labels[index] = TAG_IDS[f"{prefix}-{name.upper()}"]
        previous = span_index
    return labels


def tags_to_spans(tags: list[str], offsets: list[list[int]]) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    current: tuple[int, int, str] | None = None
    for tag, (start, end) in zip(tags, offsets, strict=True):
        if start == end or tag == "O":
            if current is not None:
                spans.append(current)
                current = None
            continue
        value = tag.split("-", 1)[1].lower()
        if tag.startswith("B-") or current is None or current[2] != value:
            if current is not None:
                spans.append(current)
            current = (start, end, value)
        else:
            current = (current[0], end, value)
    if current is not None:
        spans.append(current)
    return spans
