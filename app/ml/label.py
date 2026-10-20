"""Label redacted contexts with DeepSeek. The key comes from the environment only."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import random
import sys
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from openai import APIConnectionError, APIStatusError, APITimeoutError, OpenAI

from redact import redact
from render import (
    detached,
    hash_records,
    prompt_lines,
    read_json,
    read_jsonl,
    write_jsonl,
)
from validate import canonical_label, label_errors, rejection_class

SYSTEM = """You label terminal text for a paragraph question detector.
Read the numbered lines. A question unit is a question paragraph and its answer options.
Return JSON only, with this exact shape:
{"lines": ["other", "question", ...], "options": [{"line": 4, "text": "exact option"}]}

Rules:
- "lines" has one class for every numbered line: "question", "option" or "other".
- Label every question unit in the text, not only the hovered paragraph.
- An option on a line that starts with a list marker ("1.", "-", "a)") has class "option".
  The marker is not part of the option text.
- An option inside a question sentence stays on a "question" line and also appears in "options".
- Example list: "  1: Pick one?" then "  2: 1. Red" then "  3: 2. Blue".
  Lines 2 and 3 are "option".
- Example inline: "  1: Should I use alpha or beta?".
  Line 1 is "question", and "alpha" and "beta" are options.
- Every option appears in "options" with its exact text as it appears on its line, without the
  list marker. Copy the text exactly. Do not invent text.
- A question without options has only "question" lines and an empty "options" list.
- Plain prose, code, logs, tables and numbered steps are "other".
- A question and its option lines form one contiguous unit. Blank lines may separate them.
- A context can hold more than one question unit. Each unit is contiguous on its own.
"""

PROMPT_VERSION = "phase1-v3"
MODELS = {
    "deepseek-flash": {
        "name": "DeepSeek-V4.1-Flash",
        "version": "DeepSeek-V4.1-Flash-1017",
        "cache_hit": (0.003, 0.006),
        "cache_miss": (0.15, 0.30),
        "output": (0.60, 1.20),
        "max_tokens": 2048,
    },
    "deepseek-v4-pro": {
        "name": "DeepSeek-V4-Pro",
        "version": "DeepSeek-V4-Pro-0813",
        "cache_hit": (0.022, 0.044),
        "cache_miss": (0.66, 1.32),
        "output": (1.98, 3.96),
        "max_tokens": 16384,
    },
}
ALIASES = {"flash": "deepseek-flash", "pro": "deepseek-v4-pro"}
PEAK_HOURS = ((1, 4), (6, 10))
BUDGET = 40.0
MAX_ATTEMPTS = 5
TRANSIENT = {429, 500, 502, 503, 504}


def is_peak(now: datetime) -> bool:
    if now.weekday() >= 5:
        return False
    return any(start <= now.hour < end for start, end in PEAK_HOURS)


def resolve_model(name: str) -> str:
    return ALIASES.get(name, name)


def request_body(model: str, messages: list[dict[str, str]], thinking: bool) -> dict[str, object]:
    body: dict[str, object] = {
        "model": model,
        "messages": messages,
        "response_format": {"type": "json_object"},
        "max_tokens": MODELS[model]["max_tokens"],
        "extra_body": {"thinking": {"type": "enabled" if thinking else "disabled"}},
    }
    if not thinking:
        body["temperature"] = 0
    return body


def parse_response(content: str) -> object:
    content = content.strip()
    if content.startswith("```"):
        content = content.split("\n", 1)[1] if "\n" in content else content
        content = content.rsplit("```", 1)[0]
    return json.loads(content)


@dataclass(frozen=True)
class Usage:
    model: str
    prompt_tokens: int
    completion_tokens: int
    cache_hit: int
    cache_miss: int
    reasoning_tokens: int
    peak: bool
    cost: float


def usage_of(model: str, usage: object | None, peak: bool) -> Usage:
    if usage is None:
        return Usage(model, 0, 0, 0, 0, 0, peak, 0.0)
    details = getattr(usage, "completion_tokens_details", None)
    reasoning = int(getattr(details, "reasoning_tokens", 0) or 0)
    prompt_tokens = int(getattr(usage, "prompt_tokens", 0) or 0)
    completion = int(getattr(usage, "completion_tokens", 0) or 0)
    hit = int(getattr(usage, "prompt_cache_hit_tokens", 0) or 0)
    miss = int(getattr(usage, "prompt_cache_miss_tokens", 0) or 0)
    if miss == 0:
        miss = max(0, prompt_tokens - hit)
    prices = MODELS[model]
    index = 1 if peak else 0
    cost = (
        hit * prices["cache_hit"][index]
        + miss * prices["cache_miss"][index]
        + completion * prices["output"][index]
    ) / 1_000_000
    return Usage(model, prompt_tokens, completion, hit, miss, reasoning, peak, cost)


class BudgetExceeded(Exception):
    pass


class Spend:
    def __init__(self, path: Path, limit: float = BUDGET) -> None:
        self.path = path
        self.limit = limit
        self.lock = threading.Lock()
        self.total = 0.0
        self.reserved = 0.0
        self.cached_hits = 0
        self.models: dict[str, dict[str, float]] = {}
        self.stages: dict[str, dict[str, float]] = {}
        if path.exists():
            for item in read_jsonl(path):
                self._account(item)

    def _account(self, item: dict[str, object]) -> None:
        cost = float(item.get("cost", 0.0))
        self.total += cost
        keys = (
            (self.models, str(item.get("model"))),
            (self.stages, str(item.get("stage"))),
        )
        for table, key in keys:
            values = table.setdefault(
                key,
                {
                    "requests": 0,
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "cache_hit": 0,
                    "cache_miss": 0,
                    "reasoning_tokens": 0,
                    "peak_requests": 0,
                    "cached_requests": 0,
                    "cost": 0.0,
                },
            )
            values["requests"] += 1
            for field in (
                "prompt_tokens",
                "completion_tokens",
                "cache_hit",
                "cache_miss",
                "reasoning_tokens",
            ):
                values[field] += int(item.get(field, 0))
            values["peak_requests"] += 1 if item.get("peak") else 0
            values["cached_requests"] += 1 if item.get("cached") else 0
            values["cost"] += cost

    def reserve(self, worst: float) -> None:
        with self.lock:
            if self.total + self.reserved + worst > self.limit:
                raise BudgetExceeded()
            self.reserved += worst

    def release(self, worst: float) -> None:
        with self.lock:
            self.reserved = max(0.0, self.reserved - worst)

    def _write(self, usage: Usage, stage: str, cached: bool) -> None:
        item = {
            "stage": stage,
            "model": usage.model,
            "prompt_tokens": usage.prompt_tokens,
            "completion_tokens": usage.completion_tokens,
            "cache_hit": usage.cache_hit,
            "cache_miss": usage.cache_miss,
            "reasoning_tokens": usage.reasoning_tokens,
            "peak": usage.peak,
            "cached": cached,
            "cost": usage.cost,
            "at": datetime.now(UTC).isoformat(timespec="seconds"),
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(item) + "\n")

    def settle(self, worst: float, usage: Usage, stage: str) -> None:
        with self.lock:
            self.reserved = max(0.0, self.reserved - worst)
            self._account(
                {
                    "model": usage.model,
                    "stage": stage,
                    "prompt_tokens": usage.prompt_tokens,
                    "completion_tokens": usage.completion_tokens,
                    "cache_hit": usage.cache_hit,
                    "cache_miss": usage.cache_miss,
                    "reasoning_tokens": usage.reasoning_tokens,
                    "peak": usage.peak,
                    "cost": usage.cost,
                }
            )
            self._write(usage, stage, False)

    def cached(self, usage: Usage, stage: str) -> None:
        with self.lock:
            self.cached_hits += 1
            free = Usage(
                usage.model,
                usage.prompt_tokens,
                usage.completion_tokens,
                usage.cache_hit,
                usage.cache_miss,
                usage.reasoning_tokens,
                usage.peak,
                0.0,
            )
            self._account(
                {
                    "model": free.model,
                    "stage": stage,
                    "prompt_tokens": free.prompt_tokens,
                    "completion_tokens": free.completion_tokens,
                    "cache_hit": free.cache_hit,
                    "cache_miss": free.cache_miss,
                    "reasoning_tokens": free.reasoning_tokens,
                    "peak": free.peak,
                    "cached": True,
                    "cost": 0.0,
                }
            )
            self._write(free, stage, True)

    def over(self) -> bool:
        with self.lock:
            return self.total >= self.limit

    def snapshot(self, table: dict[str, dict[str, float]], key: str | None = None) -> object:
        with self.lock:
            if key is None:
                return json.loads(json.dumps(table))
            return json.loads(json.dumps(table.get(key, {})))


def worst_cost(model: str, messages: list[dict[str, str]]) -> float:
    prices = MODELS[model]
    characters = sum(len(str(message["content"])) for message in messages) + 500
    return (
        characters * prices["cache_miss"][1]
        + int(prices["max_tokens"]) * prices["output"][1]
    ) / 1_000_000


def cache_key(body: dict[str, object], nonce: str) -> str:
    payload = json.dumps({"body": body, "nonce": nonce}, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()


RESPONSE_CACHE = Path("data/response-cache")


def cache_path(key: str) -> Path:
    return RESPONSE_CACHE / f"{key}.json"


def cached_response(key: str, model: str) -> tuple[str, str, Usage] | None:
    item = read_json(cache_path(key))
    if not isinstance(item, dict):
        return None
    usage = item.get("usage", {})
    return (
        str(item.get("content", "")),
        str(item.get("finish_reason", "stop")),
        Usage(
            model,
            int(usage.get("prompt_tokens", 0)),
            int(usage.get("completion_tokens", 0)),
            int(usage.get("cache_hit", 0)),
            int(usage.get("cache_miss", 0)),
            int(usage.get("reasoning_tokens", 0)),
            bool(usage.get("peak", False)),
            0.0,
        ),
    )


def save_response(key: str, content: str, finish_reason: str, usage: Usage) -> None:
    path = cache_path(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "content": content,
                "finish_reason": finish_reason,
                "usage": {
                    "prompt_tokens": usage.prompt_tokens,
                    "completion_tokens": usage.completion_tokens,
                    "cache_hit": usage.cache_hit,
                    "cache_miss": usage.cache_miss,
                    "reasoning_tokens": usage.reasoning_tokens,
                    "peak": usage.peak,
                },
            }
        )
        + "\n"
    )


def _send(
    client: OpenAI,
    model: str,
    thinking: bool,
    messages: list[dict[str, str]],
    *,
    spend: Spend,
    stage: str,
    nonce: str,
    user: str,
    sleep=time.sleep,
) -> tuple[str, str]:
    safe = [
        {"role": str(message["role"]), "content": redact(str(message["content"]), user=user)}
        for message in messages
    ]
    body = request_body(model, safe, thinking)
    key = cache_key(body, nonce)
    hit = cached_response(key, model)
    if hit is not None:
        content, finish_reason, usage = hit
        spend.cached(usage, stage)
        if finish_reason != "length":
            return content, finish_reason
    worst = worst_cost(model, safe)
    for attempt in range(MAX_ATTEMPTS):
        spend.reserve(worst)
        try:
            response = client.chat.completions.create(**body)
        except (APIStatusError, APIConnectionError, APITimeoutError) as error:
            spend.release(worst)
            status = getattr(error, "status_code", None)
            transient = isinstance(error, (APIConnectionError, APITimeoutError)) or (
                status in TRANSIENT
            )
            if not transient or attempt == MAX_ATTEMPTS - 1:
                raise
            sleep(min(30.0, float(2**attempt)) + random.random())
            continue
        usage = usage_of(model, getattr(response, "usage", None), is_peak(datetime.now(UTC)))
        spend.settle(worst, usage, stage)
        content = response.choices[0].message.content or ""
        finish_reason = str(response.choices[0].finish_reason or "stop")
        save_response(key, content, finish_reason, usage)
        return content, finish_reason
    raise RuntimeError("unreachable")


def label_sample(
    client: OpenAI,
    model: str,
    prompt: str,
    user: str,
    *,
    thinking: bool,
    spend: Spend,
    stage: str,
    sample: int,
    sleep=time.sleep,
) -> dict[str, object]:
    redacted = redact(prompt, user=user)
    if redacted != prompt:
        return {"sample": sample, "errors": ["input is not redacted"]}
    messages = [
        {
            "role": "system",
            "content": SYSTEM + f"\nReturn exactly {len(prompt_lines(prompt))} line classes.",
        },
        {"role": "user", "content": detached(prompt)},
    ]
    errors: list[str] = []
    raw = ""
    for attempt in range(2):
        payload = messages
        if errors:
            correction = redact("; ".join(errors[:5]), user=user)
            payload = messages + [
                {"role": "assistant", "content": redact(raw, user=user)},
                {
                    "role": "user",
                    "content": f"Your label was rejected: {correction}. Correct it.",
                },
            ]
        finish = ""
        for resample in range(3):
            raw, finish = _send(
                client,
                model,
                thinking,
                payload,
                spend=spend,
                stage=stage,
                nonce=f"{sample}:{attempt}:{resample}",
                user=user,
                sleep=sleep,
            )
            if finish != "length":
                break
        if finish == "length":
            return {"sample": sample, "errors": ["finish reason length"]}
        try:
            label = parse_response(raw)
        except json.JSONDecodeError as error:
            errors = [f"not JSON: {error}"]
            continue
        problems = label_errors(prompt, label)
        if not problems:
            return {"sample": sample, "label": label}
        errors = problems
    return {"sample": sample, "errors": errors, "raw": raw}


def append_sample(path: Path, item: dict[str, object]) -> None:
    line = (json.dumps(item) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, line)
    finally:
        os.close(descriptor)


def run_family(
    client: OpenAI,
    record: dict[str, object],
    *,
    model: str,
    samples: int,
    thinking: bool,
    spend: Spend,
    stage: str,
    user: str,
    sink,
    stop: threading.Event | None = None,
    sleep=time.sleep,
) -> dict[str, object]:
    identifier = str(record["id"])
    prompt = str(record["prompt"])
    settings = {
        "model": model,
        "thinking": thinking,
        "temperature": None if thinking else 0,
        "max_tokens": MODELS[model]["max_tokens"],
        "samples": samples,
        "prompt": PROMPT_VERSION,
    }
    first = label_sample(
        client,
        model,
        prompt,
        user,
        thinking=thinking,
        spend=spend,
        stage=stage,
        sample=1,
        sleep=sleep,
    )
    first["id"] = identifier
    first["settings"] = settings
    sink(first)
    if "label" not in first:
        return {
            "id": identifier,
            "errors": first.get("errors", ["invalid"]),
            "settings": settings,
        }
    labels = [first["label"]]
    if samples > 1:
        with ThreadPoolExecutor(max_workers=max(1, samples - 1)) as pool:
            futures = {
                pool.submit(
                    label_sample,
                    client,
                    model,
                    prompt,
                    user,
                    thinking=thinking,
                    spend=spend,
                    stage=stage,
                    sample=index,
                    sleep=sleep,
                ): index
                for index in range(2, samples + 1)
            }
            for future in as_completed(futures):
                if stop is not None and stop.is_set():
                    for pending in futures:
                        pending.cancel()
                    break
                result = future.result()
                result["id"] = identifier
                result["settings"] = settings
                sink(result)
                if "label" not in result:
                    for pending in futures:
                        pending.cancel()
                    return {
                        "id": identifier,
                        "errors": [f"sample invalid: {result.get('errors', ['invalid'])[0]}"],
                        "settings": settings,
                    }
                labels.append(result["label"])
                keys = {
                    json.dumps(canonical_label(label, prompt), sort_keys=True)
                    for label in labels
                }
                if len(keys) != 1:
                    for pending in futures:
                        pending.cancel()
                    return {
                        "id": identifier,
                        "agree": False,
                        "samples": len(labels),
                        "errors": [f"samples disagree: {len(keys)} distinct labels"],
                        "settings": settings,
                    }
    if len(labels) != samples:
        return {
            "id": identifier,
            "agree": False,
            "samples": len(labels),
            "errors": [f"expected {samples} samples, got {len(labels)}"],
            "settings": settings,
        }
    return {
        "id": identifier,
        "agree": True,
        "samples": samples,
        "label": labels[0],
        "settings": settings,
    }


def pending_records(
    records: list[dict[str, object]], output: Path, resume: bool
) -> tuple[dict[str, dict[str, object]], list[dict[str, object]]]:
    existing: dict[str, dict[str, object]] = {}
    if resume and output.exists():
        for item in read_jsonl(output):
            if item.get("label") is not None or item.get("agree") is False:
                existing[str(item["id"])] = item
    return existing, [record for record in records if str(record["id"]) not in existing]


def dry_run(
    records: list[dict[str, object]], output: Path, model: str, thinking: bool
) -> dict[str, int]:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        for record in records:
            prompt = str(record["prompt"])
            messages = [
                {
                    "role": "system",
                    "content": SYSTEM
                    + f"\nReturn exactly {len(prompt_lines(prompt))} line classes.",
                },
                {"role": "user", "content": detached(prompt)},
            ]
            handle.write(json.dumps(request_body(model, messages, thinking)) + "\n")
    return {"requests": len(records)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("data/contexts-train.jsonl"))
    parser.add_argument("--output", type=Path, default=Path("data/labels-train.jsonl"))
    parser.add_argument("--model", default="flash")
    parser.add_argument("--samples", type=int, default=1)
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--stage", default="label")
    parser.add_argument("--budget", type=float, default=BUDGET)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args(argv)

    model = resolve_model(args.model)
    if model not in MODELS:
        print(f"label: unknown model {args.model}", file=sys.stderr)
        return 1
    thinking = model == "deepseek-v4-pro"
    key = os.environ.get("DEEPSEEK_API_KEY", "")
    user = getpass.getuser()
    records = [record for record in read_jsonl(args.input) if record.get("source") != "ask"]
    existing, pending = pending_records(records, args.output, args.resume)
    if args.limit is not None:
        pending = pending[: args.limit]
    if args.dry_run:
        counts = dry_run(pending, Path("data/dry-run-requests.jsonl"), model, thinking)
        print(json.dumps(counts, sort_keys=True))
        return 0
    if not key and pending:
        print("label: DEEPSEEK_API_KEY is not set", file=sys.stderr)
        return 1

    client = (
        OpenAI(api_key=key, base_url="https://api.deepseek.com", max_retries=0, timeout=900)
        if pending
        else None
    )
    spend = Spend(Path("data/usage.jsonl"), args.budget)
    started = datetime.now(UTC)
    stop = threading.Event()
    samples_path = Path(f"data/{args.stage}-samples.jsonl")
    drop_path = Path(f"data/{args.stage}-drops.jsonl")
    results: list[dict[str, object]] = list(existing.values())
    counts: Counter[str] = Counter()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("a", encoding="utf-8") as out, drop_path.open(
        "a", encoding="utf-8"
    ) as drops:
        def sink(item: dict[str, object]) -> None:
            append_sample(samples_path, item)

        pool = ThreadPoolExecutor(max_workers=args.workers)
        futures = {
            pool.submit(
                run_family,
                client,
                record,
                model=model,
                samples=args.samples,
                thinking=thinking,
                spend=spend,
                stage=args.stage,
                user=user,
                sink=sink,
                stop=stop,
            ): record
            for record in pending
        }
        try:
            for future in as_completed(futures):
                try:
                    result = future.result()
                except BudgetExceeded:
                    counts["skipped_budget"] += 1
                    continue
                except Exception as error:  # noqa: BLE001 - one bad request must not stop the run
                    record = futures[future]
                    result = {
                        "id": str(record["id"]),
                        "errors": [f"{type(error).__name__}: {error}"],
                    }
                counts["attempted"] += 1
                line = json.dumps(result) + "\n"
                if result.get("label") is not None:
                    counts["labelled"] += 1
                    out.write(line)
                    out.flush()
                else:
                    counts["dropped"] += 1
                    drops.write(line)
                    drops.flush()
                results.append(result)
        except KeyboardInterrupt:
            stop.set()
            for future in futures:
                future.cancel()
            pool.shutdown(wait=False, cancel_futures=True)
            print("label: interrupted", file=sys.stderr)
        finally:
            pool.shutdown(wait=False, cancel_futures=True)

    input_ids = {str(record["id"]) for record in records}
    merged: dict[str, dict[str, object]] = {}
    for item in results:
        if str(item["id"]) in input_ids:
            merged[str(item["id"])] = item
    ordered = [merged[identifier] for identifier in sorted(merged)]
    write_jsonl(args.output, ordered)
    classes: Counter[str] = Counter()
    for item in read_jsonl(drop_path) if drop_path.exists() else []:
        for error in item.get("errors", []):
            classes[rejection_class([str(error)])] += 1
    finished = datetime.now(UTC)
    meta = {
        "stage": args.stage,
        "input": str(args.input),
        "output": str(args.output),
        "input_hash": hashlib.sha256(args.input.read_bytes()).hexdigest()
        if args.input.exists()
        else None,
        "output_hash": hash_records(
            [item for item in ordered if item.get("label") is not None]
        ),
        "prompt_version": PROMPT_VERSION,
        "prompt_hash": hashlib.sha256(SYSTEM.encode()).hexdigest(),
        "hover_marker_sent": False,
        "model": {"id": model, **MODELS[model]},
        "samples": args.samples,
        "thinking": thinking,
        "temperature": None if thinking else 0,
        "temperature_ignored": thinking,
        "workers": args.workers,
        "budget": args.budget,
        "started": started.isoformat(timespec="seconds"),
        "finished": finished.isoformat(timespec="seconds"),
        "wall_seconds": (finished - started).total_seconds(),
        "contexts": len(records),
        "pending": len(pending),
        "resumed": len(existing),
        "attempted": len(ordered),
        "labelled": sum(1 for item in ordered if item.get("label") is not None),
        "dropped": sum(1 for item in ordered if item.get("label") is None),
        "skipped_budget": counts["skipped_budget"],
        "drop_classes": dict(classes),
        "cache_hits": spend.cached_hits,
        "spend_total": spend.total,
        "budget_hit": spend.total >= args.budget,
        "spend": spend.snapshot(spend.models, model),
        "stage_spend": spend.snapshot(spend.stages, args.stage),
    }
    Path(f"data/label-{args.stage}-meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(
        json.dumps(
            {
                key: meta[key]
                for key in (
                    "model",
                    "samples",
                    "labelled",
                    "dropped",
                    "skipped_budget",
                    "spend_total",
                    "budget_hit",
                    "wall_seconds",
                )
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
