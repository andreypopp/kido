"""Label units with one DeepSeek call each: validation, one correction turn, sample agreement."""

import json
import threading
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from openai import APIError

from corpus import SPLITS, Row, samples
from deepseek import STOP_SPEND, BudgetExceeded, PeakHours, Session, complete
from jsonl import append_jsonl, read_jsonl, sha256
from tagging import Span
from units import ITEM, category

PROMPT = Path(__file__).parent / "unit_prompt.md"
KINDS = ("choice", "yes_no", "open")
MIN_OPTION = 3


@dataclass(frozen=True)
class Question:
    question: str
    kind: str
    options: tuple[str, ...]


@dataclass(frozen=True)
class Dropped:
    reason: str  # "length" or "invalid"


@dataclass(frozen=True)
class Prompt:
    text: str
    digest: str


def load_prompt() -> Prompt:
    text = PROMPT.read_text()
    return Prompt(text, sha256(text))


def occurrences(text: str, part: str) -> list[int]:
    """Where part occurs in text, also where occurrences overlap."""
    found, start = [], text.find(part)
    while start >= 0:
        found.append(start)
        start = text.find(part, start + 1)
    return found


def option_errors(number: int, question: str, options: list[str]) -> list[str]:
    errors, spans = [], []
    for option in options:
        where = occurrences(question, option)
        if len(option) < MIN_OPTION:
            errors.append(f"question {number}: an option is shorter than {MIN_OPTION} characters")
        elif option != option.strip() or option.endswith(".") or ITEM.match(option + " "):
            errors.append(
                f"question {number}: an option has an edge space, a full stop or a marker"
            )
        elif len(where) != 1:
            errors.append(f"question {number}: an option does not occur once in the question")
        else:
            spans.append((where[0], where[0] + len(option)))
    if len(set(options)) != len(options):
        errors.append(f"question {number}: duplicate options")
    spans.sort()
    if any(after[0] < before[1] for before, after in zip(spans, spans[1:], strict=False)):
        errors.append(f"question {number}: options overlap")
    return errors


def parse(unit: str, content: str) -> tuple[list[Question], list[str]]:
    """The questions of an answer, and the errors of the answer. The errors never quote it."""
    try:
        answer = json.loads(content)
        items = answer["questions"]
        if set(answer) != {"questions"} or not isinstance(items, list):
            raise ValueError
        questions = [
            Question(i["question"], i["kind"], tuple(i["options"]))
            for i in items
            if set(i) == {"question", "kind", "options"}
        ]
        if len(questions) != len(items) or not all(
            isinstance(q.question, str) and all(isinstance(o, str) for o in q.options)
            for q in questions
        ):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        return [], ["the answer does not have the shape of the schema"]
    errors, end = [], 0
    for number, q in enumerate(questions, 1):
        if q.kind not in KINDS:
            errors.append(f"question {number}: the kind is not choice, yes_no or open")
        elif (q.kind == "choice") != bool(q.options):
            errors.append(f"question {number}: only a choice has options, and it has them")
        where = occurrences(unit, q.question) if q.question else []
        if len(where) != 1:
            errors.append(f"question {number}: the text does not occur exactly once in the unit")
            continue
        if where[0] < end:
            errors.append(f"question {number}: not in text order, or overlaps the one before")
        end = max(end, where[0] + len(q.question))
        errors += option_errors(number, q.question, list(q.options))
    return ([] if errors else questions), errors


def label_unit(
    session: Session, prompt: Prompt, unit: str, nonce: str
) -> tuple[list[Question] | Dropped, bool]:
    """The questions of a unit, or why it was dropped; and whether a correction turn was needed."""
    messages = [
        {"role": "system", "content": prompt.text},
        {"role": "user", "content": f"Text: {unit}"},
    ]
    for turn in range(2):
        content, finish = complete(session, messages, nonce)
        if finish == "length":
            return Dropped("length"), turn == 1
        questions, errors = parse(unit, content)
        if not errors:
            return questions, turn == 1
        correction = "Errors in your answer:\n" + "\n".join(errors) + "\nAnswer again, as JSON."
        messages += [
            {"role": "assistant", "content": content},
            {"role": "user", "content": correction},
        ]
    return Dropped("invalid"), True


def canonical(questions: list[Question]) -> str:
    return json.dumps(
        [[q.question, q.kind, sorted(q.options, key=q.question.index)] for q in questions]
    )


def agreed(results: list[list[Question] | Dropped]) -> list[Question] | None:
    """The label that at least 2 of 3 samples give, else None."""
    votes = Counter(canonical(r) for r in results if not isinstance(r, Dropped))
    if not votes or votes.most_common(1)[0][1] < 2:
        return None
    best = votes.most_common(1)[0][0]
    return next(r for r in results if not isinstance(r, Dropped) and canonical(r) == best)


def label_row(session: Session, prompt: Prompt, row: Row) -> dict:
    """The record of a row. Its status is labelled, length, invalid or disagree."""
    outcomes = [label_unit(session, prompt, row.text, f"sample{n}") for n in range(samples(row))]
    results = [result for result, _ in outcomes]
    label = results[0] if len(results) == 1 else agreed(results)
    drops = [r.reason for r in results if isinstance(r, Dropped)]
    if isinstance(label, list):
        status = "labelled"
    elif isinstance(label, Dropped):
        status = label.reason
    else:
        status = "length" if "length" in drops else "disagree"
    questions = label if status == "labelled" else []
    return {
        "text": row.text,
        "status": status,
        "questions": [
            {"question": q.question, "kind": q.kind, "options": list(q.options)} for q in questions
        ],
        "prompt": prompt.digest,
        "corrections": sum(corrected for _, corrected in outcomes),
        "length_stops": drops.count("length"),
    }


def gold_of(record: dict) -> list[tuple[Span, tuple[Span, ...]]]:
    """(question span, option spans in the question) of a labelled record, in text order."""
    found = []
    for q in record["questions"]:
        start = record["text"].index(q["question"])
        options = tuple(
            sorted((q["question"].index(o), q["question"].index(o) + len(o)) for o in q["options"])
        )
        found.append(((start, start + len(q["question"])), options))
    return found


def load_labelled(
    path: Path, rows: list[Row], prompt: Prompt
) -> tuple[dict[str, list[dict]], dict[str, int]]:
    """The labelled records by split, and how many records were skipped. The split is the one of
    the frozen units. A record of a text that is no unit now, or of another prompt, is skipped."""
    split_of = {row.text: row.split for row in rows}
    labelled: dict[str, list[dict]] = {split: [] for split in SPLITS}
    skipped = {"not_a_unit": 0, "other_prompt": 0}
    for record in read_jsonl(path):
        if record["text"] not in split_of:
            skipped["not_a_unit"] += 1
        elif record["prompt"] != prompt.digest:
            skipped["other_prompt"] += 1
        elif record["status"] == "labelled" and category(record["text"]) != "other":
            labelled[split_of[record["text"]]].append(record)
    return labelled, skipped


def run(
    session: Session,
    prompt: Prompt,
    rows: list[Row],
    out: Path,
    workers: int = 8,
) -> dict[str, int]:
    """Label the rows that `out` does not have yet, appending a record for each. A budget, spend
    or peak stop ends the run, and an API error leaves its row for a rerun. Returns the count of
    each status."""
    done = {r["text"] for r in read_jsonl(out)}
    stop = threading.Event()
    errors: list[str] = []

    def work(row: Row) -> None:
        if session.ledger.total > STOP_SPEND:
            stop.set()
        if stop.is_set():
            return
        try:
            record = label_row(session, prompt, row)
        except (BudgetExceeded, PeakHours):
            stop.set()
            return
        except APIError:
            errors.append("error")
            return
        append_jsonl(out, record)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(work, [row for row in rows if row.text not in done]))
    records = read_jsonl(out)
    return dict(Counter(r["status"] for r in records)) | {
        "error": len(errors),
        "stopped": int(stop.is_set()),
    }
