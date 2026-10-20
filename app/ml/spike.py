"""Phase 1 spike: sample texts from train sessions, then label them with v4-pro."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import random
import sys
import threading
from datetime import UTC, datetime
from pathlib import Path

from openai import OpenAI

from deepseek import DATA, OLD_LEDGER, LedgerBusy, Spend, is_peak, run_parallel
from jsonl import append_jsonl, read_jsonl, write_jsonl
from questions import PROMPT_HASH, label_text
from render import STYLES, ask_sessions, render_text, transcript_messages
from segments import segments

OLD_PLAN = Path("data-paragraphs/session-plan.json")
ROOTS = {
    "pi": Path.home() / ".pi" / "agent" / "sessions",
    "claude": Path.home() / ".claude" / "projects",
}
WIDTH_MIN, WIDTH_MAX = 60, 220
MAX_CHARACTERS = 8000
PER_SESSION = 3
TEXTS = DATA / "spike-texts.jsonl"


def question_segments(text: str) -> int:
    """Sentences and list items, outside code and tables, that contain a question mark."""
    return sum(
        1 for s in segments(text) if s.kind in ("sentence", "item") and "?" in text[s.start : s.end]
    )


def sample(count: int, multi: int, user: str) -> tuple[list[dict[str, object]], dict[str, int]]:
    excluded = set(json.loads(OLD_PLAN.read_text())["selected"]["sessions"])
    excluded |= ask_sessions(ROOTS["claude"])
    pool: list[dict[str, object]] = []
    seen = {"messages": 0, "short": 0, "excluded": 0, "no_question_mark": 0, "too_long": 0}
    for source, root in ROOTS.items():
        for message in transcript_messages(root, source):
            seen["messages"] += 1
            seen["short"] += len(message.text) < 300
            if message.session in excluded:
                seen["excluded"] += 1
            elif "?" not in message.text:
                seen["no_question_mark"] += 1
            elif len(message.text) > MAX_CHARACTERS:
                seen["too_long"] += 1
            else:
                digest = hashlib.sha256(f"{message.session}\0{message.text}".encode()).hexdigest()
                width = random.Random(digest).randint(WIDTH_MIN, WIDTH_MAX)
                text = render_text(message.text, width, STYLES[source], user)
                rows = question_segments(text)
                if rows:
                    pool.append(
                        {
                            "id": digest[:16],
                            "session": message.session,
                            "source": source,
                            "width": width,
                            "question_segments": rows,
                            "text": text,
                        }
                    )
    pool.sort(key=lambda record: str(record["id"]))
    random.Random(0).shuffle(pool)
    chosen: list[dict[str, object]] = []
    used: dict[str, int] = {}
    ids: set[object] = set()

    def take(candidates: list[dict[str, object]], limit: int) -> None:
        for record in candidates:
            if limit <= 0:
                return
            session = str(record["session"])
            if record["id"] not in ids and used.get(session, 0) < PER_SESSION:
                chosen.append(record)
                ids.add(record["id"])
                used[session] = used.get(session, 0) + 1
                limit -= 1

    several = [r for r in pool if int(r["question_segments"]) >= 2]  # type: ignore[call-overload]
    take(several, multi)
    take([r for r in pool if int(r["question_segments"]) < 2], count - len(chosen))  # type: ignore[call-overload]
    take(pool, count - len(chosen))
    seen["pool"] = len(pool)
    seen["pool_multi"] = len(several)
    seen["short_in_sample"] = sum(len(str(r["text"])) < 300 for r in chosen)
    return chosen, seen


def labels_path(mode: str) -> Path:
    return DATA / f"spike-labels-{mode}.jsonl"


def label_all(mode: str, limit: int | None, workers: int, allow_peak: bool, user: str) -> int:
    key = os.environ.get("DEEPSEEK_API_KEY", "")
    if not key:
        print("spike: DEEPSEEK_API_KEY is not set", file=sys.stderr)
        return 1
    if is_peak(datetime.now(UTC)) and not allow_peak:
        print("spike: peak hours (output costs double); wait or pass --peak", file=sys.stderr)
        return 1
    stage = f"spike-{mode}"
    out, drops = labels_path(mode), DATA / f"spike-drops-{mode}.jsonl"
    done = {str(item["id"]) for item in read_jsonl(out)} if out.exists() else set()
    dropped_before = {str(item["id"]) for item in read_jsonl(drops)} if drops.exists() else set()
    pending = [r for r in read_jsonl(TEXTS) if r["id"] not in done | dropped_before][:limit]
    client = OpenAI(api_key=key, base_url="https://api.deepseek.com", max_retries=0, timeout=900)
    try:
        spend = Spend(DATA / "usage.jsonl", earlier=[OLD_LEDGER])
    except LedgerBusy as error:
        print(f"spike: {error}", file=sys.stderr)
        return 1
    stop = threading.Event()
    before = spend.stages.get(stage, 0.0)

    def work(record: dict[str, object]) -> dict[str, object]:
        if stop.is_set():
            raise KeyboardInterrupt
        return label_text(
            client,
            str(record["text"]),
            spend=spend,
            cache_dir=DATA / "response-cache",
            stage=stage,
            user=user,
            thinking=mode == "think",
        )

    counts = {"labelled": 0, "dropped": 0, "length": 0}
    try:
        for record, result in run_parallel(pending, work, workers, stop):
            if isinstance(result, BaseException):
                result = {"errors": [f"{type(result).__name__}: {result}"]}
            item = {"id": record["id"], "prompt": PROMPT_HASH, "mode": mode, **result}
            if "label" in result:
                counts["labelled"] += 1
                append_jsonl(out, item)
            else:
                counts["dropped"] += 1
                counts["length"] += result["errors"] == ["finish reason length"]
                append_jsonl(drops, item)
    except KeyboardInterrupt:
        stop.set()
        print("spike: interrupted", file=sys.stderr)
    entries = [
        e for e in read_jsonl(DATA / "usage.jsonl") if e.get("stage") == stage and "cost" in e
    ]
    print(
        json.dumps(
            {
                **counts,
                "mode": mode,
                "spend_run": round(spend.stages.get(stage, 0.0) - before, 4),
                "spend_total": round(spend.total, 4),
                "peak_share": round(
                    sum(bool(e.get("peak")) for e in entries) / max(1, len(entries)), 3
                ),
                "prompt": PROMPT_HASH,
            }
        )
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pick = commands.add_parser("sample")
    pick.add_argument("--count", type=int, default=100)
    pick.add_argument("--multi", type=int, default=25)
    run = commands.add_parser("label")
    run.add_argument("--mode", choices=("think", "nothink"), default="think")
    run.add_argument("--limit", type=int)
    run.add_argument("--workers", type=int, default=8)
    run.add_argument("--peak", action="store_true")
    args = parser.parse_args(argv)
    user = getpass.getuser()
    if args.command == "label":
        return label_all(args.mode, args.limit, args.workers, args.peak, user)
    records, seen = sample(args.count, args.multi, user)
    write_jsonl(TEXTS, records)
    print(
        json.dumps(
            {"texts": len(records), "sessions": len({r["session"] for r in records}), **seen}
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
