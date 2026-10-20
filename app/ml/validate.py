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


def units(classes: list[str], prompt: str) -> list[tuple[int, int]]:
    """Contiguous tagged runs. Blank lines may separate a question from its options."""
    lines = prompt_lines(prompt)
    runs: list[tuple[int, int]] = []
    first: int | None = None
    last: int | None = None
    for index, value in enumerate(classes):
        if value != "other":
            if first is None:
                first = index
            last = index
        elif first is not None and lines[index]["text"].strip():
            runs.append((first, last))
            first = None
            last = None
    if first is not None:
        runs.append((first, last))
    return runs


def label_errors(prompt: str, raw: object) -> list[str]:
    errors = schema_errors(raw)
    if errors:
        return errors
    assert isinstance(raw, dict)
    lines = prompt_lines(prompt)
    classes = raw["lines"]
    if len(classes) != len(lines):
        return [f"expected {len(lines)} line classes, got {len(classes)}"]
    runs = units(classes, prompt)
    options = raw.get("options", [])
    seen: set[str] = set()
    for option in options:
        normalised = _normalise(str(option["text"]))
        if normalised in seen:
            errors.append(f"option {option['text']!r}: duplicate")
        seen.add(normalised)
    covered: set[int] = set()
    for option in options:
        line = int(option["line"])
        if not 1 <= line <= len(lines):
            errors.append(f"option line {line}: out of range")
            continue
        index = line - 1
        owner = next((run for run in runs if run[0] <= index <= run[1]), None)
        if owner is None:
            errors.append(f"option line {line}: not adjacent to a question unit")
            continue
        if classes[index] not in ("option", "question"):
            errors.append(f"option line {line}: class is not option or question")
        covered.add(index)
        text = lines[index]["text"]
        if text.count(str(option["text"])) != 1:
            errors.append(
                f"option line {line}: {option['text']!r} appears "
                f"{text.count(str(option['text']))} times"
            )
    for run in runs:
        if "question" not in [classes[index] for index in range(run[0], run[1] + 1)]:
            errors.append(f"line {run[0] + 1}: unit has no question line")
        option_lines = {
            index
            for index in range(run[0], run[1] + 1)
            if classes[index] == "option"
        }
        missing = option_lines - covered
        if missing:
            errors.append(f"option line {sorted(missing)[0] + 1}: no exact option")
    if options and not runs:
        errors.append("options given without a question unit")
    return errors


def normalize_label(prompt: str, raw: object) -> tuple[object, int]:
    """Apply the option convention: list-marker lines are option, inline stays question."""
    if not isinstance(raw, dict) or not isinstance(raw.get("lines"), list):
        return raw, 0
    lines = prompt_lines(prompt)
    classes = list(raw["lines"])
    changed = 0
    for option in raw.get("options", []):
        if not isinstance(option, dict) or not isinstance(option.get("line"), int):
            continue
        index = int(option["line"]) - 1
        if not 0 <= index < len(classes) or index >= len(lines):
            continue
        wanted = "option" if MARKER.match(str(lines[index]["text"])) else "question"
        if classes[index] != wanted:
            classes[index] = wanted
            changed += 1
    return {"lines": classes, "options": raw.get("options", [])}, changed


def attach(
    record: dict[str, object], label: object
) -> tuple[dict[str, object] | None, int]:
    normalized, changed = normalize_label(str(record["prompt"]), label)
    if not isinstance(normalized, dict) or label_errors(
        str(record["prompt"]), normalized
    ):
        return None, changed
    return {**record, "label": normalized}, changed


def is_positive(record: dict[str, object]) -> bool:
    classes = record["label"]["lines"]
    start, end = record["ranges"][int(record["hovered"])]
    return any(classes[index] != "other" for index in range(start, end + 1))


def unit_from_classes(
    prompt: str,
    classes: list[str],
    ranges: list[list[int]],
    hovered: int,
) -> tuple[int, int] | None:
    start, end = ranges[hovered]
    tagged = [index for index in range(start, end + 1) if classes[index] != "other"]
    if not tagged:
        return None
    owner = next(run for run in units(classes, prompt) if run[0] <= tagged[0] <= run[1])
    in_ranges = [
        index
        for index in range(owner[0], owner[1] + 1)
        if classes[index] != "other"
        and any(pair[0] <= index <= pair[1] for pair in ranges)
    ]
    if not in_ranges:
        return None
    first, last = in_ranges[0], in_ranges[-1]
    low = next(index for index, pair in enumerate(ranges) if pair[0] <= first <= pair[1])
    high = next(index for index, pair in enumerate(ranges) if pair[0] <= last <= pair[1])
    return (ranges[low][0], ranges[high][1])


def option_kinds(record: dict[str, object]) -> dict[str, int]:
    lines = prompt_lines(str(record["prompt"]))
    kinds = {"list": 0, "inline": 0}
    for option in record["label"]["options"]:
        text = str(lines[int(option["line"]) - 1]["text"])
        kinds["list" if MARKER.match(text) else "inline"] += 1
    return kinds


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


def canonical_label(raw: object, prompt: str | None = None) -> object:
    if prompt is not None:
        raw, _ = normalize_label(prompt, raw)
    if not isinstance(raw, dict) or not isinstance(raw.get("lines"), list):
        return raw
    options = raw.get("options", [])
    if not isinstance(options, list):
        return raw
    values = sorted(
        (int(option["line"]), str(option["text"]))
        for option in options
        if isinstance(option, dict) and isinstance(option.get("line"), int)
    )
    return {"lines": list(raw["lines"]), "options": [list(value) for value in values]}


def rejection_class(errors: list[str]) -> str:
    if not errors:
        return "valid"
    text = errors[0]
    if text.startswith("samples disagree"):
        return "disagreement"
    if text.startswith("sample invalid"):
        return "sample_invalid"
    if text.startswith("not JSON") or text.startswith("label is not an object"):
        return "invalid_json"
    if "bad class" in text or "line classes" in text or "is not a list" in text:
        return "schema"
    if "shorter than" in text:
        return "option_too_short"
    if "marker or bold" in text:
        return "option_markup"
    if "duplicate" in text:
        return "duplicate_option"
    if "no exact option" in text or "appears" in text:
        return "missing_option"
    if "not adjacent" in text or "out of range" in text:
        return "option_placement"
    if "not contiguous" in text:
        return "non_contiguous"
    if "no question line" in text:
        return "no_question"
    if "without a question unit" in text:
        return "orphan_options"
    return "other"
