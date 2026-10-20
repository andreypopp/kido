"""Write the tracked manifest: counts, hashes, configuration and spend only."""

from __future__ import annotations

import json
import platform
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

from label import MODELS, PEAK_HOURS, Spend
from render import file_hash, hash_records, read_json, read_jsonl

SAMPLE_FILES = ("train", "dev", "dev-train", "eval")
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
    manifest = {
        "phase": 1,
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
        "label_eval_real": read_json(data / "label-eval-real-meta.json"),
        "eval": read_json(data / "eval-meta.json"),
        "split": read_json(data / "split-meta.json"),
        "sanity": read_json(data / "sanity.json"),
        "diagnostic": read_json(data / "diagnostic-meta.json"),
        "label_diagnostic": read_json(data / "label-diagnostic-meta.json"),
        "hover_check": read_json(data / "hover-check.json"),
        "spend": {
            "total": spend.total,
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
