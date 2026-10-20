"""Assemble the three eval parts and decide the v4-pro agreement filter."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

from render import (
    hash_records,
    part_of,
    read_json,
    read_jsonl,
    write_jsonl,
)
from validate import (
    attach,
    canonical_label,
    is_positive,
    label_errors,
    normalize_label,
    option_kinds,
)

EXPECTED_SAMPLES = 5


def agreement(
    bases: list[dict[str, object]],
    samples: list[dict[str, object]],
    expected: int = EXPECTED_SAMPLES,
) -> tuple[list[dict[str, object]], dict[str, int], int]:
    base_family = {str(base["id"]): str(base["context_id"]) for base in bases}
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for sample in samples:
        grouped[str(sample["id"])].append(sample)
    records: list[dict[str, object]] = []
    stats = {
        "attempted": 0,
        "agreed": 0,
        "disagreement": 0,
        "invalid": 0,
        "not_attempted": 0,
        "normalization_families": 0,
        "normalization_lines": 0,
    }
    rejected = 0
    for base in bases:
        identifier = str(base["id"])
        family = base_family[identifier]
        values = grouped.get(identifier, [])
        if not values:
            continue
        stats["attempted"] += 1
        raw_labels = [
            item["label"] for item in values if isinstance(item.get("label"), dict)
        ]
        if raw_labels:
            _, changed = normalize_label(str(base["prompt"]), raw_labels[0])
            if changed:
                stats["normalization_families"] += 1
                stats["normalization_lines"] += changed
        errors = [error for item in values for error in item.get("errors", [])]
        if errors:
            stats["invalid"] += 1
            continue
        if any(label_errors(str(base["prompt"]), label) for label in raw_labels):
            rejected += 1
            stats["invalid"] += 1
            continue
        labels = []
        for raw in raw_labels:
            normalized, _ = normalize_label(str(base["prompt"]), raw)
            labels.append(normalized)
        if any(
            not isinstance(label, dict)
            or label_errors(str(base["prompt"]), label)
            for label in labels
        ):
            rejected += 1
            stats["invalid"] += 1
            continue
        keys = {
            json.dumps(canonical_label(label, str(base["prompt"])), sort_keys=True)
            for label in labels
        }
        if len(keys) > 1:
            stats["disagreement"] += 1
            continue
        if len(labels) != expected or len(values) != expected:
            stats["invalid"] += 1
            continue
        stats["agreed"] += 1
        records.append(
            {
                **base,
                "part": "real",
                "label": labels[0],
                "family": family,
                "samples": expected,
            }
        )
    return records, stats, rejected


def attach_gold(records: list[dict[str, object]], part: str) -> tuple[list, int]:
    kept = []
    rejected = 0
    for record in records:
        label = record.get("gold") or record.get("label")
        attached, _ = attach(record, label)
        if attached is None:
            rejected += 1
            continue
        kept.append({**attached, "part": part})
    return kept, rejected


def expand_real(
    bases: list[dict[str, object]],
    variants: list[dict[str, object]],
    samples: list[dict[str, object]],
    expected: int = EXPECTED_SAMPLES,
) -> tuple[list[dict[str, object]], dict[str, int], int, int]:
    decided, stats, rejected = agreement(bases, samples, expected)
    labels = {str(record["family"]): record["label"] for record in decided}
    records = []
    for record in variants:
        label = labels.get(str(record["context_id"]))
        if label is None:
            continue
        attached, _ = attach(record, label)
        if attached is None:
            continue
        records.append({**attached, "part": "real"})
    return records, stats, rejected, len(decided)


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
                "hash": "",
            },
        )
        values["examples"] += 1
        values["positive" if is_positive(record) else "negative"] += 1
        values["option_spans"] += len(record["label"]["options"])
        for kind, count in option_kinds(record).items():
            values["option_kinds"][kind] += count
        values["families"].add(str(record["context_id"]))
        values["sessions"].add(str(record["session"]))
    for part, values in parts.items():
        values["families"] = len(values["families"])
        values["sessions"] = len(values["sessions"])
        values["hash"] = hash_records(
            [record for record in records if part_of(record) == part]
        )
    return parts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ask", type=Path, default=Path("data/contexts-ask.jsonl"))
    parser.add_argument(
        "--synthetic", type=Path, default=Path("data/synthetic/eval.jsonl")
    )
    parser.add_argument(
        "--real-bases", type=Path, default=Path("data/contexts-eval-real.jsonl")
    )
    parser.add_argument(
        "--real-variants",
        type=Path,
        default=Path("data/contexts-eval-real-variants.jsonl"),
    )
    parser.add_argument(
        "--real-samples",
        type=Path,
        default=Path("data/eval-real-samples.jsonl"),
    )
    parser.add_argument("--plan", type=Path, default=Path("data/session-plan.json"))
    parser.add_argument("--output", type=Path, default=Path("data/eval-parts.jsonl"))
    parser.add_argument("--meta", type=Path, default=Path("data/eval-meta.json"))
    args = parser.parse_args(argv)

    ask, ask_rejected = attach_gold(read_jsonl(args.ask), "ask")
    synthetic, synthetic_rejected = attach_gold(read_jsonl(args.synthetic), "synthetic")
    real, stats, real_rejected, decided = expand_real(
        read_jsonl(args.real_bases),
        read_jsonl(args.real_variants),
        read_jsonl(args.real_samples),
    )
    plan = read_json(args.plan)
    if plan is None:
        raise FileNotFoundError(f"missing input: {args.plan}")
    selected = plan.get("selected", {}).get("families", [])
    stats["not_attempted"] = max(0, len(selected) - stats["attempted"])
    records = ask + synthetic + real
    records.sort(key=lambda item: str(item["id"]))
    write_jsonl(args.output, records)
    meta = {
        "config": {
            "model": "deepseek-v4-pro",
            "samples": EXPECTED_SAMPLES,
            "thinking": True,
        },
        "counts": {
            "examples": len(records),
            "ask_rejected": ask_rejected,
            "synthetic_rejected": synthetic_rejected,
            "real_rejected": real_rejected,
            "real_families": decided,
            "selected_families": len(selected),
            "agreement": stats,
            "normalization": {
                "families": stats["attempted"],
                "families_changed": stats["normalization_families"],
                "lines_changed": stats["normalization_lines"],
            },
            "hash": hash_records(records),
        },
        "parts": part_counts(records),
    }
    args.meta.write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta["counts"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
