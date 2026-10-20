"""Select eval contexts, deduplicate and write the train, dev and eval splits."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
from collections import Counter
from pathlib import Path

from datasketch import MinHash, MinHashLSH

from render import (
    SEED,
    exact_digest,
    family_digest,
    hash_records,
    hover_question,
    normalized,
    part_of,
    read_json,
    read_jsonl,
    variant,
    write_jsonl,
)
from validate import attach, is_positive, normalize_label, option_kinds

NEAR_THRESHOLD = 0.8
MINHASH_PERM = 64
EVAL_POSITIVE_TARGET = 300
EVAL_NEGATIVE_TARGET = 300
EVAL_SESSION_TARGET = 100
DEV_FRACTION = 0.15
DEV_OPTION_SPANS = 300


def shingles(text: str) -> set[str]:
    lines = normalized(text).splitlines()
    values = set(lines)
    values.update(" ".join(lines[index : index + 2]) for index in range(len(lines) - 1))
    return values


def minhash(text: str) -> MinHash:
    sketch = MinHash(num_perm=MINHASH_PERM)
    for value in shingles(text):
        sketch.update(value.encode())
    return sketch


class Deduper:
    def __init__(self, near: bool = True) -> None:
        self.near = near
        self.lsh = MinHashLSH(threshold=NEAR_THRESHOLD, num_perm=MINHASH_PERM)
        self.families: dict[str, str] = {}
        self.blocked: set[str] = set()
        self.exact: set[str] = set()

    def keep(
        self, records: list[dict[str, object]], block: bool = False
    ) -> tuple[list[dict[str, object]], int, int, int]:
        kept: list[dict[str, object]] = []
        exact_dropped = 0
        near_dropped = 0
        family_dropped = 0
        seen: set[str] = set()
        for record in sorted(records, key=lambda item: str(item["id"])):
            prompt = str(record["prompt"])
            family = family_digest(prompt)
            seen.add(family)
            if block and family in self.blocked:
                family_dropped += 1
                continue
            state = self.families.get(family)
            if state == "dropped":
                family_dropped += 1
                continue
            if state is None:
                sketch = minhash(prompt)
                if self.near and self.lsh.query(sketch):
                    self.families[family] = "dropped"
                    near_dropped += 1
                    continue
                if self.near:
                    self.lsh.insert(str(record["id"]), sketch)
                self.families[family] = "kept"
            key = exact_digest(prompt)
            if key in self.exact:
                exact_dropped += 1
                continue
            self.exact.add(key)
            kept.append(record)
        self.blocked.update(seen)
        return kept, exact_dropped, near_dropped, family_dropped


class UnionFind:
    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, value: str) -> str:
        self.parent.setdefault(value, value)
        while self.parent[value] != value:
            self.parent[value] = self.parent[self.parent[value]]
            value = self.parent[value]
        return value

    def union(self, left: str, right: str) -> None:
        a = self.find(left)
        b = self.find(right)
        if a != b:
            self.parent[b] = a


def family_records(
    records: list[dict[str, object]],
) -> dict[str, list[dict[str, object]]]:
    groups: dict[str, list[dict[str, object]]] = {}
    for record in records:
        groups.setdefault(str(record["context_id"]), []).append(record)
    return groups


def base_record(records: list[dict[str, object]]) -> dict[str, object]:
    question = [record for record in records if hover_question(record)]
    return sorted(question or records, key=lambda item: str(item["id"]))[0]


def select_eval(
    records: list[dict[str, object]],
) -> tuple[set[str], set[str], dict[str, list[dict[str, object]]]]:
    families = family_records(records)
    sessions: dict[str, set[str]] = {}
    for family, values in families.items():
        for record in values:
            sessions.setdefault(str(record["session"]), set()).add(family)
    question = {
        family for family, values in families.items() if any(hover_question(r) for r in values)
    }
    rng = random.Random(SEED)
    ordered = sorted(sessions)
    rng.shuffle(ordered)
    eval_sessions: set[str] = set()
    positive: set[str] = set()
    negative: set[str] = set()
    for session in ordered:
        if len(positive) >= EVAL_POSITIVE_TARGET and len(negative) >= EVAL_NEGATIVE_TARGET:
            if len(eval_sessions) >= EVAL_SESSION_TARGET:
                break
        eval_sessions.add(session)
        for family in sessions[session]:
            if family in question:
                positive.add(family)
            else:
                negative.add(family)
    chosen = set(sorted(positive)[:EVAL_POSITIVE_TARGET])
    chosen |= set(sorted(negative)[:EVAL_NEGATIVE_TARGET])
    chosen_sessions = {
        str(record["session"])
        for family in chosen
        for record in families[family]
    }
    if len(chosen_sessions) < EVAL_SESSION_TARGET:
        for session in ordered:
            if len(chosen_sessions) >= EVAL_SESSION_TARGET:
                break
            extra = [
                family
                for family in sessions[session]
                if family not in chosen and family not in question
            ]
            if not extra:
                continue
            chosen.add(sorted(extra)[0])
            chosen_sessions.add(session)
    eval_sessions = chosen_sessions
    return chosen, eval_sessions, families


def extra_variants(records: list[dict[str, object]]) -> list[dict[str, object]]:
    expanded: list[dict[str, object]] = []
    for values in family_records(records).values():
        base = base_record(values)
        existing = {str(record["id"]): record for record in values}
        for index in range(len(base["ranges"])):
            item = variant(base, index)
            record = existing.get(str(item["id"]))
            expanded.append(record or item)
    return expanded


def plan(args: argparse.Namespace) -> int:
    records = read_jsonl(args.contexts)
    asks = [record for record in records if record.get("source") == "ask"]
    real = [record for record in records if record.get("source") != "ask"]
    existing = read_json(args.output_dir / "session-plan.json")
    frozen = (existing or {}).get("selected", {})
    families = family_records(real)
    if frozen.get("families"):
        chosen = {str(family) for family in frozen["families"] if str(family) in families}
        eval_sessions = {
            str(record["session"]) for family in chosen for record in families[family]
        }
    else:
        chosen, eval_sessions, families = select_eval(real)
    train_records = [
        record for record in real if str(record["session"]) not in eval_sessions
    ]
    train = {str(record["context_id"]) for record in train_records}
    train_bases = [base_record(families[family]) for family in sorted(train)]
    eval_bases = [base_record(families[family]) for family in sorted(chosen)]
    train_variants = extra_variants(train_records)
    eval_variants = extra_variants(
        [record for record in real if str(record["context_id"]) in chosen]
    )
    write_jsonl(args.output_dir / "contexts-train.jsonl", train_bases)
    write_jsonl(args.output_dir / "contexts-train-variants.jsonl", train_variants)
    write_jsonl(args.output_dir / "contexts-eval-real.jsonl", eval_bases)
    write_jsonl(args.output_dir / "contexts-eval-real-variants.jsonl", eval_variants)
    write_jsonl(args.output_dir / "contexts-ask.jsonl", asks)
    session_plan = {
        "config": {
            "seed": SEED,
            "eval_positive_target": EVAL_POSITIVE_TARGET,
            "eval_negative_target": EVAL_NEGATIVE_TARGET,
            "eval_session_target": EVAL_SESSION_TARGET,
        },
        "selected": {
            "families": sorted(chosen),
            "sessions": sorted(eval_sessions),
            "question_families": len(
                {
                    family
                    for family in chosen
                    if any(hover_question(r) for r in families[family])
                }
            ),
        },
        "counts": {
            "contexts": len(real),
            "families": len(families),
            "train_families": len(train),
            "train_bases": len(train_bases),
            "eval_families": len(chosen),
            "eval_sessions": len(eval_sessions),
            "train_variants": len(train_variants),
            "eval_variants": len(eval_variants),
            "ask": len(asks),
        },
        "hashes": {
            "contexts": hash_records(records),
            "eval_families": hashlib.sha256(
                "\n".join(sorted(chosen)).encode()
            ).hexdigest(),
        },
    }
    (args.output_dir / "session-plan.json").write_text(
        json.dumps(session_plan, indent=2) + "\n"
    )
    print(json.dumps(session_plan["counts"], sort_keys=True))
    return 0


def labels_by_family(
    bases: list[dict[str, object]], labels_path: Path
) -> tuple[dict[str, dict[str, object]], dict[str, int]]:
    base_family = {str(base["id"]): base for base in bases}
    labels: dict[str, dict[str, object]] = {}
    changed_lines = 0
    changed_families = 0
    for item in read_jsonl(labels_path):
        if item.get("label") is None:
            continue
        base = base_family.get(str(item["id"]))
        if base is None:
            continue
        normalized, changed = normalize_label(str(base["prompt"]), item["label"])
        if not isinstance(normalized, dict):
            continue
        labels[str(base["context_id"])] = normalized
        if changed:
            changed_families += 1
            changed_lines += changed
    return labels, {
        "lines_changed": changed_lines,
        "families_changed": changed_families,
        "families": len(labels),
    }


def attach_variants(
    variants: list[dict[str, object]], labels: dict[str, dict[str, object]]
) -> tuple[list[dict[str, object]], int]:
    records = []
    missing = 0
    for record in variants:
        label = labels.get(str(record["context_id"]))
        if label is None:
            missing += 1
            continue
        attached, _ = attach(record, label)
        if attached is None:
            missing += 1
            continue
        records.append(attached)
    return records, missing


def balance(records: list[dict[str, object]]) -> tuple[list[dict[str, object]], int]:
    positives = [record for record in records if is_positive(record)]
    negatives = [record for record in records if not is_positive(record)]
    if len(positives) <= len(negatives):
        return records, 0
    rng = random.Random(SEED)
    rng.shuffle(positives)
    chosen = {str(record["id"]) for record in positives[: len(negatives)]}
    return [
        record
        for record in records
        if not is_positive(record) or str(record["id"]) in chosen
    ], len(positives) - len(negatives)


def assign_dev(
    records: list[dict[str, object]],
    fraction: float = DEV_FRACTION,
    target_spans: int = DEV_OPTION_SPANS,
) -> tuple[list[dict[str, object]], list[dict[str, object]], dict[str, int]]:
    union = UnionFind()
    for record in records:
        union.union(
            "session:" + str(record["session"]),
            "family:" + str(record["context_id"]),
        )
    components: dict[str, list[dict[str, object]]] = {}
    for record in records:
        components.setdefault(union.find("session:" + str(record["session"])), []).append(record)
    roots = sorted(components)
    rng = random.Random(SEED)
    rng.shuffle(roots)
    wanted = max(1, int(len(records) * fraction))
    dev_roots: set[str] = set()
    examples = 0
    spans = 0
    for root in roots:
        values = components[root]
        if examples >= wanted and spans >= target_spans:
            break
        dev_roots.add(root)
        examples += len(values)
        spans += sum(len(record["label"]["options"]) for record in values)
    dev = [
        record
        for record in records
        if union.find("session:" + str(record["session"])) in dev_roots
    ]
    train = [
        record
        for record in records
        if union.find("session:" + str(record["session"])) not in dev_roots
    ]
    return train, dev, {
        "examples": len(dev),
        "positive": sum(1 for record in dev if is_positive(record)),
        "negative": sum(1 for record in dev if not is_positive(record)),
        "sessions": len({str(record["session"]) for record in dev}),
        "families": len({str(record["context_id"]) for record in dev}),
        "option_spans": spans,
        "option_spans_real": sum(
            len(record["label"]["options"]) for record in dev if record["source"] != "synthetic"
        ),
        "option_kinds": kinds(dev),
    }


def family_set(records: list[dict[str, object]]) -> set[str]:
    return {str(record["context_id"]) for record in records}


def kinds(records: list[dict[str, object]]) -> dict[str, int]:
    total = Counter()
    for record in records:
        total.update(option_kinds(record))
    return dict(total)


def part_counts(records: list[dict[str, object]]) -> dict[str, object]:
    parts: dict[str, dict[str, object]] = {}
    for record in records:
        part = part_of(record)
        values = parts.setdefault(
            part,
            {
                "examples": 0,
                "positive": 0,
                "negative": 0,
                "option_spans": 0,
                "option_kinds": {"list": 0, "inline": 0},
                "families": set(),
                "sessions": set(),
            },
        )
        positive = is_positive(record)
        values["examples"] += 1
        values["positive" if positive else "negative"] += 1
        values["option_spans"] += len(record["label"]["options"])
        for kind, count in option_kinds(record).items():
            values["option_kinds"][kind] += count
        values["families"].add(str(record["context_id"]))
        values["sessions"].add(str(record["session"]))
    for values in parts.values():
        values["families"] = len(values["families"])
        values["sessions"] = len(values["sessions"])
    return parts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contexts", type=Path, default=Path("data/contexts.jsonl"))
    parser.add_argument(
        "--train-bases", type=Path, default=Path("data/contexts-train.jsonl")
    )
    parser.add_argument(
        "--train-variants",
        type=Path,
        default=Path("data/contexts-train-variants.jsonl"),
    )
    parser.add_argument(
        "--train-labels", type=Path, default=Path("data/labels-train.jsonl")
    )
    parser.add_argument("--eval-parts", type=Path, default=Path("data/eval-parts.jsonl"))
    parser.add_argument(
        "--synthetic", type=Path, default=Path("data/synthetic/train.jsonl")
    )
    parser.add_argument("--output-dir", type=Path, default=Path("data"))
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args(argv)
    if args.plan:
        return plan(args)
    labels, normalization = labels_by_family(
        read_jsonl(args.train_bases), args.train_labels
    )
    real, missing = attach_variants(read_jsonl(args.train_variants), labels)
    synthetic = read_jsonl(args.synthetic)
    train = real + synthetic
    evaluation = read_jsonl(args.eval_parts)
    deduper = Deduper()
    evaluation, eval_exact, eval_near, _ = deduper.keep(evaluation)
    train, train_exact, train_near, _ = deduper.keep(train, block=True)
    train, balanced = balance(train)
    dev_train, dev, dev_meta = assign_dev(train)
    train_families = family_set(dev_train) | family_set(dev)
    eval_families = family_set(evaluation)
    if train_families & eval_families or family_set(dev) & family_set(dev_train):
        raise RuntimeError("split families overlap")
    full_train = sorted(dev_train + dev, key=lambda item: str(item["id"]))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_jsonl(args.output_dir / "train.jsonl", full_train)
    write_jsonl(args.output_dir / "dev-train.jsonl", dev_train)
    write_jsonl(args.output_dir / "dev.jsonl", dev)
    write_jsonl(args.output_dir / "eval.jsonl", evaluation)
    meta = {
        "config": {
            "seed": SEED,
            "near_threshold": NEAR_THRESHOLD,
            "minhash_perm": MINHASH_PERM,
            "dev_fraction": DEV_FRACTION,
            "dev_option_spans": DEV_OPTION_SPANS,
        },
        "counts": {
            "train_bases": len(labels),
            "train_missing_labels": missing,
            "train": len(full_train),
            "dev": len(dev),
            "dev_train": len(dev_train),
            "eval": len(evaluation),
            "eval_exact_duplicates": eval_exact,
            "eval_near_duplicates": eval_near,
            "train_exact_duplicates": train_exact,
            "train_near_duplicates": train_near,
            "train_balanced_positive_dropped": balanced,
            "train_sessions": len({str(record["session"]) for record in full_train}),
            "train_families": len(train_families),
            "eval_families": len(eval_families),
            "dev_families": len(family_set(dev)),
            "train_option_spans": sum(
                len(record["label"]["options"]) for record in full_train
            ),
            "eval_option_spans": sum(
                len(record["label"]["options"]) for record in evaluation
            ),
            "train_option_kinds": kinds(full_train),
            "train_normalization": normalization,
            "dev_option_kinds": kinds(dev),
            "eval_option_kinds": kinds(evaluation),
        },
        "train_parts": part_counts(full_train),
        "eval_parts": part_counts(evaluation),
        "dev": dev_meta,
        "hashes": {
            "train": hash_records(full_train),
            "dev": hash_records(dev),
            "dev_train": hash_records(dev_train),
            "eval": hash_records(evaluation),
        },
    }
    (args.output_dir / "split-meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
