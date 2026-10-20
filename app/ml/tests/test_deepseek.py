import json
import threading
from pathlib import Path

import httpx2 as httpx
import pytest
from conftest import USER, FakeClient, response
from openai import APIStatusError, APITimeoutError

from deepseek import (
    BudgetExceeded,
    LedgerBusy,
    Spend,
    complete,
    request_body,
    run_parallel,
    usage_of,
    worst_cost,
)

MESSAGES = [{"role": "user", "content": "Pick one? alpha or beta"}]
DEADLINE = 5.0


def spend_in(tmp_path: Path, **kwargs) -> Spend:
    return Spend(tmp_path / "usage.jsonl", **kwargs)


def ask(client, tmp_path: Path, spend: Spend, messages=MESSAGES, nonce: str = "1:0"):
    return complete(
        client,
        messages,
        spend=spend,
        cache_dir=tmp_path / "cache",
        stage="test",
        nonce=nonce,
        user=USER,
        sleep=lambda _: None,
    )


def status_error(code: int) -> APIStatusError:
    request = httpx.Request("POST", "https://x")
    return APIStatusError("x", response=httpx.Response(code, request=request), body=None)


def test_bodies() -> None:
    thinking, plain = request_body(MESSAGES), request_body(MESSAGES, thinking=False)
    assert "temperature" not in thinking
    assert thinking["max_tokens"] == 12000
    assert thinking["extra_body"] == {"thinking": {"type": "enabled"}}
    assert plain["temperature"] == 0
    assert plain["extra_body"] == {"thinking": {"type": "disabled"}}


def test_ledger_counts_the_old_spend_and_writes_the_new_one(tmp_path: Path) -> None:
    old = tmp_path / "old.jsonl"
    old.write_text(json.dumps({"stage": "train", "cost": 26.21}) + "\n")
    spend = spend_in(tmp_path, earlier=[old])
    assert spend.total == pytest.approx(26.21)
    reservation = spend.reserve(0.5, "spike")
    assert spend.total == pytest.approx(26.71)
    spend.settle(reservation, 0.5, "spike", 0.1, {})
    assert spend.total == pytest.approx(26.31)
    spend.close()
    assert old.read_text().count("\n") == 1
    again = spend_in(tmp_path, earlier=[old])
    assert again.total == pytest.approx(26.31)
    again.close()
    with pytest.raises(BudgetExceeded):
        spend_in(tmp_path, limit=26.0, earlier=[old]).reserve(0.01, "spike")


def test_a_reservation_without_a_settle_counts_at_its_maximum_after_a_restart(
    tmp_path: Path,
) -> None:
    spend = spend_in(tmp_path)
    spend.reserve(0.7, "spike")
    spend.close()
    assert spend_in(tmp_path).total == pytest.approx(0.7)


def test_a_second_process_cannot_hold_the_ledger(tmp_path: Path) -> None:
    first = spend_in(tmp_path)
    with pytest.raises(LedgerBusy):
        spend_in(tmp_path)
    first.close()
    spend_in(tmp_path).close()


def test_unredacted_messages_are_refused_before_a_call(tmp_path: Path) -> None:
    client = FakeClient([])
    spend = spend_in(tmp_path)
    for role in ("user", "assistant"):
        with pytest.raises(ValueError, match="not redacted"):
            ask(client, tmp_path, spend, [{"role": role, "content": "mail alice@example.com"}])
    with pytest.raises(ValueError, match="not redacted"):
        ask(client, tmp_path, spend, [{"role": "user", "content": 'password="a b c d e"'}])
    assert client.calls == []


def test_a_cache_hit_does_not_call_or_cost(tmp_path: Path) -> None:
    client = FakeClient(["{}"])
    spend = spend_in(tmp_path)
    first = ask(client, tmp_path, spend)
    paid = spend.total
    assert 0 < paid < 0.01
    assert ask(client, tmp_path, spend) == first
    assert len(client.calls) == 1
    assert spend.total == pytest.approx(paid)


def test_a_stop_on_length_is_returned_without_a_second_call(tmp_path: Path) -> None:
    client = FakeClient([("", "length")])
    assert ask(client, tmp_path, spend_in(tmp_path)) == ("", "length")
    assert len(client.calls) == 1


def test_a_timeout_may_have_been_billed(tmp_path: Path) -> None:
    client = FakeClient([APITimeoutError(request=httpx.Request("POST", "https://x"))])
    spend = spend_in(tmp_path)
    with pytest.raises(APITimeoutError):
        ask(client, tmp_path, spend)
    assert spend.total == pytest.approx(worst_cost(MESSAGES))
    assert len(client.calls) == 1


def test_a_missing_usage_counts_at_the_maximum(tmp_path: Path) -> None:
    spend = spend_in(tmp_path)
    ask(FakeClient([response("{}", usage=False)]), tmp_path, spend)
    assert spend.total == pytest.approx(worst_cost(MESSAGES))


def test_a_rate_limit_is_retried_and_not_billed(tmp_path: Path) -> None:
    client = FakeClient([status_error(429), "{}"])
    spend = spend_in(tmp_path)
    assert ask(client, tmp_path, spend)[0] == "{}"
    assert len(client.calls) == 2
    assert spend.total < 0.01


def test_a_server_error_is_not_retried_and_stays_reserved(tmp_path: Path) -> None:
    client = FakeClient([status_error(500)])
    spend = spend_in(tmp_path)
    with pytest.raises(APIStatusError):
        ask(client, tmp_path, spend)
    assert spend.total == pytest.approx(worst_cost(MESSAGES))


def test_the_input_bound_counts_utf8_bytes() -> None:
    ascii_cost = worst_cost([{"role": "user", "content": "a" * 100}])
    wide_cost = worst_cost([{"role": "user", "content": "日" * 100}])
    assert wide_cost > ascii_cost
    assert wide_cost - ascii_cost == pytest.approx(200 * 1.32 / 1e6)


def test_budget_reservation_is_atomic(tmp_path: Path) -> None:
    spend = spend_in(tmp_path, limit=1.0)
    results: list[str] = []
    barrier = threading.Barrier(2, timeout=DEADLINE)

    def reserve() -> None:
        barrier.wait()
        try:
            spend.reserve(0.6, "spike")
            results.append("ok")
        except BudgetExceeded:
            results.append("stopped")

    threads = [threading.Thread(target=reserve) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(DEADLINE)
    assert sorted(results) == ["ok", "stopped"]
    assert spend.total == pytest.approx(0.6)


def test_usage_uses_cache_hit_and_peak_prices() -> None:
    usage = response("x", prompt=1_000_000).usage
    usage.completion_tokens = 1_000_000
    usage.prompt_cache_hit_tokens = 1_000_000
    usage.prompt_cache_miss_tokens = 0
    assert usage_of(usage, False).cost == pytest.approx(0.022 + 1.98)
    assert usage_of(usage, True).cost == pytest.approx(0.044 + 3.96)


def test_stop_cancels_the_waiting_items() -> None:
    stop = threading.Event()
    gate = threading.Event()
    started: list[int] = []

    def work(item: int) -> int:
        started.append(item)
        if item > 0:
            gate.wait(DEADLINE)
        return item

    results = []
    for item, result in run_parallel(list(range(20)), work, 2, stop):
        results.append((item, result))
        stop.set()
        gate.set()
    assert [item for item, _ in results] == [0]
    assert len(started) < 20
