"""Generate template examples with exact labels, held out by template family."""

from __future__ import annotations

import argparse
import getpass
import json
import random
from dataclasses import dataclass
from pathlib import Path

from render import (
    MARKER,
    SEED,
    context_record,
    cut_context,
    family_digest,
    hash_records,
    logical_lines,
    partition_blocks,
    render_markdown,
    sample_width,
    write_jsonl,
)
from validate import is_positive, label_errors, option_kinds

NEGATIVE_KINDS = {
    "prose",
    "code",
    "diff",
    "log",
    "table",
    "stack",
    "shell",
    "steps",
    "files",
    "userq",
}
FILLERS = (
    "The build finished without errors.",
    "I checked the logs and the cache is warm.",
    "This paragraph is context from an earlier turn.",
    "The next paragraph is not part of the question.",
    "A short note about the current task.",
    "The test suite runs in a few seconds.",
    "Nothing changed in the last commit.",
    "The server restarted cleanly.",
    "The output is in the build directory.",
    "I read the diff twice and found no problem.",
    "The cache hit ratio is high today.",
    "The command exited with status zero.",
    "The staging deploy finished two minutes ago.",
    "The logs rotate every night.",
    "The new fixture passes on this machine.",
    "This section repeats the earlier summary.",
)


@dataclass(frozen=True)
class Family:
    id: str
    kind: str
    questions: tuple[str, ...] = ()
    option_sets: tuple[tuple[str, ...], ...] = ()
    markers: tuple[str, ...] = ("-",)
    blank: bool = False
    bold: bool = False
    indent: int = 0
    contents: tuple[str, ...] = ()


TRAIN_FAMILIES = (
    Family(
        "train-db",
        "list",
        questions=(
            "Which database should the service use?",
            "Pick a storage engine for the cache.",
            "Which queue should we add to the pipeline?",
        ),
        option_sets=(
            ("sqlite", "postgres", "duckdb"),
            ("redis", "memcached", "none"),
            ("rabbitmq", "nats", "sqs"),
        ),
        markers=("{n}.", "-", "•", "{n})"),
        blank=False,
        bold=True,
    ),
    Family(
        "train-color",
        "list",
        questions=(
            "Which color should the toolbar use?",
            "Pick a color for the new badge.",
        ),
        option_sets=(
            ("green", "amber", "slate"),
            ("teal", "violet", "stone"),
            ("blue", "orange"),
        ),
        markers=("*", "❯", "-"),
        blank=False,
        indent=2,
    ),
    Family(
        "train-mode",
        "list",
        questions=(
            "How should the upload run?",
            "Choose a mode for the migration.",
        ),
        option_sets=(
            ("sequential", "parallel", "batched"),
            ("dry run", "single pass", "retry on failure"),
        ),
        markers=("{n}.", "{a})", "-"),
        blank=False,
        bold=True,
    ),
    Family(
        "train-file",
        "list",
        questions=(
            "Which file should I change first?",
            "Which log should I open?",
        ),
        option_sets=(
            ("src/main.py", "src/render.py", "tests/test_render.py"),
            ("build.log", "test.log", "server.log"),
        ),
        markers=("-", "*", "[ ]"),
        blank=False,
    ),
    Family(
        "train-deploy",
        "list",
        questions=(
            "Where should the preview deploy run?",
            "Which region should the job use?",
        ),
        option_sets=(
            ("local", "staging", "production"),
            ("eu-west", "us-east", "ap-south"),
        ),
        markers=("{n})", "{n}.", "❯"),
        blank=False,
    ),
    Family(
        "train-loose",
        "list",
        questions=(
            "Which option looks right to you?",
            "Which of these should I keep?",
        ),
        option_sets=(
            ("the short report", "the long report"),
            ("the first draft", "the revised draft"),
        ),
        markers=("•", "❯", "[ ]", "{a})"),
        blank=True,
    ),
    Family(
        "train-lettered",
        "list",
        questions=(
            "Select a retry policy.",
            "Choose a timeout for the request.",
        ),
        option_sets=(
            ("no retry", "retry twice", "retry with backoff"),
            ("five seconds", "thirty seconds", "two minutes"),
        ),
        markers=("{a})", "{a}.", "-"),
        blank=False,
        indent=4,
    ),
    Family(
        "train-inline-one",
        "inline",
        questions=(
            "Should I use {a} or {b} for the build?",
            "Do you want {a} or {b}?",
            "Is the flag named {a} or {b}?",
        ),
        option_sets=(
            ("alpha", "beta"),
            ("the cache", "the fresh build"),
            ("quickly", "fast"),
        ),
    ),
    Family(
        "train-inline-two",
        "inline",
        questions=(
            "Should the report be {a} or {b}?",
            "Do we keep {a} or pick {b}?",
        ),
        option_sets=(
            ("long", "short"),
            ("the old name", "a new one"),
        ),
    ),
    Family(
        "train-plain",
        "plain",
        questions=(
            "What should I check next?",
            "Which failing test should I investigate?",
            "What would you like me to do now?",
        ),
    ),
    Family(
        "train-plain-two",
        "plain",
        questions=(
            "How should I verify the fix?",
            "Do you want me to continue?",
        ),
    ),
    Family(
        "train-box",
        "box",
        questions=(
            "Which mode should the editor start in?",
            "Choose a profile for the run.",
        ),
        option_sets=(
            ("insert", "normal", "visual"),
            ("debug", "release"),
        ),
        markers=("{n}.", "-", "•"),
    ),
    Family(
        "train-prose",
        "prose",
        contents=(
            "The launcher writes the config file and starts the server.",
            "The reader opens the file and parses each line in order.",
            "The cache is warm, so the next build takes a few seconds.",
        ),
    ),
    Family(
        "train-code",
        "code",
        contents=(
            "def add(left, right):\n    return left + right",
            "for item in values:\n    print(item)",
            "let result = items.map { $0 * 2 }",
        ),
    ),
    Family(
        "train-diff",
        "diff",
        contents=(
            "--- a/main.py\n+++ b/main.py\n@@ -1,2 +1,2 @@\n-before\n+after",
            "--- a/app.go\n+++ b/app.go\n@@ -8,3 +8,3 @@\n-old\n+new",
        ),
    ),
    Family(
        "train-log",
        "log",
        contents=(
            "09:00:00 INFO start\n09:00:01 INFO ready\n09:00:02 WARN retry",
            "2026-02-03T10:00:00Z INFO open\n2026-02-03T10:00:01Z WARN slow",
        ),
    ),
    Family(
        "train-table",
        "table",
        contents=(
            "| key | value |\n| --- | --- |\n| alpha | 3 |\n| beta | 5 |",
            "| step | time |\n| --- | --- |\n| build | 12s |\n| test | 4s |",
        ),
    ),
    Family(
        "train-stack",
        "stack",
        contents=(
            "Traceback (most recent call last):\n"
            "  File \"main.py\", line 3, in <module>\n"
            "ValueError: bad value",
            "error: thread panicked at src/main.rs:4:5\n"
            "note: run with RUST_BACKTRACE=1",
        ),
    ),
    Family(
        "train-shell",
        "shell",
        contents=(
            "$ make test\n$ make install",
            "$ git status\n$ git diff --stat",
        ),
    ),
    Family(
        "train-steps",
        "steps",
        contents=(
            "1. Open the settings page.\n2. Pick the cache folder.\n3. Restart the app.",
            "1. Stop the server.\n2. Remove the lock file.\n3. Start the server.",
        ),
    ),
    Family(
        "train-files",
        "files",
        contents=(
            "- src/main.py\n- src/render.py\n- tests/test_render.py",
            "- build/app\n- build/config.json",
        ),
    ),
    Family(
        "train-userq",
        "userq",
        contents=(
            "Where is the config file for the server?",
            "Can you run the tests one more time?",
        ),
    ),
)

EVAL_FAMILIES = (
    Family(
        "eval-pick-lang",
        "list",
        questions=(
            "Which language should the new CLI use?",
            "Pick a language for the helper script.",
        ),
        option_sets=(
            ("python", "swift", "rust"),
            ("bash", "python", "ocaml"),
        ),
        markers=("{n})", "{a})", "*"),
        blank=False,
        bold=True,
    ),
    Family(
        "eval-choose-path",
        "list",
        questions=(
            "Choose a location for the log file.",
            "Where should the export land?",
        ),
        option_sets=(
            ("inside the state directory", "beside the binary"),
            ("the desktop", "the downloads folder"),
        ),
        markers=("❯", "•", "[ ]"),
        blank=True,
    ),
    Family(
        "eval-inline",
        "inline",
        questions=(
            "Is {a} or {b} the right target?",
            "Should the badge be {a} or {b}?",
        ),
        option_sets=(
            ("the staging URL", "the local URL"),
            ("square", "round"),
        ),
    ),
    Family(
        "eval-plain",
        "plain",
        questions=(
            "What would you like me to run next?",
            "Which report should I read first?",
        ),
    ),
    Family(
        "eval-box",
        "box",
        questions=(
            "Select a retry policy for the job.",
            "Choose a window layout.",
        ),
        option_sets=(
            ("no retry", "retry once", "retry forever"),
            ("split", "stacked"),
        ),
        markers=("{n}.", "-"),
    ),
    Family(
        "eval-lettered",
        "list",
        questions=(
            "Pick a branch for the release.",
            "Which changelog entry should I keep?",
        ),
        option_sets=(
            ("the maintenance branch", "the feature branch"),
            ("the short entry", "the detailed entry", "both entries"),
        ),
        markers=("{a}.", "{a})"),
        blank=False,
        indent=2,
    ),
    Family(
        "eval-prose",
        "prose",
        contents=(
            "The renderer walks the syntax tree and writes one row for each paragraph.",
            "A short summary follows the diff and repeats the important parts.",
            "The cache keeps the compiled artifacts between runs.",
        ),
    ),
    Family(
        "eval-diff",
        "diff",
        contents=(
            "--- a/src/app.swift\n+++ b/src/app.swift\n@@ -4,3 +4,4 @@\n-old line\n+new line",
            "--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,2 @@\n-before\n+after",
        ),
    ),
    Family(
        "eval-log",
        "log",
        contents=(
            "12:00:01 INFO server started\n12:00:02 WARN cache miss\n12:00:03 INFO request done",
            "2026-01-01T09:00:00Z DEBUG connect\n2026-01-01T09:00:01Z ERROR timeout",
        ),
    ),
    Family(
        "eval-table",
        "table",
        contents=(
            "| name | value |\n| --- | --- |\n| alpha | 1 |\n| beta | 2 |",
            "| test | result |\n| --- | --- |\n| parser | pass |\n| renderer | pass |",
        ),
    ),
    Family(
        "eval-steps",
        "steps",
        contents=(
            "1. Run the build.\n2. Read the output.\n3. Fix the failure.",
            "1. Start the server.\n2. Open the page.\n3. Check the console.",
        ),
    ),
    Family(
        "eval-userq",
        "userq",
        contents=(
            "Which database should I use for the prototype?",
            "Can you check the failing test before lunch?",
        ),
    ),
)


def normalize(text: str) -> str:
    return " ".join(text.replace("**", "").split())


def marker_prefix(marker: str, index: int) -> str:
    if marker == "{n}.":
        return f"{index + 1}."
    if marker == "{n})":
        return f"{index + 1})"
    if marker == "{a})":
        return f"{chr(ord('a') + index)})"
    if marker == "{a}.":
        return f"{chr(ord('a') + index)}."
    return marker


def option_markdown(
    question: str,
    options: tuple[str, ...],
    marker: str,
    *,
    blank: bool,
    bold: bool,
    indent: int,
) -> str:
    rows = []
    for index, option in enumerate(options):
        text = f"**{option}**" if bold else option
        rows.append(" " * indent + marker_prefix(marker, index) + " " + text)
    listed = marker in ("-", "*", "{n}.", "{n})")
    if blank and not listed:
        separator = "\n\n"
    elif listed:
        separator = "\n"
    else:
        separator = "  \n"
    return question + "\n\n" + separator.join(rows)


def box_markdown(question: str) -> str:
    width = len(question) + 4
    return (
        "╭" + "─" * width + "╮\n"
        "│ " + question + " │\n"
        "╰" + "─" * width + "╯"
    )


def build_positive(
    rng: random.Random, family: Family
) -> tuple[str, str, tuple[str, ...]]:
    options = rng.choice(family.option_sets) if family.option_sets else ()
    question = rng.choice(family.questions)
    if family.kind == "inline":
        question = question.format(a=options[0], b=options[1])
    if family.kind == "list":
        marker = rng.choice(family.markers)
        unit = option_markdown(
            question,
            options,
            marker,
            blank=family.blank,
            bold=family.bold or rng.random() < 0.25,
            indent=family.indent,
        )
    elif family.kind == "box":
        marker = rng.choice(family.markers)
        unit = (
            box_markdown(question)
            + "\n\n"
            + option_markdown("", options, marker, blank=False, bold=False, indent=0)[2:]
        )
    else:
        unit = question
    before = "\n\n".join(rng.sample(FILLERS, rng.randint(1, 2)))
    after = "\n\n".join(rng.sample(FILLERS, rng.randint(1, 2)))
    return before + "\n\n" + unit + "\n\n" + after, question, options


def build_negative(rng: random.Random, family: Family) -> tuple[str, str]:
    content = rng.choice(family.contents)
    if family.kind == "diff":
        primary = "```diff\n" + content + "\n```"
        anchor = content.splitlines()[0]
    elif family.kind in ("code", "stack", "shell"):
        primary = "```\n" + content + "\n```"
        anchor = content.splitlines()[0]
    elif family.kind in ("log", "table", "steps", "files"):
        primary = content
        anchor = content.splitlines()[0]
    elif family.kind == "userq":
        primary = f"> **User:** {content}\n\nThe answer describes the two choices and the tradeoff."
        anchor = "The answer describes"
    else:
        primary = content
        anchor = content.splitlines()[0]
    before = "\n\n".join(rng.sample(FILLERS, rng.randint(1, 2)))
    after = "\n\n".join(rng.sample(FILLERS, rng.randint(1, 2)))
    return before + "\n\n" + primary + "\n\n" + after, anchor


def find_block(rows, anchor: str):
    blocks = partition_blocks(logical_lines(rows))
    wanted = normalize(anchor)
    for block in blocks:
        if wanted and wanted in normalize(block.text):
            return block
    raise RuntimeError(f"synthetic anchor not found: {anchor!r}")


def line_option(text: str, option: str) -> bool:
    stripped = MARKER.sub("", text).strip()
    return normalize(stripped).casefold() == normalize(option).casefold()


def make_example(
    rng: random.Random, family: Family, session: str
) -> dict[str, object]:
    options: tuple[str, ...] = ()
    inline = family.kind == "inline"
    positive = family.kind not in NEGATIVE_KINDS
    if positive:
        markdown, question, options = build_positive(rng, family)
        anchor = question
    else:
        markdown, anchor = build_negative(rng, family)
    width = sample_width(rng)
    rows = render_markdown(markdown, width)
    block = find_block(rows, anchor)
    context = cut_context(rows, block.lines[0].rows[0])
    if context is None:
        raise RuntimeError("synthetic context is empty")
    ranges = context.ranges
    hovered = context.hovered
    classes = ["other"] * len(context.lines)
    entries: list[dict[str, object]] = []
    if positive:
        for index in range(ranges[hovered][0], ranges[hovered][1] + 1):
            classes[index] = "question"
        if inline:
            line = ranges[hovered][0]
            for option in options:
                if str(context.lines[line].text).count(option) != 1:
                    raise RuntimeError(f"inline option not found once: {option!r}")
                entries.append({"line": line + 1, "text": option})
        else:
            cursor = ranges[hovered][1] + 1
            for option in options:
                found = None
                for index in range(cursor, len(context.lines)):
                    if line_option(str(context.lines[index].text), option):
                        found = index
                        break
                if found is None:
                    raise RuntimeError(f"list option not found: {option!r}")
                classes[found] = "option"
                entries.append({"line": found + 1, "text": option})
                cursor = found + 1
    label = {"lines": classes, "options": entries}
    record = context_record(
        session=session,
        source="synthetic",
        context=context,
        width=width,
        user=getpass.getuser(),
        label=label,
    )
    if record is None:
        raise RuntimeError("synthetic record is empty")
    errors = label_errors(str(record["prompt"]), record["label"])
    if errors:
        raise RuntimeError(f"synthetic label invalid: {errors[:3]}")
    return record


def generate(
    rng: random.Random, families: tuple[Family, ...], count: int, session: str
) -> tuple[list[dict[str, object]], int]:
    records: list[dict[str, object]] = []
    seen: set[str] = set()
    attempts = 0
    negatives = [family for family in families if family.kind in NEGATIVE_KINDS]
    positives = [family for family in families if family.kind not in NEGATIVE_KINDS]
    while len(records) < count and attempts < count * 8:
        attempts += 1
        if negatives and rng.random() < 0.5:
            family = rng.choice(negatives)
        else:
            family = rng.choice(positives)
        record = make_example(rng, family, f"synthetic-{session}-{attempts // 4}")
        digest = family_digest(str(record["prompt"]))
        if digest in seen:
            continue
        seen.add(digest)
        records.append(record)
    return records, attempts - len(records)


def build(
    output: Path,
    train_count: int = 6000,
    eval_count: int = 300,
    meta_path: Path | None = None,
) -> dict[str, int]:
    rng = random.Random(SEED)
    train, train_dropped = generate(rng, TRAIN_FAMILIES, train_count, "train")
    evaluation, eval_dropped = generate(rng, EVAL_FAMILIES, eval_count, "eval")
    write_jsonl(output / "train.jsonl", train)
    write_jsonl(output / "eval.jsonl", evaluation)
    meta = {
        "config": {
            "seed": SEED,
            "train_families": [family.id for family in TRAIN_FAMILIES],
            "eval_families": [family.id for family in EVAL_FAMILIES],
            "train_target": train_count,
            "eval_target": eval_count,
        },
        "hashes": {
            "train": hash_records(train),
            "eval": hash_records(evaluation),
        },
        "counts": {
            "train": len(train),
            "eval": len(evaluation),
            "train_duplicates": train_dropped,
            "eval_duplicates": eval_dropped,
            "train_positive": sum(1 for record in train if is_positive(record)),
            "eval_positive": sum(1 for record in evaluation if is_positive(record)),
            "train_option_spans": sum(
                len(record["label"]["options"]) for record in train
            ),
            "eval_option_spans": sum(
                len(record["label"]["options"]) for record in evaluation
            ),
            "train_option_kinds": {
                kind: sum(option_kinds(record)[kind] for record in train)
                for kind in ("list", "inline")
            },
            "eval_option_kinds": {
                kind: sum(option_kinds(record)[kind] for record in evaluation)
                for kind in ("list", "inline")
            },
        },
    }
    if meta_path is not None:
        meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    return meta["counts"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("data/synthetic"))
    parser.add_argument("--train-count", type=int, default=6000)
    parser.add_argument("--eval-count", type=int, default=300)
    args = parser.parse_args(argv)
    print(
        json.dumps(
            build(
                args.output,
                args.train_count,
                args.eval_count,
                Path("data/synthetic-meta.json"),
            ),
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
