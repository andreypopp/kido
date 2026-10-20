"""DeepSeek v4-pro client: spend ledger and cap, response cache, retries, parallel runs."""

from __future__ import annotations

import fcntl
import hashlib
import json
import random
import threading
import time
import uuid
from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from openai import APIConnectionError, APIStatusError, APITimeoutError, OpenAI

from jsonl import append_jsonl, read_jsonl
from redact import redact

MODEL = "deepseek-v4-pro"
CACHE_HIT = (0.022, 0.044)
CACHE_MISS = (0.66, 1.32)
OUTPUT = (1.98, 3.96)
MAX_TOKENS = 12000
PEAK_HOURS = ((1, 4), (6, 10))
BUDGET = 50.0
MAX_ATTEMPTS = 5
NOT_BILLED = {429, 503}
DATA = Path("data")
OLD_LEDGER = Path("data-paragraphs/usage.jsonl")


def is_peak(now: datetime) -> bool:
    return now.weekday() < 5 and any(start <= now.hour < end for start, end in PEAK_HOURS)


def request_body(messages: list[dict[str, str]], thinking: bool = True) -> dict[str, object]:
    body: dict[str, object] = {
        "model": MODEL,
        "messages": messages,
        "response_format": {"type": "json_object"},
        "max_tokens": MAX_TOKENS,
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
    prompt_tokens: int
    completion_tokens: int
    cache_hit: int
    cache_miss: int
    reasoning_tokens: int
    peak: bool
    cost: float


def usage_of(usage: object | None, peak: bool) -> Usage:
    if usage is None:
        return Usage(0, 0, 0, 0, 0, peak, 0.0)
    details = getattr(usage, "completion_tokens_details", None)
    prompt_tokens = int(getattr(usage, "prompt_tokens", 0) or 0)
    completion = int(getattr(usage, "completion_tokens", 0) or 0)
    hit = int(getattr(usage, "prompt_cache_hit_tokens", 0) or 0)
    miss = int(getattr(usage, "prompt_cache_miss_tokens", 0) or 0) or max(0, prompt_tokens - hit)
    index = 1 if peak else 0
    cost = (hit * CACHE_HIT[index] + miss * CACHE_MISS[index] + completion * OUTPUT[index]) / 1e6
    reasoning = int(getattr(details, "reasoning_tokens", 0) or 0)
    return Usage(prompt_tokens, completion, hit, miss, reasoning, peak, cost)


class BudgetExceeded(Exception):
    pass


class LedgerBusy(Exception):
    pass


class Spend:
    """Cumulative cost over the old and the new ledger; new entries go to the new one.

    A reservation is written before the call. A call that has no settle entry, because the
    process died or the answer was lost, counts at its reserved maximum. One process holds
    the ledger at a time.
    """

    def __init__(self, path: Path, limit: float = BUDGET, earlier: Iterable[Path] = ()) -> None:
        self.path = path
        self.limit = limit
        self.lock = threading.Lock()
        self.total = 0.0
        self.stages: dict[str, float] = {}
        self.open: dict[str, tuple[float, str]] = {}
        path.parent.mkdir(parents=True, exist_ok=True)
        self.guard = open(path.with_name(path.name + ".lock"), "w")  # noqa: SIM115
        try:
            fcntl.flock(self.guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise LedgerBusy(f"another process holds {path}") from None
        for ledger in (*earlier, path):
            for item in read_jsonl(ledger) if ledger.exists() else []:
                self._add(item)
        for worst, stage in self.open.values():
            self._charge(stage, worst)

    def _charge(self, stage: str, cost: float) -> None:
        self.total += cost
        self.stages[stage] = self.stages.get(stage, 0.0) + cost

    def _add(self, item: dict[str, object]) -> None:
        stage = str(item.get("stage"))
        if "reserve" in item:
            self.open[str(item["id"])] = (float(item["reserve"]), stage)  # type: ignore[arg-type]
        else:
            self.open.pop(str(item.get("id")), None)
            self._charge(stage, float(item.get("cost", 0.0)))  # type: ignore[arg-type]

    def reserve(self, worst: float, stage: str) -> str:
        with self.lock:
            if self.total + worst > self.limit:
                raise BudgetExceeded()
            reservation = uuid.uuid4().hex
            append_jsonl(self.path, {"id": reservation, "stage": stage, "reserve": worst})
            self._charge(stage, worst)
            return reservation

    def settle(
        self, reservation: str, worst: float, stage: str, cost: float, usage: dict[str, object]
    ) -> None:
        with self.lock:
            item = {"id": reservation, "stage": stage, "model": MODEL, **usage, "cost": cost}
            append_jsonl(self.path, {**item, "at": datetime.now(UTC).isoformat(timespec="seconds")})
            self._charge(stage, cost - worst)

    def close(self) -> None:
        self.guard.close()


def worst_cost(messages: list[dict[str, str]]) -> float:
    """Every UTF-8 byte is at most one token."""
    tokens = sum(len(message["content"].encode()) + 20 for message in messages) + 500
    return (tokens * CACHE_MISS[1] + MAX_TOKENS * OUTPUT[1]) / 1e6


def cache_key(body: dict[str, object], nonce: str) -> str:
    payload = json.dumps({"body": body, "nonce": nonce}, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()


def read_cache(cache_dir: Path, key: str) -> tuple[str, str] | None:
    path = cache_dir / f"{key}.json"
    if not path.exists():
        return None
    item = json.loads(path.read_text())
    return item["content"], item["finish_reason"]


def write_cache(cache_dir: Path, key: str, content: str, finish: str) -> None:
    cache_dir.mkdir(parents=True, exist_ok=True)
    (cache_dir / f"{key}.json").write_text(
        json.dumps({"content": content, "finish_reason": finish})
    )


def _send(
    client: OpenAI,
    body: dict[str, object],
    *,
    spend: Spend,
    stage: str,
    sleep: Callable[[float], None],
) -> tuple[str, str]:
    worst = worst_cost(body["messages"])  # type: ignore[arg-type]
    for attempt in range(MAX_ATTEMPTS):
        reservation = spend.reserve(worst, stage)
        try:
            response = client.chat.completions.create(**body)
        except APIStatusError as error:
            if error.status_code not in NOT_BILLED:
                raise
            spend.settle(reservation, worst, stage, 0.0, {})
            if attempt == MAX_ATTEMPTS - 1:
                raise
            sleep(min(30.0, float(2**attempt)) + random.random())
            continue
        except (APIConnectionError, APITimeoutError):
            raise  # the server may have billed it: the reservation stays at its maximum
        usage = getattr(response, "usage", None)
        if usage is None:
            cost, fields = worst, {}
        else:
            counted = usage_of(usage, is_peak(datetime.now(UTC)))
            cost, fields = counted.cost, {k: v for k, v in vars(counted).items() if k != "cost"}
        spend.settle(reservation, worst, stage, cost, fields)
        choice = response.choices[0]
        return choice.message.content or "", str(choice.finish_reason or "stop")
    raise RuntimeError("unreachable")


def complete(
    client: OpenAI,
    messages: list[dict[str, str]],
    *,
    spend: Spend,
    cache_dir: Path,
    stage: str,
    nonce: str,
    user: str,
    thinking: bool = True,
    sleep: Callable[[float], None] = time.sleep,
) -> tuple[str, str]:
    """(content, finish_reason). A message that redaction would change is refused. A cached
    answer costs nothing. A stop on length is returned as it is."""
    for message in messages:
        if (
            message["role"] != "system"
            and redact(message["content"], user=user) != message["content"]
        ):
            raise ValueError("a message is not redacted")
    body = request_body(messages, thinking)
    key = cache_key(body, nonce)
    hit = read_cache(cache_dir, key)
    if hit is not None:
        return hit
    content, finish = _send(client, body, spend=spend, stage=stage, sleep=sleep)
    write_cache(cache_dir, key, content, finish)
    return content, finish


def run_parallel[T, R](
    items: list[T], work: Callable[[T], R], workers: int, stop: threading.Event
) -> Iterable[tuple[T, R | BaseException]]:
    """Results as they finish. Setting stop, or an interrupt, cancels the waiting items."""
    pool = ThreadPoolExecutor(max_workers=workers)
    futures = {pool.submit(work, item): item for item in items}
    try:
        for future in as_completed(futures):
            try:
                yield futures[future], future.result()
            except Exception as error:  # noqa: BLE001 - one failed item must not stop the run
                yield futures[future], error
            if stop.is_set():
                break
    finally:
        stop.set()
        pool.shutdown(wait=False, cancel_futures=True)
