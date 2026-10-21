"""Template texts with exact labels, in both TUI layouts. Eval families share no stem, action,
topic or option set with the train families."""

from __future__ import annotations

import argparse
import getpass
import json
import random
import re
import sys
from dataclasses import dataclass

from corpus import WIDTH_MAX, WIDTH_MIN, candidates, is_positive
from jsonl import read_json, write_jsonl
from paths import PLAN, synthetic_path
from questions import CHOICE, OPEN, YES_NO, label_errors, question_item, span
from render import STYLES, render_text
from segments import SENTENCE, segments
from split import families, option_count

SEED = 7

VERBS = {
    "train": [
        "update",
        "run",
        "delete",
        "rebase",
        "bump",
        "clear",
        "restart",
        "squash",
        "pin",
        "split",
    ],
    "eval": ["rename", "regenerate", "drop", "archive", "merge", "revert", "inline", "skip"],
}
OBJECTS = {
    "train": [
        "the docs",
        "the tests",
        "the old branch",
        "the cache",
        "the server",
        "the changelog",
        "the lockfile",
        "the config",
        "the build",
        "the schema",
    ],
    "eval": [
        "the module",
        "the migration",
        "the logs",
        "the pull request",
        "the release",
        "the helper",
        "the linter",
        "the fixture",
    ],
}
ACTIONS = {
    group: [f"{verb} {thing}" for verb in VERBS[group] for thing in OBJECTS[group]]
    for group in VERBS
}
YES_NO_STEMS = {
    "train": ["Should I {a}?", "Do you want me to {a}?", "Is it OK to {a}?", "Can I {a}?"],
    "eval": ["Shall I {a}?", "Is it fine if I {a}?", "May I {a}?", "Want me to {a}?"],
}
THINGS = {
    "train": {
        "database": ["sqlite", "postgres", "duckdb", "mysql"],
        "cache": ["redis", "memcached", "none"],
        "region": ["eu-west-1", "us-east-2", "ap-south-1"],
        "color": ["green", "amber", "slate", "violet"],
        "mode": ["sequential", "parallel", "batched"],
        "branch": ["main", "develop", "release"],
    },
    "eval": {
        "queue": ["rabbitmq", "nats", "sqs", "kafka"],
        "format": ["json", "yaml", "toml"],
        "logger": ["structlog", "loguru", "stdlib"],
        "theme": ["solarized", "gruvbox", "nord"],
        "runner": ["pytest", "unittest", "nose"],
    },
}
CHOICE_STEMS = {
    "train": ["Which {t} should I use?", "Which {t} do you prefer?", "What {t} do you want?"],
    "eval": ["Which {t} would you pick?", "Which {t} fits best?", "What {t} should we go with?"],
}
OPEN_STEMS = {
    "train": [
        "What should the {t} be called?",
        "Where should I put the {t}?",
        "How long should the {t} wait?",
    ],
    "eval": [
        "What name do you prefer for the {t}?",
        "Where do you want the {t} to live?",
        "When should the {t} run?",
    ],
}
LEADS = {
    "train": ["There are two ways:", "I see these options:", "Here is what I found:"],
    "eval": ["Two choices come to mind:", "The candidates are:", "I could go either way:"],
}
NEGATIVE_KINDS = ("prose", "code", "log", "table", "steps", "files", "quote", "rhetorical", "diff")
MARKERS = ("-", "*", "1.")


@dataclass
class Gold:
    first: str
    last: str
    kind: str
    options: list[str]


def normal(text: str) -> str:
    return " ".join(text.split())


def listing(items: list[str], marker: str) -> str:
    return "\n".join(
        f"{n}. {i}" if marker == "1." else f"{marker} {i}" for n, i in enumerate(items, 1)
    )


class Maker:
    def __init__(self, group: str, fillers: list[str], rng: random.Random) -> None:
        self.group, self.fillers, self.rng = group, fillers, rng

    def action(self) -> str:
        return self.rng.choice(ACTIONS[self.group])

    def thing(self) -> tuple[str, list[str]]:
        name = self.rng.choice(sorted(THINGS[self.group]))
        options = THINGS[self.group][name]
        return name, self.rng.sample(options, self.rng.randint(2, len(options)))

    def yes_no(self) -> tuple[str, Gold]:
        text = self.rng.choice(YES_NO_STEMS[self.group]).format(a=self.action())
        return text, Gold(text, text, YES_NO, [])

    def open(self) -> tuple[str, Gold]:
        name, _ = self.thing()
        text = self.rng.choice(OPEN_STEMS[self.group]).format(t=name)
        return text, Gold(text, text, OPEN, [])

    def single(self) -> tuple[str, list[Gold]]:
        text, gold = self.rng.choice((self.yes_no, self.open))()
        if gold.kind == YES_NO and self.rng.random() < 0.3:
            text += " Reply y/n."
        return text, [gold]

    def inline(self) -> tuple[str, list[Gold]]:
        first, second = self.rng.sample(ACTIONS[self.group], 2)
        text = f"Should I {first} or {second}?"
        return text, [Gold(text, text, CHOICE, [first, second])]

    def listed(self) -> tuple[str, list[Gold]]:
        name, options = self.thing()
        stem = self.rng.choice(CHOICE_STEMS[self.group]).format(t=name)
        marker = self.rng.choice(MARKERS)
        gap = "\n\n" if self.rng.random() < 0.5 else "\n"
        lead = f"I see {len(options)} options. " if self.rng.random() < 0.3 else ""
        return f"{lead}{stem}{gap}{listing(options, marker)}", [
            Gold(lead.strip() or stem, options[-1], CHOICE, options)
        ]

    def after(self) -> tuple[str, list[Gold]]:
        name, options = self.thing()
        lead = self.rng.choice(LEADS[self.group])
        stem = self.rng.choice(CHOICE_STEMS[self.group]).format(t=name)
        marker = self.rng.choice(MARKERS)
        return f"{lead}\n{listing(options, marker)}\n\n{stem}", [Gold(lead, stem, CHOICE, options)]

    def numbered(self) -> tuple[str, list[Gold]]:
        pairs = [self.rng.choice((self.yes_no, self.open))() for _ in range(self.rng.randint(2, 3))]
        text = f"I have {len(pairs)} questions.\n" + listing([p for p, _ in pairs], "1.")
        return text, [Gold(g.first, g.last, g.kind, []) for _, g in pairs]

    def two(self) -> tuple[str, list[Gold]]:
        (a, ga), (b, gb) = self.yes_no(), self.open()
        glue = self.rng.choice((" ", "\n\n", "\n\n" + self.rng.choice(self.fillers) + "\n\n"))
        return a + glue + b, [ga, gb]

    FORMS = ("single", "inline", "listed", "after", "numbered", "two")

    def negative(self) -> str:
        kind = self.rng.choice(NEGATIVE_KINDS)
        filler = self.rng.choice
        if kind == "prose":
            return " ".join(filler(self.fillers) for _ in range(self.rng.randint(2, 4)))
        if kind == "code":
            return f"{filler(self.fillers)}\n\n```sh\n$ grep -r 'why?' src\n$ make test\n```"
        if kind == "log":
            return "```\n[12:01] WARN cache miss?\n[12:02] INFO retrying\n```\n\n" + filler(
                self.fillers
            )
        if kind == "table":
            return "| step | result? |\n|---|---|\n| build | ok |\n| test | slow |\n\n" + filler(
                self.fillers
            )
        if kind == "steps":
            steps = self.rng.sample(ACTIONS[self.group], 3)
            return "Steps:\n" + listing([s.capitalize() + "." for s in steps], "1.")
        if kind == "files":
            return "Files:\n" + listing(["src/main.py", "src/render.py", "tests/test_main.py"], "-")
        if kind == "quote":
            text, _ = self.yes_no()
            return f'You asked: "{text}" {filler(self.fillers)}'
        if kind == "rhetorical":
            return f"Why does this matter? Because {filler(self.fillers).lower()}"
        return "```diff\n- old line\n+ new line\n```\n\n" + filler(self.fillers)


def build(maker: Maker, rng: random.Random, user: str) -> dict[str, object] | str:
    """A record, or the reason the text was refused: "invalid" or "repeated"."""
    count = rng.choices([0, 1, 2, 3, 4], [0.25, 0.35, 0.2, 0.12, 0.08])[0]
    blocks: list[str] = []
    golds: list[Gold] = []
    forms: list[str] = []
    if count == 0:
        blocks.append(maker.negative())
        forms.append("negative")
    wanted = 0
    while wanted < count:
        form = rng.choice(Maker.FORMS)
        text, gold = getattr(maker, form)()
        if wanted + len(gold) > 4:
            continue
        wanted += len(gold)
        forms.append(form)
        if rng.random() < 0.5:
            blocks.append(rng.choice(maker.fillers))
        blocks.append(text)
        golds.extend(gold)
    if count and rng.random() < 0.3:
        blocks.append(maker.negative())
        forms.append("negative")
    source = rng.choice(("pi", "claude"))
    width = rng.randint(WIDTH_MIN, WIDTH_MAX)
    text = render_text("\n\n".join(blocks), width, STYLES[source], user)
    cuts = segments(text)
    shown = [normal(text[c.start : c.end]) for c in cuts]
    questions, cursor = [], 0
    for gold in golds:
        first = next((i for i in range(cursor, len(cuts)) if normal(gold.first) in shown[i]), None)
        last = (
            None
            if first is None
            else next((i for i in range(first, len(cuts)) if normal(gold.last) in shown[i]), None)
        )
        if first is None or last is None:
            return "invalid"
        cursor = last + 1
        questions.append(question_item(text, first + 1, last + 1, gold.kind, gold.options))
    label = {"questions": questions}
    if label_errors(text, label):
        return "invalid"
    spans = [normal(text[slice(*span(cuts, q["first"], q["last"]))]) for q in questions]  # type: ignore[arg-type]
    repeated = [re.sub(r"^\d+[.)]\s*", "", value) for value in spans]
    if len(set(repeated)) != len(repeated):
        return "repeated"
    return {
        "source": "synthetic",
        "layout": source,
        "width": width,
        "forms": forms,
        "shared_template": "inline" in forms or "negative" in forms,
        "text": text,
        "label": label,
    }


def fillers_from_train() -> list[str]:
    """Plain sentences of train-session texts that have no question."""
    out: set[str] = set()
    eval_sessions = set(read_json(PLAN)["eval_sessions"])  # type: ignore[arg-type]
    for record in candidates():
        if record["session"] in eval_sessions or is_positive(record):
            continue
        text = str(record["text"])
        for cut in segments(text):
            sentence = " ".join(text[cut.start : cut.end].split())
            if (
                cut.kind == SENTENCE
                and 40 <= len(sentence) <= 160
                and re.fullmatch(r"[A-Z][A-Za-z ,.'-]+\.", sentence)
            ):
                out.add(sentence)
    return sorted(out)


def generate(
    part: str, count: int, fillers: list[str], user: str
) -> tuple[list[dict[str, object]], dict[str, int]]:
    """count valid texts of a part, and how many texts were refused and why."""
    rng = random.Random(f"{SEED}:{part}")
    maker = Maker("eval" if part == "eval" else "train", fillers, rng)
    made: list[dict[str, object]] = []
    refused = {"invalid": 0, "repeated": 0}
    while len(made) < count:
        record = build(maker, rng, user)
        if isinstance(record, str):
            refused[record] += 1
            continue
        record["id"] = f"syn-{part}-{len(made):06d}"
        record["part"] = part
        made.append(record)
    return made, refused


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--train", type=int, default=900)
    parser.add_argument("--dev", type=int, default=150)
    parser.add_argument("--eval", type=int, default=300)
    args = parser.parse_args()
    user = getpass.getuser()
    fillers = fillers_from_train()
    sizes = {"eval": args.eval, "dev": args.dev, "train": args.train}
    made = {part: generate(part, count, fillers, user) for part, count in sizes.items()}
    everything = [r for part in sizes for r in made[part][0]]
    family = families(everything)
    report: dict[str, object] = {"fillers": len(fillers)}
    for part in sizes:
        records, refused = made[part]
        kept = [r for r in records if family[str(r["id"])] == str(r["id"])]
        write_jsonl(synthetic_path(part), kept)
        report[part] = {
            "texts": len(kept),
            "refused": refused,
            "shared_template": sum(bool(r["shared_template"]) for r in kept),
            "near_duplicate_rate": round(1 - len(kept) / len(records), 4),
            "multi_question": sum(len(r["label"]["questions"]) >= 2 for r in kept),  # type: ignore[index]
            "options": sum(option_count(r) for r in kept),
        }
    print(json.dumps(report))
    rate = max(report[p]["near_duplicate_rate"] for p in sizes)  # type: ignore[index]
    return 0 if rate < 0.1 else 1


if __name__ == "__main__":
    sys.exit(main())
