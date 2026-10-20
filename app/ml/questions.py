"""The labelling prompt for questions in agent text, its validator, and one labelled text."""

from __future__ import annotations

import hashlib
import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from openai import OpenAI

from deepseek import Spend, complete, parse_response
from redact import redact
from segments import LIST_ITEM, trimmed

KINDS = ("choice", "yes_no", "open")
MIN_OPTION = 3

SYSTEM = f"""You find the questions that a coding agent asks the user, in one message of the agent.
The message is plain terminal text. Rows may be cut in the middle of a sentence: a row break
inside a paragraph or a list item is only a line wrap. Return JSON only, in this shape:
{{"questions": [{{"question": "...", "kind": "{KINDS[0]}", "options": ["...", "..."]}}]}}

A question needs an answer from the user. List the questions in text order.

"question" is a copy of the text, character for character, with its row breaks and indents. It
runs from the first character of the question to the last. It includes the lead-in sentences that
belong to it, and its list of options.
- Two sentences: "I see two ways. Which one do you want?" is one question, from "I see".
- A question with a list: the question, the blank lines and every list item are one question.
- A question after its options: "Two ways:", the list items and "Which one?" are one question,
  and it starts at "Two ways:".
- A numbered list where every item is a question is several questions, one per item. A list of
  options for one question is one question.
- Two questions in one paragraph are two questions.
- A question that has no options is only its sentence or sentences.

"kind" is one of:
- "{KINDS[0]}": the user picks between options that the text names. "options" has them.
- "{KINDS[1]}": the user answers yes or no. "options" is []. Words like "y/n" or "yes or no" are not
  options.
- "{KINDS[2]}": there is no finite answer ("What should the name be?"). "options" is [].

"options" are copies of text inside "question", character for character:
- Without a list marker, without a trailing full stop, with inner punctuation kept.
- At least {MIN_OPTION} characters, no duplicates, each one appears once in "question".
- A list item gives one option.
- Inline options: the option is the noun phrase after "or" or the list word, without the verb
  that the options share. "Should I update the docs or keep the change?" gives "update the docs"
  and "keep the change".

These are not questions:
- A rhetorical question, or a question that the agent answers itself.
- A question that the agent quotes from the user, or from a document.
- A question inside a code block, a log, a table or a command output.
- A sentence that only has a question mark in a name or a path.
- A request without a question ("Let me know if you want it.").

If the text has no question, return {{"questions": []}}."""
PROMPT_HASH = hashlib.sha256(SYSTEM.encode()).hexdigest()[:12]


@dataclass(frozen=True)
class Question:
    start: int
    end: int
    kind: str
    options: tuple[str, ...]


def occurrences(text: str, part: str) -> int:
    """How many times part occurs in text, overlaps included."""
    count, at = 0, text.find(part)
    while at >= 0:
        count += 1
        at = text.find(part, at + 1)
    return count


def locate(text: str, questions: list[str]) -> list[int]:
    """The start of each question, searched in text order; -1 when one is missing."""
    cursor, starts = 0, []
    for question in questions:
        start = text.find(question, cursor)
        starts.append(start)
        if start >= 0:
            cursor = start + len(question)
    return starts


def label_errors(text: str, label: object) -> list[str]:
    if not isinstance(label, dict) or not isinstance(label.get("questions"), list):
        return ['the JSON needs a "questions" list']
    items = label["questions"]
    if not all(isinstance(item, dict) for item in items):
        return ["every question is an object"]
    errors: list[str] = []
    texts = [item.get("question") for item in items]
    valid = [isinstance(value, str) and bool(value.strip()) for value in texts]
    starts = iter(locate(text, [value for value, ok in zip(texts, valid, strict=True) if ok]))
    for number, (item, ok) in enumerate(zip(items, valid, strict=True), start=1):
        where = f"question {number}"
        if not ok:
            errors.append(f"{where} has no text")
            continue
        start = next(starts)
        question, kind, options = item["question"], item.get("kind"), item.get("options")
        if kind not in KINDS:
            errors.append(f'{where}: "kind" is one of {", ".join(KINDS)}')
        if not isinstance(options, list) or not all(isinstance(o, str) for o in options):
            errors.append(f'{where}: "options" is a list of strings')
            continue
        if start < 0:
            errors.append(
                f"{where} is not a copy of the text after the previous question"
                if question in text
                else f"{where} is not an exact copy of the text"
            )
            continue
        if kind == KINDS[0] and not options:
            errors.append(f"{where} is a choice with no options")
        if kind in KINDS[1:] and options:
            errors.append(f"{where} is {kind} and has options")
        if len(set(options)) != len(options):
            errors.append(f"{where} has a duplicate option")
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
    """The labelled questions with their trimmed character ranges; the label must be valid."""
    items = label["questions"]
    starts = locate(text, [item["question"] for item in items])  # type: ignore[index]
    return [
        Question(
            *trimmed(text, start, start + len(item["question"])),
            item["kind"],
            tuple(item["options"]),
        )
        for start, item in zip(starts, items, strict=True)  # type: ignore[arg-type]
    ]


def label_text(
    client: OpenAI,
    text: str,
    *,
    spend: Spend,
    cache_dir: Path,
    stage: str,
    user: str,
    thinking: bool = True,
    sample: int = 1,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, object]:
    """{"label": ...} or {"errors": [...]}. A rejected label goes back once with its reasons;
    a stop on length is dropped at once."""
    if redact(text, user=user) != text:
        return {"errors": ["input is not redacted"]}
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]
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
            thinking=thinking,
            sleep=sleep,
        )
        if finish == "length":
            return {"errors": ["finish reason length"]}
        try:
            label = parse_response(raw)
        except json.JSONDecodeError as error:
            errors = [f"not JSON: {error}"]
            continue
        errors = label_errors(text, label)
        if not errors:
            return {"label": label}
    return {"errors": errors, "raw": raw}
