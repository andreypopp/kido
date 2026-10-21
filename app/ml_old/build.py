"""Assemble the train, dev and eval files from the labels, and write the manifest.

`inspect` reports what an assembly would be, with its problems, and writes nothing. `publish`
refuses to write while there is a problem: a selected text without a label or a drop, a missing
part, a leak between the eval and the rest, or an empty train set. Every real label comes from
DeepSeek; no text gets an empty label by default. The manifest holds counts, hashes, settings
and spend, no text.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter

from corpus import candidates, is_multi_candidate
from deepseek import read_ledger
from jsonl import file_digest, read_jsonl, write_json, write_jsonl
from label import STAGES, stage_ids
from model import load_tokenizer
from paths import (
    ASK,
    LEDGER,
    MANIFEST,
    OLD_LEDGER,
    drops_path,
    labels_path,
    output_path,
    synthetic_path,
)
from questions import PROMPT_HASH
from segments import ITEM, segments
from select_texts import HARD, frozen
from split import assign_dev, families, is_multi, is_synthetic, option_count

OUTPUTS = ("train", "dev", "eval")

Record = dict[str, object]


def has_question(record: Record) -> bool:
    return bool(record["label"]["questions"])  # type: ignore[index]


def stats(records: list[Record]) -> dict[str, object]:
    questions = [q for r in records for q in r["label"]["questions"]]  # type: ignore[index]
    return {
        "texts": len(records),
        "with_question": sum(bool(r["label"]["questions"]) for r in records),  # type: ignore[index]
        "multi_question": sum(map(is_multi, records)),
        "questions": len(questions),
        "options": sum(map(option_count, records)),
        "kinds": dict(Counter(q["kind"] for q in questions)),
        "sessions": len({r["session"] for r in records if r.get("session")}),
    }


def boundary_screen(records: list[Record]) -> dict[str, int]:
    """Questions whose first segment has no question mark and is not a list item, a heading or
    a colon lead-in, and those among them with a question mark in a later segment. Their starts
    need a look before they count as exact gold."""
    found = later = 0
    texts: set[str] = set()
    for record in records:
        text, cuts = str(record["text"]), segments(str(record["text"]))
        for q in record["label"]["questions"]:  # type: ignore[index]
            head = text[cuts[q["first"] - 1].start : cuts[q["first"] - 1].end]
            if "?" in head or cuts[q["first"] - 1].kind == ITEM or head.startswith("#"):
                continue
            if head.endswith(":"):
                continue
            found += 1
            texts.add(str(record["id"]))
            later += any("?" in text[c.start : c.end] for c in cuts[q["first"] : q["last"]])
    return {"questions": found, "texts": len(texts), "with_later_question_mark": later}


def token_report(records: list[Record]) -> dict[str, object]:
    tokenizer = load_tokenizer()
    texts = [str(r["text"]) for r in records]
    sizes = sorted(len(ids) for ids in tokenizer(texts, add_special_tokens=True)["input_ids"])
    over = sum(size > 1024 for size in sizes)
    return {
        "p50": sizes[len(sizes) // 2],
        "p90": sizes[int(len(sizes) * 0.9)],
        "max": sizes[-1],
        "over_1024": over,
        "over_1024_share": round(over / len(sizes), 4),
    }


def stage_report(name: str, texts: dict[str, Record]) -> dict[str, object]:
    kept, dropped = read_jsonl(labels_path(name)), read_jsonl(drops_path(name))
    multi = {str(d["id"]) for d in dropped if is_multi_candidate(texts[str(d["id"])])}
    multi |= {str(k["id"]) for k in kept if is_multi_candidate(texts[str(k["id"])])}
    return {
        "decided": len(kept) + len(dropped),
        "kept": len(kept),
        "unanimous": sum(
            int(k["agree"]) == int(k["samples"]) == STAGES[name].samples for k in kept
        ),  # type: ignore[call-overload]
        "dropped": len(dropped),
        "drop_reasons": dict(Counter(str(d["reason"]) for d in dropped)),
        "multi_decided": len(multi),
        "multi_dropped": sum(str(d["id"]) in multi for d in dropped),
    }


def spend_report() -> dict[str, object]:
    first, _, _ = read_ledger([OLD_LEDGER])
    total, _, _ = read_ledger([OLD_LEDGER, LEDGER])
    _, stages, held = read_ledger([LEDGER])
    calls = Counter(
        str(i["stage"]) for i in read_jsonl(LEDGER) if "reserve" not in i and "cost" in i
    )
    return {
        "first_attempt": round(first, 4),
        "stages": {s: round(c, 4) for s, c in sorted(stages.items())},
        "unsettled": {s: round(c, 4) for s, c in sorted(held.items())},
        "calls": dict(calls),
        "total": round(total, 4),
    }


def assemble() -> tuple[dict[str, list[Record]], dict[str, object]]:
    plan, selection = frozen()
    eval_sessions = set(plan["eval_sessions"])  # type: ignore[call-overload]
    texts = {str(r["id"]): r for r in candidates()}
    problems: list[str] = []

    def labelled(name: str) -> list[Record]:
        kept = {str(k["id"]): k for k in read_jsonl(labels_path(name))}
        dropped = {str(d["id"]) for d in read_jsonl(drops_path(name))}
        wanted = stage_ids(name)
        missing = [i for i in wanted if i not in kept and i not in dropped]
        if missing:
            problems.append(f"{name}: {len(missing)} selected texts have no label or drop")
        if any(k["prompt"] != PROMPT_HASH for k in kept.values()):
            problems.append(f"{name}: labels from another prompt")
        return [
            {**texts[i], "label": kept[i]["label"], "agree": kept[i]["agree"]}
            for i in wanted
            if i in kept
        ]

    real_eval = [{**r, "part": "eval-real"} for r in labelled("eval-real")]
    checked = labelled("eval-negative")
    eval_negative = [{**r, "part": "eval-negative"} for r in checked if not has_question(r)]
    eval_noq = [{**r, "part": "eval-real-noq"} for r in checked if has_question(r)]
    train_real = [{**r, "part": "train", "pool": "positive"} for r in labelled("train-real")]
    train_negative = [
        {**r, "part": "train", "pool": "hard" if HARD.search(str(r["text"])) else "uniform"}
        for r in labelled("train-negative")
    ]
    sample = labelled("negative-sample")
    ask = [{**r, "part": "eval-ask"} for r in read_jsonl(ASK)]
    synthetic = {p: read_jsonl(synthetic_path(p)) for p in ("train", "dev", "eval")}
    for part, records in synthetic.items():
        if not records:
            problems.append(f"synthetic {part} is missing")
    held_out = real_eval + eval_negative + eval_noq + ask + synthetic["eval"]
    rest = synthetic["dev"] + train_real + train_negative + synthetic["train"]
    family = families(held_out + rest)
    eval_ids = {str(r["id"]) for r in held_out}

    def clear(records: list[Record]) -> list[Record]:
        return [r for r in records if family[str(r["id"])] not in eval_ids]

    copies = {
        "real": len(train_real + train_negative) - len(clear(train_real + train_negative)),
        "synthetic": sum(len(synthetic[p]) - len(clear(synthetic[p])) for p in ("train", "dev")),
    }
    synthetic_dev = clear(synthetic["dev"])
    dev_families = {family[str(r["id"])] for r in synthetic_dev}
    synthetic_train = [
        r for r in clear(synthetic["train"]) if family[str(r["id"])] not in dev_families
    ]
    real = clear(train_real + train_negative)
    dev_ids = assign_dev(real, family)
    dev = [{**r, "part": "dev"} for r in real if str(r["id"]) in dev_ids] + synthetic_dev
    train = [r for r in real if str(r["id"]) not in dev_ids] + synthetic_train
    train = [{**r, "split": "train"} for r in train]
    dev = [{**r, "split": "dev"} for r in dev]
    held_out = [{**r, "split": "eval"} for r in held_out]
    if not [r for r in train if not is_synthetic(r)]:
        problems.append("no real train text is left")
    leaks = {
        "train_sessions_in_eval": len(
            {str(r["session"]) for r in train + dev if r.get("session")} & eval_sessions
        ),
        "split_overlap": len({str(r["id"]) for r in train} & {str(r["id"]) for r in dev}),
        "train_dev_family": len(
            {family[str(r["id"])] for r in train} & {family[str(r["id"])] for r in dev}
        ),
        "eval_family_in_rest": sum(family[str(r["id"])] in eval_ids for r in train + dev),
    }
    if any(leaks.values()):
        problems.append(f"leaks: {leaks}")
    parts = {"train": train, "dev": dev, "eval": held_out}

    def real_only(records: list[Record]) -> list[Record]:
        return [r for r in records if not is_synthetic(r)]

    pools = {
        pool: {
            "labelled": sum(r["pool"] == pool for r in train_negative),
            "with_question": sum(r["pool"] == pool and has_question(r) for r in train_negative),
        }
        for pool in ("hard", "uniform")
    }
    manifest: dict[str, object] = {
        "prompt": PROMPT_HASH,
        "session_plan": {k: plan[k] for k in ("old_eval", "ask", "moved_to_train", "hash")}
        | {"eval_sessions": len(plan["eval_sessions"])},  # type: ignore[arg-type]
        "selection": selection["hashes"]
        | {
            k: selection[k]
            for k in ("train_dropped_as_eval_copies", "train_dropped_as_train_copies")
        },  # type: ignore[operator]
        "stages": {name: stage_report(name, texts) for name in STAGES},
        "negative_sample": {
            "labelled": len(sample),
            "with_question": sum(map(has_question, sample)),
            "rate": round(sum(map(has_question, sample)) / max(1, len(sample)), 4),
        },
        "train_negative_pools": pools,
        "dropped_as_eval_copies": copies,
        "parts": {
            "train_real": stats(real_only(train)),
            "train_synthetic": stats(synthetic_train),
            "dev_real": stats(real_only(dev)),
            "dev_synthetic": stats(synthetic_dev),
            "eval_real": stats(real_eval),
            "eval_real_multi_segments": sum(map(is_multi_candidate, real_eval)),
            "eval_real_multi_paragraphs": sum(
                int(r["question_paragraphs"]) >= 2 for r in real_eval
            ),  # type: ignore[call-overload]
            "eval_negative": stats(eval_negative),
            "eval_real_noq": stats(eval_noq),
            "eval_ask": stats(ask),
            "eval_synthetic": stats(synthetic["eval"])
            | {"shared_template": sum(bool(r["shared_template"]) for r in synthetic["eval"])},
        },
        "boundary_screen": {
            "train_real": boundary_screen(real_only(train)),
            "dev_real": boundary_screen(real_only(dev)),
            "eval_real": boundary_screen(real_eval),
            "eval_real_noq": boundary_screen(eval_noq),
            "eval_ask": boundary_screen(ask),
        },
        "tokens": {"eval_real": token_report(real_eval) if real_eval else None},
        "leaks": leaks,
        "spend": spend_report(),
        "problems": problems,
    }
    return parts, manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inspect", "publish"))
    args = parser.parse_args(argv)
    parts, manifest = assemble()
    if args.command == "publish":
        if manifest["problems"]:
            print(json.dumps(manifest, indent=1))
            return 1
        for name, records in parts.items():
            write_jsonl(output_path(name), records)
        manifest["files"] = {name: file_digest(output_path(name)) for name in OUTPUTS}
        write_json(MANIFEST, manifest)
    print(json.dumps(manifest, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
