import json
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

import label
from label import (
    BudgetExceeded,
    Spend,
    dry_run,
    label_sample,
    parse_response,
    pending_records,
    request_body,
    run_family,
    usage_of,
)
from render import detached

PROMPT = "  1: Intro.\n> 2: Pick one? alpha or beta"
LABEL = {"lines": ["other", "question"], "options": []}


def response(content: str, *, finish: str = "stop", prompt: int = 100, completion: int = 10):
    return SimpleNamespace(
        choices=[
            SimpleNamespace(
                message=SimpleNamespace(content=content), finish_reason=finish
            )
        ],
        usage=SimpleNamespace(
            prompt_tokens=prompt,
            completion_tokens=completion,
            prompt_cache_hit_tokens=20,
            prompt_cache_miss_tokens=prompt - 20,
            completion_tokens_details=SimpleNamespace(reasoning_tokens=4),
        ),
    )


class FakeClient:
    def __init__(self, replies: list[object]) -> None:
        self.replies = list(replies)
        self.calls: list[dict[str, object]] = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        item = self.replies.pop(0) if self.replies else response(json.dumps(LABEL))
        if isinstance(item, Exception):
            raise item
        if isinstance(item, tuple):
            return response(content=item[0], finish=item[1])
        return response(str(item))

    @property
    def chat(self):
        return SimpleNamespace(completions=self)


def spend(tmp_path: Path, limit: float = 40.0) -> Spend:
    return Spend(tmp_path / "usage.jsonl", limit=limit)


def test_request_bodies_do_not_send_temperature_when_thinking() -> None:
    messages = [{"role": "user", "content": PROMPT}]
    flash = request_body("deepseek-flash", messages, False)
    pro = request_body("deepseek-v4-pro", messages, True)
    assert flash["temperature"] == 0
    assert "temperature" not in pro
    assert pro["max_tokens"] == 16384
    assert pro["extra_body"] == {"thinking": {"type": "enabled"}}


def test_dry_run_writes_exactly_the_call_body(tmp_path: Path) -> None:
    output = tmp_path / "requests.jsonl"
    counts = dry_run([{"id": "a", "prompt": PROMPT}], output, "deepseek-flash", False)
    assert counts == {"requests": 1}
    body = json.loads(output.read_text())
    messages = [
        {
            "role": "system",
            "content": label.SYSTEM + "\nReturn exactly 2 line classes.",
        },
        {"role": "user", "content": detached(PROMPT)},
    ]
    assert body == request_body("deepseek-flash", messages, False)
    assert "> 2:" not in body["messages"][1]["content"]


def test_unredacted_input_is_refused(tmp_path: Path) -> None:
    client = FakeClient([])
    result = label_sample(
        client,
        "deepseek-flash",
        "email alice@example.com",
        "alice",
        thinking=False,
        spend=spend(tmp_path),
        stage="test",
        sample=1,
    )
    assert result["errors"] == ["input is not redacted"]
    assert client.calls == []


def test_retry_redacts_the_model_output(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(label, "RESPONSE_CACHE", tmp_path / "cache")
    bad = json.dumps({"lines": ["other"], "note": "alice@example.com"})
    client = FakeClient([bad, json.dumps(LABEL)])
    result = label_sample(
        client,
        "deepseek-flash",
        PROMPT,
        "alice",
        thinking=False,
        spend=spend(tmp_path),
        stage="test",
        sample=1,
    )
    assert result["label"] == LABEL
    retry = client.calls[1]["messages"]
    assert all("alice@example.com" not in str(message["content"]) for message in retry)
    assert any("user@example.com" in str(message["content"]) for message in retry)


def test_cache_hit_does_not_call_or_cost(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(label, "RESPONSE_CACHE", tmp_path / "cache")
    client = FakeClient([json.dumps(LABEL)])
    tracker = spend(tmp_path)
    for _ in range(2):
        result = label_sample(
            client,
            "deepseek-flash",
            PROMPT,
            "alice",
            thinking=False,
            spend=tracker,
            stage="test",
            sample=1,
        )
        assert result["label"] == LABEL
    assert len(client.calls) == 1
    assert tracker.cached_hits == 1
    assert tracker.total > 0


def test_length_stop_resamples_without_a_correction_turn(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(label, "RESPONSE_CACHE", tmp_path / "cache")
    client = FakeClient([("", "length"), json.dumps(LABEL)])
    result = label_sample(
        client,
        "deepseek-v4-pro",
        PROMPT,
        "alice",
        thinking=True,
        spend=spend(tmp_path),
        stage="test",
        sample=1,
    )
    assert result["label"] == LABEL
    assert len(client.calls) == 2
    assert client.calls[0]["messages"] == client.calls[1]["messages"]
    assert "temperature" not in client.calls[0]


def test_budget_reservation_is_atomic(tmp_path: Path) -> None:
    tracker = spend(tmp_path, limit=1.0)
    results: list[str] = []
    barrier = threading.Barrier(2)

    def reserve() -> None:
        barrier.wait()
        try:
            tracker.reserve(0.6)
            results.append("ok")
        except BudgetExceeded:
            results.append("stopped")

    threads = [threading.Thread(target=reserve) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert sorted(results) == ["ok", "stopped"]
    assert tracker.reserved == pytest.approx(0.6)


def test_usage_uses_cache_hit_and_peak_prices(tmp_path: Path) -> None:
    usage = SimpleNamespace(
        prompt_tokens=1_000_000,
        completion_tokens=1_000_000,
        prompt_cache_hit_tokens=1_000_000,
        prompt_cache_miss_tokens=0,
        completion_tokens_details=SimpleNamespace(reasoning_tokens=10),
    )
    off_peak = usage_of("deepseek-flash", usage, False)
    peak = usage_of("deepseek-v4-pro", usage, True)
    assert off_peak.cost == pytest.approx(0.003 + 0.60)
    assert peak.cost == pytest.approx(0.044 + 3.96)
    assert peak.reasoning_tokens == 10


def test_run_family_agrees_and_saves_every_sample(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(label, "RESPONSE_CACHE", tmp_path / "cache")
    client = FakeClient([json.dumps(LABEL)] * 5)
    samples: list[dict[str, object]] = []
    result = run_family(
        client,
        {"id": "a", "prompt": PROMPT},
        model="deepseek-flash",
        samples=5,
        thinking=False,
        spend=spend(tmp_path),
        stage="test",
        user="alice",
        sink=samples.append,
    )
    assert result["agree"] is True
    assert result["label"] == LABEL
    assert len(samples) == 5
    assert {record["sample"] for record in samples} == {1, 2, 3, 4, 5}


def test_run_family_stops_at_disagreement(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(label, "RESPONSE_CACHE", tmp_path / "cache")
    other = json.dumps({"lines": ["question", "other"], "options": []})
    client = FakeClient([json.dumps(LABEL)] * 4 + [other])
    samples: list[dict[str, object]] = []
    result = run_family(
        client,
        {"id": "a", "prompt": PROMPT},
        model="deepseek-flash",
        samples=5,
        thinking=False,
        spend=spend(tmp_path),
        stage="test",
        user="alice",
        sink=samples.append,
    )
    assert result["agree"] is False
    assert "disagree" in result["errors"][0]
    assert 2 <= len(samples) <= 5


def test_run_family_stops_at_invalid_sample(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(label, "RESPONSE_CACHE", tmp_path / "cache")
    client = FakeClient([json.dumps(LABEL), "not json"])
    samples: list[dict[str, object]] = []
    result = run_family(
        client,
        {"id": "a", "prompt": PROMPT},
        model="deepseek-flash",
        samples=5,
        thinking=False,
        spend=spend(tmp_path),
        stage="test",
        user="alice",
        sink=samples.append,
    )
    assert "agree" not in result
    assert "sample invalid" in result["errors"][0]
    assert len(samples) == 2


def test_budget_exceeded_makes_no_call(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(label, "RESPONSE_CACHE", tmp_path / "cache")
    client = FakeClient([json.dumps(LABEL)])
    tracker = spend(tmp_path, limit=0.0)
    with pytest.raises(BudgetExceeded):
        label_sample(
            client,
            "deepseek-flash",
            PROMPT,
            "alice",
            thinking=False,
            spend=tracker,
            stage="test",
            sample=1,
        )
    assert client.calls == []


def test_resume_skips_labelled_and_finished_samples(tmp_path: Path) -> None:
    output = tmp_path / "labels.jsonl"
    output.write_text(
        "\n".join(
            json.dumps(item)
            for item in (
                {"id": "a", "label": LABEL},
                {"id": "b", "agree": False, "errors": ["samples disagree"]},
            )
        )
        + "\n"
    )
    records = [{"id": identifier, "prompt": PROMPT} for identifier in ("a", "b", "c")]
    existing, pending = pending_records(records, output, True)
    assert sorted(existing) == ["a", "b"]
    assert [record["id"] for record in pending] == ["c"]


def test_parse_response_accepts_fences() -> None:
    assert parse_response('```json\n{"lines": []}\n```') == {"lines": []}
