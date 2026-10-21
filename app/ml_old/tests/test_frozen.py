import json
from pathlib import Path

import pytest

import select_texts
from jsonl import digest, file_digest, write_once


def test_a_frozen_file_is_written_once(tmp_path: Path) -> None:
    write_once(tmp_path / "a.json", {"x": 1})
    with pytest.raises(FileExistsError):
        write_once(tmp_path / "a.json", {"x": 2})
    assert json.loads((tmp_path / "a.json").read_text()) == {"x": 1}


def test_digest_ignores_order() -> None:
    assert digest(["b", "a"]) == digest(["a", "b"]) != digest(["a"])


def freeze_in(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    files = {name: tmp_path / name for name in ("plan", "selection", "candidates", "ask")}
    files["candidates"].write_text("c\n")
    files["ask"].write_text("a\n")
    sessions = ["s1", "s2"]
    write_once(files["plan"], {"eval_sessions": sessions, "hash": digest(sessions)})
    write_once(
        files["selection"],
        {
            "plan": digest(sessions),
            "candidates": file_digest(files["candidates"]),
            "ask": file_digest(files["ask"]),
            "settings": select_texts.SETTINGS,
        },
    )
    for attribute, key in (
        ("PLAN", "plan"),
        ("SELECTION", "selection"),
        ("CANDIDATES", "candidates"),
        ("ASK", "ask"),
    ):
        monkeypatch.setattr(select_texts, attribute, files[key])
    return tmp_path


def test_frozen_inputs_are_checked(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    root = freeze_in(tmp_path, monkeypatch)
    plan, selection = select_texts.frozen()
    assert plan["eval_sessions"] == ["s1", "s2"] and selection["plan"] == plan["hash"]
    (root / "candidates").write_text("changed\n")
    with pytest.raises(SystemExit, match="frozen inputs changed"):
        select_texts.frozen()


def test_the_pick_prefers_texts_with_several_question_paragraphs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(select_texts, "EVAL_REAL", 6)
    monkeypatch.setattr(select_texts, "EVAL_MULTI", 3)
    pool = [
        {
            "id": f"i{n}",
            "session": f"s{n}",
            "text": f"distinct words for text number {n} " * 5,
            "question_segments": 2 if n < 5 else 1,
            "question_paragraphs": 2 if n in (3, 4) else 1,
        }
        for n in range(10)
    ]
    chosen = select_texts.choose_eval(pool, set(), 0)
    assert chosen is not None and {"i3", "i4"} <= set(chosen) and len(chosen) == 6


def record(key: str, session: str, text: str, positive: bool = False) -> dict[str, object]:
    return {
        "id": key,
        "session": session,
        "text": text,
        "question_segments": int(positive),
        "question_paragraphs": int(positive),
    }


def test_train_negatives_put_the_hard_pool_first_and_skip_eval_copies(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def text(n: int, hard: bool) -> str:
        return (
            f"Unique note number {n} " + ("tell me what you decide " if hard else "") + f"end{n}."
        )

    records = [record("r1", "E", text(1, False), True), record("n1", "E", text(2, False))]
    records += [record("copy", "T", text(2, False))]
    records += [record(f"u{n}", "T", text(10 + n, False)) for n in range(6)]
    records += [record(f"h{n}", "T", text(30 + n, True)) for n in range(4)]
    plan = {"eval_sessions": ["E"], "hash": "p"}
    selection = {
        "eval_real": ["r1"],
        "eval_negative": ["n1"],
        "negative_sample": ["u0"],
        "candidates": "c",
    }
    sampled = [{"id": "u0", "label": {"questions": []}}]
    monkeypatch.setattr(select_texts, "frozen", lambda: (plan, selection))
    monkeypatch.setattr(select_texts, "candidates", lambda: records)
    monkeypatch.setattr(select_texts, "read_jsonl", lambda path: sampled)
    monkeypatch.setattr(select_texts, "NEGATIVES", tmp_path / "negatives.json")
    monkeypatch.setattr(select_texts, "TRAIN_NEGATIVES", 8)
    monkeypatch.setattr(select_texts, "UNIFORM_SHARE", 0.125)
    result = select_texts.freeze_negatives()
    chosen = json.loads((tmp_path / "negatives.json").read_text())["train_negative"]
    assert chosen[0] == "u0" and "copy" not in chosen and len(chosen) == 8
    assert [k[0] for k in chosen[1:5]] == ["h"] * 4
    assert result["pools"] == {
        "sample_done": 1,
        "hard": 4,
        "uniform": 3,
        "hard_available": 4,
        "uniform_available": 5,
    }
