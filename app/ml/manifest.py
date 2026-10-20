"""Write the tracked manifest: counts, hashes, configuration and metrics only."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from render import (
    CHARACTER_LIMIT,
    CONTEXT_AFTER,
    CONTEXT_BEFORE,
    LINE_LIMIT,
    SEED,
    TARGET_CONTEXTS,
    WIDTH_MAX,
    WIDTH_MIN,
    read_jsonl,
)
from runtime import MODEL


def read_json(path: Path) -> object:
    return json.loads(path.read_text())


def hash_records(values: list[dict[str, object]], field: str = "prompt") -> str:
    digest = hashlib.sha256()
    for value in sorted(values, key=lambda item: str(item["id"])):
        digest.update(str(value["id"]).encode())
        digest.update(json.dumps(value.get(field)).encode())
    return digest.hexdigest()


def main() -> int:
    import hashlib

    import coremltools
    import torch
    import transformers
    from transformers import AutoTokenizer

    contexts = read_jsonl(Path("data/contexts.jsonl"))
    labels = read_jsonl(Path("data/labels.jsonl"))
    splits = {}
    for name in ("train", "eval", "dev-train", "dev"):
        values = read_jsonl(Path(f"data/{name}.jsonl"))
        splits[name] = {
            "examples": len(values),
            "sessions": len({str(value["session"]) for value in values}),
            "hash": hash_records(values),
        }
    synthetic = {}
    for name in ("train", "eval"):
        values = read_jsonl(Path(f"data/synthetic/{name}.jsonl"))
        synthetic[name] = {"examples": len(values), "hash": hash_records(values)}
    models = {}
    for name in (
        "curve-100-bold-s0",
        "curve-100-bold-s1",
        "curve-100-bold-s2",
        "curve-100-nobold-s0",
        "curve-100-nobold-s1",
        "curve-100-nobold-s2",
        "curve-100-createml-bold",
        "curve-100-createml-nobold",
        "synthetic-ettin-bold",
        "synthetic-ettin-nobold",
        "synthetic-createml-bold",
        "synthetic-createml-nobold",
    ):
        directory = Path("data/output") / name
        training = directory / "training.json"
        evaluation = directory / "eval.json"
        if not training.exists():
            continue
        models[name] = {
            "training": read_json(training),
            "eval": read_json(evaluation) if evaluation.exists() else None,
        }
    from huggingface_hub import model_info

    revision = None
    try:
        revision = model_info(MODEL).sha
    except Exception:  # noqa: BLE001 - offline runs still write the manifest
        pass
    converted = Path("data/output/ParagraphTagger.mlpackage")
    converted_hash = None
    if converted.exists():
        digest = hashlib.sha256()
        for item in sorted(converted.rglob("*")):
            if item.is_file():
                digest.update(item.relative_to(converted).as_posix().encode())
                digest.update(item.read_bytes())
        converted_hash = digest.hexdigest()
    manifest = {
        "seed": SEED,
        "python": "3.12",
        "transformers": transformers.__version__,
        "torch": torch.__version__,
        "coremltools": coremltools.__version__,
        "base_model": {
            "id": MODEL,
            "revision": revision,
        },
        "tokenizer": AutoTokenizer.from_pretrained(MODEL).name_or_path,
        "render": {
            "width_min": WIDTH_MIN,
            "width_max": WIDTH_MAX,
            "target_contexts": TARGET_CONTEXTS,
            "context_before": CONTEXT_BEFORE,
            "context_after": CONTEXT_AFTER,
            "line_limit": LINE_LIMIT,
            "character_limit": CHARACTER_LIMIT,
        },
        "counts": {
            "contexts": len(contexts),
            "labelled": len(labels),
            "sessions": len({str(value["session"]) for value in contexts}),
            "positive": sum(
                1
                for value in contexts
                if value.get("source") == "ask"
                or any(
                    "?" in str(value["lines"][index]["text"])
                    for index in range(
                        int(value["ranges"][int(value["hovered"])][0]),
                        int(value["ranges"][int(value["hovered"])][1]) + 1,
                    )
                )
            ),
            "ask": sum(1 for value in contexts if value.get("source") == "ask"),
        },
        "hashes": {
            "contexts": hash_records(contexts),
            "labels": hash_records(labels, "label"),
        },
        "split": splits,
        "synthetic": synthetic,
        "sweep": read_json(Path("data/sweep.json"))
        if Path("data/sweep.json").exists()
        else None,
        "learning_curve": read_json(Path("data/learning-curve.json"))
        if Path("data/learning-curve.json").exists()
        else None,
        "labels": {
            key: read_json(Path("data/label-meta.json"))[key]
            for key in ("model", "samples", "contexts", "labelled", "ask_gold", "dropped")
        }
        if Path("data/label-meta.json").exists()
        else None,
        "tokens": read_json(Path("data/token-counts.json"))
        if Path("data/token-counts.json").exists()
        else None,
        "converted_hash": converted_hash,
        "convert": read_json(Path("data/convert.json"))
        if Path("data/convert.json").exists()
        else None,
        "bench": read_json(Path("data/bench.json")) if Path("data/bench.json").exists() else None,
        "swift_offsets": read_json(Path("data/swift-offsets.json"))
        if Path("data/swift-offsets.json").exists()
        else None,
        "models": models,
    }
    Path("manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"contexts": len(contexts), "models": len(models)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
