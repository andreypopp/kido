"""Label the selected texts with DeepSeek v4-pro: samples in waves, then agreement.

Paid, and only off peak. A budget, peak-hours or transport stop is not a sample: the run exits
with a nonzero status and the jobs stay pending for the next run.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from openai import OpenAI

from corpus import candidates
from deepseek import (
    BudgetExceeded,
    LedgerBusy,
    PeakHours,
    Spend,
    now,
    read_ledger,
    run_parallel,
)
from jsonl import append_jsonl, read_jsonl, write_jsonl
from paths import CACHE, LEDGER, OLD_LEDGER, drops_path, labels_path, samples_path
from questions import LENGTH, PROMPT_HASH, canonical, label_text, ordered_options
from select_texts import frozen, frozen_negatives

PEAK_STOP, BUDGET_STOP, TRANSPORT_STOP = 3, 4, 5


class Stopped(Exception):
    pass


@dataclass(frozen=True)
class Stage:
    ids: str
    samples: int
    max_tokens: int


STAGES = {
    "eval-real": Stage("eval_real", 3, 16000),
    "negative-sample": Stage("negative_sample", 1, 10000),
    "train-real": Stage("train_real", 1, 10000),
    "eval-negative": Stage("eval_negative", 3, 10000),
    "train-negative": Stage("train_negative", 1, 10000),
}


def stage_ids(name: str) -> list[str]:
    """The ids a stage labels, from the frozen selections."""
    _, selection = frozen()
    if name == "eval-negative":
        extra = frozen_negatives()["eval_negative_extra"]
        return [*selection["eval_negative"], *extra]  # type: ignore[misc]
    if name == "train-negative":
        return list(frozen_negatives()["train_negative"])  # type: ignore[call-overload]
    return list(selection[STAGES[name].ids])  # type: ignore[call-overload]


def is_done(sample: dict[str, object], stage: Stage) -> bool:
    """A sample counts only for the current prompt and token limit."""
    return sample.get("prompt") == PROMPT_HASH and sample.get("max_tokens") == stage.max_tokens


def impossible(first: dict[str, object] | None, second: dict[str, object] | None) -> bool:
    """Two samples that are both without a label leave no way to get two that agree."""
    return all(s is not None and "label" not in s for s in (first, second))


def agree(
    ids: list[str], stage: Stage, samples: list[dict[str, object]], texts: dict[str, str]
) -> tuple[list[dict[str, object]], list[dict[str, object]], list[str]]:
    """(kept, dropped, undecided ids). A text keeps the label that at least two of its samples
    share (one sample is enough in a one-sample stage), taken from the lowest sample number
    with its options in text order. Only samples of the current prompt and token limit count.
    A text without enough samples yet is undecided, unless sample 3 is not needed."""
    by_id: dict[str, dict[int, dict[str, object]]] = {}
    for item in samples:
        if is_done(item, stage):
            by_id.setdefault(str(item["id"]), {})[int(item["sample"])] = item  # type: ignore[call-overload]
    need = 1 if stage.samples == 1 else 2
    kept, dropped, undecided = [], [], []
    for key in ids:
        got = by_id.get(key, {})
        skipped = stage.samples == 3 and 3 not in got and impossible(got.get(1), got.get(2))
        if len(got) < stage.samples and not skipped:
            undecided.append(key)
            continue
        valid = [got[n] for n in sorted(got) if "label" in got[n]]
        groups: dict[object, list[dict[str, object]]] = {}
        for s in valid:
            groups.setdefault(canonical(s["label"]), []).append(s)  # type: ignore[arg-type]
        best = max(groups.values(), key=len, default=[])
        if len(best) >= need:
            kept.append(
                {
                    "id": key,
                    "label": ordered_options(texts[key], best[0]["label"]),  # type: ignore[arg-type]
                    "agree": len(best),
                    "samples": len(got),
                    "valid": len(valid),
                    "prompt": PROMPT_HASH,
                }
            )
            continue
        if any(s.get("errors") == [LENGTH] for s in got.values()):
            reason = "length"
        else:
            reason = "invalid" if len(valid) < need else "disagree"
        dropped.append({"id": key, "reason": reason, "valid": len(valid), "samples": len(got)})
    return kept, dropped, undecided


def run_stage(
    client: OpenAI,
    spend: Spend,
    stage: Stage,
    name: str,
    ids: list[str],
    texts: dict[str, str],
    *,
    samples_file: Path,
    cache_dir: Path,
    workers: int,
    user: str,
    clock: Callable[[], datetime] = now,
    sleep: Callable[[float], None] = time.sleep,
) -> tuple[int, dict[str, int]]:
    """Run the pending jobs wave by wave. Returns (status, counts); 0 is a complete run."""
    counts = {"labels": 0, "rejected": 0}
    status = 0

    for number in range(1, stage.samples + 1):
        stop = threading.Event()

        def work(job: tuple[str, int], stop: threading.Event = stop) -> dict[str, object]:
            if stop.is_set():
                raise Stopped
            return label_text(
                client,
                texts[job[0]],
                spend=spend,
                cache_dir=cache_dir,
                stage=name,
                user=user,
                max_tokens=stage.max_tokens,
                sample=job[1],
                clock=clock,
                sleep=sleep,
            )

        have = {
            (str(s["id"]), int(s["sample"])): s  # type: ignore[call-overload]
            for s in read_jsonl(samples_file)
            if is_done(s, stage)
        }
        jobs = [
            (key, number)
            for key in ids
            if (key, number) not in have
            and not (
                number == 3
                and stage.samples == 3
                and impossible(have.get((key, 1)), have.get((key, 2)))
            )
        ]
        for job, result in run_parallel(jobs, work, workers, stop):
            if isinstance(result, Stopped):
                continue
            if isinstance(result, BaseException):
                stop.set()
                if isinstance(result, BudgetExceeded):
                    status = status or BUDGET_STOP
                elif isinstance(result, PeakHours):
                    status = status or PEAK_STOP
                else:
                    status = status or TRANSPORT_STOP
                    counts[type(result).__name__] = counts.get(type(result).__name__, 0) + 1
                continue
            counts["rejected" if "errors" in result else "labels"] += 1
            record = {
                "id": job[0],
                "sample": job[1],
                "prompt": PROMPT_HASH,
                "max_tokens": stage.max_tokens,
                **result,
            }
            append_jsonl(samples_file, record)
        if status:
            break
    return status, counts


def publish(name: str, stage: Stage, ids: list[str], texts: dict[str, str]) -> dict[str, object]:
    kept, dropped, undecided = agree(ids, stage, read_jsonl(samples_path(name)), texts)
    write_jsonl(labels_path(name), kept)
    write_jsonl(drops_path(name), dropped)
    return {"stage": name, "kept": len(kept), "dropped": len(dropped), "undecided": len(undecided)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run", "aggregate"))
    parser.add_argument("stage", choices=tuple(STAGES))
    parser.add_argument("--limit", type=int)
    parser.add_argument("--workers", type=int, default=24)
    args = parser.parse_args(argv)
    stage = STAGES[args.stage]
    ids = stage_ids(args.stage)
    texts = {str(r["id"]): str(r["text"]) for r in candidates()}
    if args.command == "aggregate":
        print(json.dumps(publish(args.stage, stage, ids, texts)))
        return 0
    user = getpass.getuser()
    ids = ids[: args.limit]
    key = os.environ.get("DEEPSEEK_API_KEY", "")
    if not key:
        print("label: DEEPSEEK_API_KEY is not set", file=sys.stderr)
        return 1
    client = OpenAI(api_key=key, base_url="https://api.deepseek.com", max_retries=0, timeout=900)
    try:
        spend = Spend(LEDGER, earlier=[OLD_LEDGER])
    except LedgerBusy as error:
        print(f"label: {error}", file=sys.stderr)
        return 1
    before = spend.stages.get(args.stage, 0.0)
    try:
        status, counts = run_stage(
            client,
            spend,
            stage,
            args.stage,
            ids,
            texts,
            samples_file=samples_path(args.stage),
            cache_dir=CACHE,
            workers=args.workers,
            user=user,
        )
    except KeyboardInterrupt:
        status, counts = 130, {}
    total, _, held = read_ledger([OLD_LEDGER, LEDGER])
    print(
        json.dumps(
            {
                "stage": args.stage,
                **counts,
                "status": status,
                "spend_run": round(spend.stages.get(args.stage, 0.0) - before, 4),
                "spend_total": round(total, 4),
                "unsettled": round(sum(held.values()), 4),
                "prompt": PROMPT_HASH,
            }
        )
    )
    return status


if __name__ == "__main__":
    sys.exit(main())
