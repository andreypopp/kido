"""Write the tracked manifest: counts, hashes, configuration and spend only."""

from __future__ import annotations

import json
import platform
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

from label import MODELS, PEAK_HOURS, Spend
from render import file_hash, hash_records, part_of, read_json, read_jsonl

SAMPLE_FILES = ("train", "dev", "dev-train", "eval")
PHASE1_SPEND = 22.527585965999986
EXTRA_FILES = (
    "eval-parts.jsonl",
    "synthetic/train.jsonl",
    "synthetic/eval.jsonl",
)


def package(name: str) -> str | None:
    try:
        return version(name)
    except PackageNotFoundError:
        return None


def main() -> int:
    data = Path("data")
    spend = Spend(data / "usage.jsonl", limit=float("inf"))
    summary = read_json(data / "eval-summary.json") or {}
    seeds = read_json(data / "train-seeds.json") or {}
    chosen = next(
        (run for run in seeds.get("runs", []) if run.get("name") == summary.get("chosen")),
        {},
    )
    checkpoint = Path(str(chosen.get("output", ""))) / "model.safetensors"
    chosen_eval = read_json(Path(str(chosen.get("eval", "")))) or {}
    errors = {
        "model": chosen.get("name"),
        "seed": chosen.get("seed"),
        "part": "real",
        "errors": (chosen_eval.get("errors_by_part") or {}).get("real", {}),
    }
    train_records = read_jsonl(data / "train.jsonl")
    eval_records = read_jsonl(data / "eval.jsonl")
    train_sessions = {str(record["session"]) for record in train_records}
    ask = [record for record in eval_records if part_of(record) == "ask"]
    shared = [record for record in ask if str(record["session"]) in train_sessions]
    ask_overlap = {
        "examples": len(ask),
        "shared_examples": len(shared),
        "shared_sessions": len({str(record["session"]) for record in shared}),
    }
    manifest = {
        "phase": 2,
        "seed": 0,
        "python": platform.python_version(),
        "packages": {
            name: package(name)
            for name in ("openai", "datasketch", "markdown-it-py", "transformers", "torch")
        },
        "deepseek": {
            "models": {
                key: {
                    "id": key,
                    "name": value["name"],
                    "version": value["version"],
                    "cache_hit": list(value["cache_hit"]),
                    "cache_miss": list(value["cache_miss"]),
                    "output": list(value["output"]),
                    "max_tokens": value["max_tokens"],
                }
                for key, value in MODELS.items()
            },
            "peak_hours_utc_weekdays": [list(window) for window in PEAK_HOURS],
        },
        "render": read_json(data / "render-meta.json"),
        "session_plan": read_json(data / "session-plan.json"),
        "synthetic": read_json(data / "synthetic-meta.json"),
        "label_train": read_json(data / "label-train-meta.json"),
        "label_train_flash": read_json(data / "label-train-flash-meta.json"),
        "label_eval_real": read_json(data / "label-eval-real-meta.json"),
        "train_agreement": read_json(data / "train-agreement.json"),
        "eval": read_json(data / "eval-meta.json"),
        "split": read_json(data / "split-meta.json"),
        "sanity": read_json(data / "sanity.json"),
        "diagnostic": read_json(data / "diagnostic-meta.json"),
        "label_diagnostic": read_json(data / "label-diagnostic-meta.json"),
        "hover_check": read_json(data / "hover-check.json"),
        "sweep": read_json(data / "sweep.json"),
        "experiment": read_json(data / "experiment.json"),
        "train_seeds": seeds,
        "eval_summary": summary,
        "errors": errors,
        "ask_overlap": ask_overlap,
        "checkpoint": {
            "path": str(checkpoint),
            "hash": file_hash(checkpoint),
            "bytes": checkpoint.stat().st_size if checkpoint.exists() else None,
        },
        "spend": {
            "total": spend.total,
            "phase2": spend.total - PHASE1_SPEND,
            "cached_hits": spend.cached_hits,
            "by_model": spend.snapshot(spend.models),
            "by_stage": spend.snapshot(spend.stages),
        },
        "data": {
            name: {
                "records": len(records),
                "hash": hash_records(records),
            }
            for name in SAMPLE_FILES
            if (records := read_jsonl(data / f"{name}.jsonl"))
        },
        "files": {
            name: file_hash(data / name)
            for name in EXTRA_FILES
        },
    }
    Path("manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(
        json.dumps(
            {
                "train": manifest["data"].get("train", {}).get("records"),
                "eval": manifest["data"].get("eval", {}).get("records"),
                "spend": manifest["spend"]["total"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
