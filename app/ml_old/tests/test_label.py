import json
from datetime import UTC, datetime
from pathlib import Path

from conftest import OFF_PEAK, USER, FakeClient

from deepseek import Spend
from label import BUDGET_STOP, PEAK_STOP, Stage, agree, run_stage
from questions import LENGTH, PROMPT_HASH

TEXT = "Which one do you want?\n- alpha one\n- beta two"
A = {
    "questions": [
        {
            "first": 1,
            "last": 3,
            "words": "Which one do",
            "kind": "choice",
            "options": ["beta two", "alpha one"],
        }
    ]
}
B = {"questions": []}
THREE = Stage("x", 3, 16000)
ONE = Stage("x", 1, 10000)


def sample(key: str, number: int, label: object = None, errors: list[str] | None = None, **extra):
    item = {"id": key, "sample": number, "prompt": PROMPT_HASH, "max_tokens": 16000, **extra}
    return {**item, "label": label} if label is not None else {**item, "errors": errors}


TEXTS = {"a": TEXT, "b": TEXT, "c": TEXT}


def test_two_matching_samples_keep_a_text_with_options_in_text_order() -> None:
    samples = [sample("a", 3, A), sample("a", 1, A), sample("a", 2, B)]
    kept, dropped, undecided = agree(["a"], THREE, samples, TEXTS)
    assert dropped == [] and undecided == [] and kept[0]["agree"] == 2
    assert kept[0]["label"]["questions"][0]["options"] == ["alpha one", "beta two"]


def test_unanimous_is_counted() -> None:
    kept, _, _ = agree(["a"], THREE, [sample("a", n, B) for n in (1, 2, 3)], TEXTS)
    assert kept[0]["agree"] == 3


def test_the_chosen_label_does_not_depend_on_the_file_order() -> None:
    other = {"questions": [{**A["questions"][0], "options": ["alpha one", "beta two"]}]}
    forward = [sample("a", 1, A), sample("a", 2, other), sample("a", 3, B)]
    backward = list(reversed(forward))
    assert agree(["a"], THREE, forward, TEXTS) == agree(["a"], THREE, backward, TEXTS)


def test_drops_say_why_and_missing_samples_are_undecided() -> None:
    samples = [
        sample("a", 1, A), sample("a", 2, B), sample("a", 3, errors=["x"]),
        sample("b", 1, A), sample("b", 2, errors=[LENGTH]), sample("b", 3, errors=["x"]),
        sample("c", 1, errors=["x"]), sample("c", 2, errors=["x"]),
    ]  # fmt: skip
    kept, dropped, undecided = agree(["a", "b", "c", "d"], THREE, samples, {**TEXTS, "d": TEXT})
    assert kept == []
    assert {d["id"]: d["reason"] for d in dropped} == {
        "a": "disagree",
        "b": "length",
        "c": "invalid",
    }
    assert undecided == ["d"]


def test_only_samples_of_the_current_prompt_and_limit_count() -> None:
    old = sample("a", 1, A, prompt="old")
    other = sample("a", 1, A, max_tokens=12000)
    assert agree(["a"], ONE, [old, other], TEXTS)[2] == ["a"]
    assert agree(["a"], ONE, [sample("a", 1, A, max_tokens=10000)], TEXTS)[0][0]["agree"] == 1


def test_a_duplicate_sample_number_is_one_sample() -> None:
    kept, _, undecided = agree(["a"], THREE, [sample("a", 1, A), sample("a", 1, A)], TEXTS)
    assert kept == [] and undecided == ["a"]


def good(label: object) -> str:
    return json.dumps(label)


def run(
    tmp_path: Path,
    stage: Stage,
    ids: list[str],
    replies: list[object],
    limit: float = 48.0,
    clock=OFF_PEAK,
):
    client = FakeClient(replies)
    spend = Spend(tmp_path / "usage.jsonl", limit=limit)
    status, counts = run_stage(
        client, spend, stage, "t", ids, {i: f"{TEXT}\nNote {i}." for i in ids},
        samples_file=tmp_path / "samples.jsonl", cache_dir=tmp_path / "cache", workers=1,
        user=USER, clock=clock, sleep=lambda _: None,
    )  # fmt: skip
    spend.close()
    return status, counts, client


def done(tmp_path: Path) -> set[tuple[str, int]]:
    path = tmp_path / "samples.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    return {(r["id"], r["sample"]) for r in rows}


def test_a_budget_stop_is_not_a_sample_and_a_resume_finishes(tmp_path: Path) -> None:
    status, _, _ = run(tmp_path, ONE, ["a", "b", "c"], [good(B)] * 3, limit=0.001)
    assert status == BUDGET_STOP and done(tmp_path) == set()
    status, counts, _ = run(tmp_path, ONE, ["a", "b", "c"], [good(B)] * 3)
    assert (
        status == 0 and counts["labels"] == 3 and done(tmp_path) == {("a", 1), ("b", 1), ("c", 1)}
    )
    status, counts, client = run(tmp_path, ONE, ["a", "b", "c"], [])
    assert status == 0 and client.calls == []


def test_a_peak_stop_during_a_wave_leaves_the_rest_pending(tmp_path: Path) -> None:
    times = iter(
        [datetime(2026, 10, 21, 12, tzinfo=UTC)] * 2
        + [datetime(2026, 10, 21, 0, 50, tzinfo=UTC)] * 50
    )
    status, _, client = run(tmp_path, ONE, ["a", "b"], [good(B)] * 2, clock=lambda: next(times))
    assert status == PEAK_STOP and len(client.calls) == 1
    assert done(tmp_path) == {("a", 1)}


def test_sample_three_is_skipped_when_two_agreement_is_impossible(tmp_path: Path) -> None:
    status, _, client = run(tmp_path, THREE, ["a"], [good({"questions": "x"})] * 4)
    assert status == 0 and done(tmp_path) == {("a", 1), ("a", 2)}
    assert len(client.calls) == 4  # each sample: the answer and its correction


def test_transport_errors_are_not_samples(tmp_path: Path) -> None:
    status, counts, _ = run(tmp_path, ONE, ["a"], [RuntimeError("boom")])
    assert status != 0 and done(tmp_path) == set() and counts["RuntimeError"] == 1
