from pathlib import Path

import pytest

import build
from jsonl import read_jsonl, write_jsonl
from questions import PROMPT_HASH, question_item
from synthetic import generate

FILLERS = [f"This is filler sentence number {n} about the build." for n in range(40)]


def text_of(n: int, question: bool) -> str:
    tail = "Which one do you prefer?" if question else "Nothing else changed."
    return f"Distinct opening number {n} about topic t{n}t. {tail}"


def candidate(key: str, session: str, question: bool) -> dict[str, object]:
    number = int(key[1:])
    return {
        "id": key,
        "session": session,
        "source": "pi",
        "width": 80,
        "question_segments": int(question),
        "question_paragraphs": int(question),
        "text": text_of(number, question),
    }


def item(key: str, text: str, with_question: bool) -> dict[str, object]:
    questions = [question_item(text, 2, 2, "open")] if with_question else []
    return {
        "id": key,
        "label": {"questions": questions},
        "agree": 2,
        "samples": 3,
        "prompt": PROMPT_HASH,
    }


@pytest.fixture
def world(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> dict[str, list[str]]:
    ids = {
        "eval-real": ["e1", "e2"],
        "eval-negative": ["e3", "e4"],
        "negative-sample": ["e5", "t6"],
        "train-real": [f"t{n}" for n in range(10, 40)],
        "train-negative": [f"t{n}" for n in range(100, 106)],
    }
    texts = [candidate(k, "E", k in ("e1", "e2", "e4")) for k in ids["eval-real"] + ["e3", "e4"]]
    texts += [candidate("e5", "E", False), candidate("t6", "T", False)]
    texts += [candidate(k, f"T{n}", True) for n, k in enumerate(ids["train-real"])]
    texts += [candidate(f"t{n}", "T", False) for n in range(100, 110)]
    by_id = {str(t["id"]): t for t in texts}
    plan = {"eval_sessions": ["E"], "old_eval": 1, "ask": 0, "moved_to_train": 0, "hash": "h"}
    selection = {
        "hashes": {},
        "train_dropped_as_eval_copies": 0,
        "train_dropped_as_train_copies": 0,
    }
    asking = {"e4": True, "t100": True}
    for name, records in ids.items():
        write_jsonl(
            tmp_path / f"labels-{name}.jsonl",
            [item(k, str(by_id[k]["text"]), name.endswith("real") or k in asking) for k in records],
        )
        write_jsonl(tmp_path / f"drops-{name}.jsonl", [])
    for part, count in (("train", 20), ("dev", 8), ("eval", 8)):
        write_jsonl(
            tmp_path / f"synthetic-{part}.jsonl", generate(part, count, FILLERS, "nobody")[0]
        )
    write_jsonl(tmp_path / "ask.jsonl", [])
    monkeypatch.setattr(build, "frozen", lambda: (plan, selection))
    monkeypatch.setattr(build, "stage_ids", lambda name: ids[name])
    monkeypatch.setattr(build, "candidates", lambda: texts)
    monkeypatch.setattr(build, "labels_path", lambda name: tmp_path / f"labels-{name}.jsonl")
    monkeypatch.setattr(build, "drops_path", lambda name: tmp_path / f"drops-{name}.jsonl")
    monkeypatch.setattr(build, "synthetic_path", lambda part: tmp_path / f"synthetic-{part}.jsonl")
    monkeypatch.setattr(build, "output_path", lambda name: tmp_path / f"{name}.jsonl")
    monkeypatch.setattr(build, "ASK", tmp_path / "ask.jsonl")
    monkeypatch.setattr(build, "LEDGER", tmp_path / "usage.jsonl")
    monkeypatch.setattr(build, "OLD_LEDGER", tmp_path / "old.jsonl")
    monkeypatch.setattr(build, "MANIFEST", tmp_path / "manifest.json")
    monkeypatch.setattr(build, "token_report", lambda records: {})
    return ids


def test_a_complete_world_publishes_without_leaks(
    tmp_path: Path, world: dict[str, list[str]]
) -> None:
    assert build.main(["publish"]) == 0
    train, dev, eval_set = (
        read_jsonl(tmp_path / f"{name}.jsonl") for name in ("train", "dev", "eval")
    )
    assert {r["session"] for r in train + dev if r.get("session")}.isdisjoint({"E"})
    parts = {r["id"]: r["part"] for r in eval_set if r["id"] in ("e1", "e3", "e4")}
    assert parts == {"e1": "eval-real", "e3": "eval-negative", "e4": "eval-real-noq"}
    assert {r["id"] for r in train}.isdisjoint({r["id"] for r in dev})
    assert {r["split"] for r in train} == {"train"} and {r["split"] for r in dev} == {"dev"}
    assert {r["split"] for r in eval_set} == {"eval"}
    assert {r["part"] for r in dev if r.get("session")} <= {"dev"}
    assert (tmp_path / "manifest.json").exists() and not (tmp_path / "negatives.jsonl").exists()


def test_only_labelled_texts_enter_the_output(tmp_path: Path, world: dict[str, list[str]]) -> None:
    build.main(["publish"])
    out = {
        r["id"] for name in ("train", "dev", "eval") for r in read_jsonl(tmp_path / f"{name}.jsonl")
    }
    assert "t100" in out and "t106" not in out and "t109" not in out


def test_a_selected_text_without_a_label_or_drop_blocks_publishing(
    tmp_path: Path, world: dict[str, list[str]]
) -> None:
    rows = read_jsonl(tmp_path / "labels-eval-real.jsonl")
    write_jsonl(tmp_path / "labels-eval-real.jsonl", rows[:1])
    assert build.main(["publish"]) == 1
    assert not (tmp_path / "train.jsonl").exists() and not (tmp_path / "manifest.json").exists()
    assert build.main(["inspect"]) == 0
    assert not (tmp_path / "train.jsonl").exists()


def test_boundary_screen_counts_questions_that_start_without_a_mark() -> None:
    text = "Here is the plan.\nWe could do either.\nWhich one?\n- a b c\n- d e f"
    plain = {"questions": [question_item(text, 1, 3, "open")]}
    marked = {"questions": [question_item(text, 3, 5, "choice", ["a b c", "d e f"])]}
    records = [
        {"id": "x", "text": text, "label": plain},
        {"id": "y", "text": text, "label": marked},
    ]
    assert build.boundary_screen(records) == {
        "questions": 1,
        "texts": 1,
        "with_later_question_mark": 1,
    }
