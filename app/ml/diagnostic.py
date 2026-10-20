"""Compare the flash and v4-pro labels on a seeded train sample under one convention."""

from __future__ import annotations

import argparse
import json
import random
from collections import Counter
from pathlib import Path

from render import (
    MARKER,
    SEED,
    hover_question,
    prompt_lines,
    read_jsonl,
    write_jsonl,
)
from validate import label_errors, normalize_label, unit_from_classes

TARGET = 300


def option_kind(prompt: str, option: dict[str, object]) -> str:
    lines = prompt_lines(prompt)
    text = str(lines[int(option["line"]) - 1]["text"])
    return "list" if MARKER.match(text) else "inline"


def select(bases_path: Path, output: Path) -> dict[str, int]:
    bases = [record for record in read_jsonl(bases_path) if hover_question(record)]
    bases.sort(key=lambda item: str(item["id"]))
    rng = random.Random(SEED)
    rng.shuffle(bases)
    selected = bases[:TARGET]
    write_jsonl(output, selected)
    return {"families": len(selected), "available": len(bases)}


def key(text: str) -> str:
    return " ".join(text.casefold().split())


def compare(
    bases: list[dict[str, object]],
    flash_path: Path,
    pro_path: Path,
) -> dict[str, object]:
    flash = {str(item["id"]): item["label"] for item in read_jsonl(flash_path) if item.get("label")}
    pro = {str(item["id"]): item["label"] for item in read_jsonl(pro_path) if item.get("label")}
    counts: Counter[str] = Counter()
    flash_lines = 0
    flash_families = 0
    pro_lines = 0
    pro_families = 0
    for base in bases:
        identifier = str(base["id"])
        if identifier not in flash or identifier not in pro:
            counts["missing"] += 1
            continue
        prompt = str(base["prompt"])
        flash_label, flash_changed = normalize_label(prompt, flash[identifier])
        pro_label, pro_changed = normalize_label(prompt, pro[identifier])
        if not isinstance(flash_label, dict) or not isinstance(pro_label, dict):
            counts["invalid"] += 1
            continue
        if label_errors(prompt, flash_label) or label_errors(prompt, pro_label):
            counts["invalid"] += 1
            continue
        if flash_changed:
            flash_families += 1
            flash_lines += flash_changed
        if pro_changed:
            pro_families += 1
            pro_lines += pro_changed
        counts["families"] += 1
        classes_ok = flash_label["lines"] == pro_label["lines"]
        counts["class_agreement"] += int(classes_ok)
        ranges = [list(pair) for pair in base["ranges"]]
        hovered = int(base["hovered"])
        flash_unit = unit_from_classes(prompt, flash_label["lines"], ranges, hovered)
        pro_unit = unit_from_classes(prompt, pro_label["lines"], ranges, hovered)
        counts["unit_agreement"] += int(flash_unit == pro_unit)
        flash_options = {key(str(option["text"])) for option in flash_label["options"]}
        pro_options = {key(str(option["text"])) for option in pro_label["options"]}
        if flash_options == pro_options:
            counts["options_exact"] += 1
            continue
        pro_extra = pro_options - flash_options
        flash_extra = flash_options - pro_options
        if pro_extra and not flash_extra:
            kinds = {
                option_kind(prompt, option)
                for option in pro_label["options"]
                if key(str(option["text"])) in pro_extra
            }
            if kinds == {"inline"}:
                counts["v4_more_inline"] += 1
            elif kinds == {"list"}:
                counts["v4_more_list"] += 1
            else:
                counts["other"] += 1
        elif flash_extra and not pro_extra:
            kinds = {
                option_kind(prompt, option)
                for option in flash_label["options"]
                if key(str(option["text"])) in flash_extra
            }
            if kinds == {"inline"}:
                counts["flash_more_inline"] += 1
            elif kinds == {"list"}:
                counts["flash_more_list"] += 1
            else:
                counts["other"] += 1
        else:
            counts["other"] += 1
    return {
        "selected": len(bases),
        "flash_labels": len(flash),
        "pro_labels": len(pro),
        "families": counts["families"],
        "missing": counts["missing"],
        "invalid": counts["invalid"],
        "class_agreement": counts["class_agreement"],
        "unit_agreement": counts["unit_agreement"],
        "options_exact": counts["options_exact"],
        "v4_more_inline": counts["v4_more_inline"],
        "v4_more_list": counts["v4_more_list"],
        "flash_more_inline": counts["flash_more_inline"],
        "flash_more_list": counts["flash_more_list"],
        "other": counts["other"],
        "flash_normalization": {
            "families_changed": flash_families,
            "lines_changed": flash_lines,
        },
        "pro_normalization": {
            "families_changed": pro_families,
            "lines_changed": pro_lines,
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--select", action="store_true")
    parser.add_argument("--compare", action="store_true")
    parser.add_argument("--bases", type=Path, default=Path("data/contexts-train.jsonl"))
    parser.add_argument(
        "--contexts", type=Path, default=Path("data/diagnostic-contexts.jsonl")
    )
    parser.add_argument(
        "--flash", type=Path, default=Path("data/labels-train.jsonl")
    )
    parser.add_argument(
        "--pro", type=Path, default=Path("data/labels-diagnostic.jsonl")
    )
    parser.add_argument("--output", type=Path, default=Path("data/diagnostic-meta.json"))
    args = parser.parse_args(argv)
    if args.select:
        print(json.dumps(select(args.bases, args.contexts), sort_keys=True))
        return 0
    if args.compare:
        result = compare(
            read_jsonl(args.contexts), args.flash, args.pro
        )
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, sort_keys=True))
        return 0
    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
