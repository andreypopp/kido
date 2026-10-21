"""The labelling prompt for questions in agent text, its validator, and one labelled text.

The labeller sees the text as numbered segments (the splitter's cuts) and answers with segment
indexes, the first three words of the first segment and the options as exact substrings.
"""

from __future__ import annotations

import hashlib
import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from openai import OpenAI

from deepseek import MAX_TOKENS, MODEL, Spend, complete, now, parse_response
from redact import redact
from segments import BLANK, LIST_ITEM, Segment, segments

CHOICE, YES_NO, OPEN = "choice", "yes_no", "open"
KINDS = (CHOICE, YES_NO, OPEN)
MIN_OPTION = 3
WORDS = 3
LENGTH = "finish reason length"


@dataclass(frozen=True)
class Question:
    start: int
    end: int
    kind: str
    options: tuple[str, ...]
    first: int  # segment indexes from 0, both included
    last: int


def view(text: str) -> str:
    """One numbered segment per entry, numbers from 1; a blank segment is an empty entry.
    A segment that spans rows keeps its row breaks and indents."""
    return "\n".join(
        f"{number}: {text[s.start : s.end]}".rstrip() for number, s in enumerate(segments(text), 1)
    )


def first_words(segment: str) -> str:
    return " ".join(segment.split()[:WORDS])


def entry(label: dict[str, object]) -> str:
    return json.dumps(label, ensure_ascii=False)


def example(text: str, questions: list[dict[str, object]]) -> str:
    return f"Text:\n{view(text)}\nAnswer: {entry({'questions': questions})}"


def question_item(
    text: str, first: int, last: int, kind: str, options: list[str] | None = None
) -> dict[str, object]:
    """A label item for segments first..last (numbers from 1); words come from the text."""
    head = segments(text)[first - 1]
    return {
        "first": first,
        "last": last,
        "words": first_words(text[head.start : head.end]),
        "kind": kind,
        "options": options or [],
    }


def span(cuts: list[Segment], first: int, last: int) -> tuple[int, int]:
    """The character range of segments first..last, numbers from 1."""
    return cuts[first - 1].start, cuts[last - 1].end


RULES: list[tuple[str, str, list[tuple[int, int, str, list[str]]]]] = [
    (
        "A numbered list of questions is several questions, one for each item.",
        "I have two questions.\n1. Should I update the docs?\n2. What should the name be?",
        [(2, 2, YES_NO, []), (3, 3, OPEN, [])],
    ),
    (
        "A question with a list of numbered options is one question, from the question to the "
        "last option.",
        "Which branch do you want?\n1. main\n2. develop",
        [(1, 3, CHOICE, ["main", "develop"])],
    ),
    (
        "A question can have more than one sentence. The sentences before it that belong to it "
        "are part of the question.",
        "I see two ways to fix it. Which one do you want?",
        [(1, 2, OPEN, [])],
    ),
    (
        "A question can come after its options. It starts at the first segment that belongs to it.",
        "There are two ways:\n- update the docs\n- keep the change\nWhich one do you want?",
        [(1, 4, CHOICE, ["update the docs", "keep the change"])],
    ),
    (
        'Inline options: the option is the noun phrase after "or" or the list word, without the '
        "verb that the options share.",
        "Should I update the docs or keep the change?",
        [(1, 1, CHOICE, ["update the docs", "keep the change"])],
    ),
    (
        'A yes/no question has no options. Words like "y/n" or "yes or no" are not options.',
        "Should I run the tests now? Reply y/n.",
        [(1, 1, YES_NO, [])],
    ),
    (
        "These are not questions: a rhetorical question, a question that the agent answers "
        "itself, a question quoted from the user or from a document, a question in code or a log.",
        'Why does this matter? Because the cache is shared.\nThe user asked: "Is it fast?"\n'
        "```\n$ grep -r 'why?' src\n```",
        [],
    ),
]
EXAMPLES = [
    (rule, text, [question_item(text, *spec) for spec in specs]) for rule, text, specs in RULES
]


def instructions() -> str:
    parts = [
        "You find the questions that a coding agent asks the user, in one message of the agent.",
        "The message is plain terminal text cut into numbered segments: sentences, list items, "
        "code rows, table rows and blank rows. A sentence or a list item that spans several rows "
        "is one segment and keeps its row breaks and indents. Numbers start at 1. A blank row "
        "is an empty numbered entry. Return JSON only, in this shape:",
        entry(
            {
                "questions": [
                    {
                        "first": 1,
                        "last": 3,
                        "words": "the first three words of segment first",
                        "kind": "|".join(KINDS),
                        "options": ["exact text", "exact text"],
                    }
                ]
            }
        ),
        "A question needs an answer from the user. List the questions in text order; they do "
        'not overlap. "first" and "last" are the numbers of the first and the last segment '
        'of the question. Both segments are not blank. "words" is the first three words of '
        'segment "first" (all of them if it has fewer), copied exactly; it checks your number.',
        f'"kind" is "{CHOICE}" (the user picks between options that the text names; "options" '
        f'has them), "{YES_NO}" (the user answers yes or no) or "{OPEN}" (there is no '
        f'finite answer, as in "What should the name be?"). Only "{CHOICE}" has options.',
        '"options" are copies of text inside the question, character for character: no list '
        f"marker, no trailing full stop, inner punctuation kept, at least {MIN_OPTION} "
        "characters, no duplicates, each one occurring once in the question. A list item gives "
        "one option.",
        'If the text has no question, return {"questions": []}.',
        "Rules, each with an example:",
    ]
    for rule, text, questions in EXAMPLES:
        parts.append(f"\n{rule}\n{example(text, questions)}")
    return "\n".join(parts)


SYSTEM = instructions()
PROMPT_HASH = hashlib.sha256(SYSTEM.encode()).hexdigest()[:12]


def occurrences(text: str, part: str) -> int:
    """How many times part occurs in text, overlaps included."""
    count, at = 0, text.find(part)
    while at >= 0:
        count += 1
        at = text.find(part, at + 1)
    return count


def is_index(value: object, size: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= size


def label_errors(text: str, label: object) -> list[str]:
    if not isinstance(label, dict) or not isinstance(label.get("questions"), list):
        return ['the JSON needs a "questions" list']
    cuts = segments(text)
    errors: list[str] = []
    previous = 0
    for number, item in enumerate(label["questions"], start=1):
        where = f"question {number}"
        if not isinstance(item, dict):
            return [f"{where} is not an object"]
        first, last = item.get("first"), item.get("last")
        if not (is_index(first, len(cuts)) and is_index(last, len(cuts))):
            errors.append(f'{where}: "first" and "last" are segment numbers from 1 to {len(cuts)}')
            continue
        if first > last:  # type: ignore[operator]
            errors.append(f'{where}: "first" is after "last"')
            continue
        if first <= previous:  # type: ignore[operator]
            errors.append(f"{where} overlaps the question before it or is out of order")
            continue
        previous = last  # type: ignore[assignment]
        head, tail = cuts[first - 1], cuts[last - 1]  # type: ignore[operator]
        if head.kind == BLANK or tail.kind == BLANK:
            errors.append(f'{where}: "first" and "last" are not blank segments')
            continue
        if item.get("words") != first_words(text[head.start : head.end]):
            errors.append(f'{where}: "words" is not the start of segment {first}')
        kind, options = item.get("kind"), item.get("options")
        if kind not in KINDS:
            errors.append(f'{where}: "kind" is one of {", ".join(KINDS)}')
        if not isinstance(options, list) or not all(isinstance(o, str) for o in options):
            errors.append(f'{where}: "options" is a list of strings')
            continue
        if kind == CHOICE and not options:
            errors.append(f"{where} is a choice with no options")
        if kind in (YES_NO, OPEN) and options:
            errors.append(f"{where} is {kind} and has options")
        if len(set(options)) != len(options):
            errors.append(f"{where} has a duplicate option")
        question = text[slice(*span(cuts, first, last))]  # type: ignore[arg-type]
        for option in options:
            if len(option) < MIN_OPTION or option != option.strip() or option.endswith("."):
                errors.append(
                    f"{where}: option {option!r} is too short, padded or ends with a full stop"
                )
            elif LIST_ITEM.match(option):
                errors.append(f"{where}: option {option!r} starts with a list marker")
            elif occurrences(question, option) != 1:
                errors.append(f"{where}: option {option!r} is not in the question exactly once")
    return errors


def questions_of(text: str, label: dict[str, object]) -> list[Question]:
    """The labelled questions with their character ranges; the label must be valid."""
    cuts = segments(text)
    return [
        Question(
            *span(cuts, item["first"], item["last"]),  # type: ignore[index]
            item["kind"],  # type: ignore[index]
            tuple(item["options"]),  # type: ignore[index]
            item["first"] - 1,  # type: ignore[index]
            item["last"] - 1,  # type: ignore[index]
        )
        for item in label["questions"]  # type: ignore[attr-defined]
    ]


def canonical(label: dict[str, object]) -> tuple[tuple[object, ...], ...]:
    """What two samples must share to agree: ranges, kinds and option sets."""
    return tuple(
        (q["first"], q["last"], q["kind"], tuple(sorted(q["options"])))
        for q in label["questions"]  # type: ignore[attr-defined]
    )


def option_ranges(
    text: str, start: int, options: tuple[str, ...] | list[str]
) -> list[tuple[int, int]]:
    """The range of each option in text, found from the start of its question; each option
    occurs once in its question."""
    return [(text.find(o, start), text.find(o, start) + len(o)) for o in options]


def ordered_options(text: str, label: dict[str, object]) -> dict[str, object]:
    """The label with the options of each question in the order of the text."""
    cuts = segments(text)
    items = []
    for item in label["questions"]:  # type: ignore[attr-defined]
        start, _ = span(cuts, item["first"], item["last"])
        items.append(
            {**item, "options": sorted(item["options"], key=lambda o: text.find(o, start))}
        )
    return {"questions": items}


def label_text(
    client: OpenAI,
    text: str,
    *,
    spend: Spend,
    cache_dir: Path,
    stage: str,
    user: str,
    max_tokens: int = MAX_TOKENS,
    sample: int = 1,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], datetime] = now,
    allow_peak: bool = False,
    effort: str | None = None,
    model: str = MODEL,
) -> dict[str, object]:
    """{"label": ...} or {"errors": [...]}. A rejected label goes back once with its reasons;
    a stop on length is dropped at once."""
    if redact(text, user=user) != text:
        return {"errors": ["input is not redacted"]}
    prompt = f"Text:\n{view(text)}"
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]
    errors: list[str] = []
    raw = ""
    for attempt in range(2):
        payload = messages
        if errors:
            reasons = redact("; ".join(errors[:5]), user=user)
            payload = [
                *messages,
                {"role": "assistant", "content": redact(raw, user=user)},
                {"role": "user", "content": f"Your answer was rejected: {reasons}. Correct it."},
            ]
        raw, finish = complete(
            client,
            payload,
            spend=spend,
            cache_dir=cache_dir,
            stage=stage,
            nonce=f"{sample}:{attempt}",
            user=user,
            max_tokens=max_tokens,
            sleep=sleep,
            clock=clock,
            allow_peak=allow_peak,
            effort=effort,
            model=model,
        )
        if finish == "length":
            return {"errors": [LENGTH]}
        try:
            label = parse_response(raw)
        except json.JSONDecodeError as error:
            errors = [f"not JSON: {error}"]
            continue
        errors = label_errors(text, label)
        if not errors:
            return {"label": label}
    return {"errors": errors, "raw": raw}
