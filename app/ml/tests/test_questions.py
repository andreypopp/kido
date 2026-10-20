import json
from pathlib import Path

from conftest import USER, FakeClient

from deepseek import Spend
from questions import (
    PROMPT_HASH,
    SYSTEM,
    Question,
    label_errors,
    label_text,
    occurrences,
    questions_of,
)

TEXT = (
    "I see two ways.\nWhich one?\n- update the docs\n- keep the change\n\n"
    "Should I run the tests?\nWhat name do you want?"
)


def question(text: str, kind: str, options: list[str]) -> dict[str, object]:
    return {"question": text, "kind": kind, "options": options}


GOOD = {
    "questions": [
        question(
            "I see two ways.\nWhich one?\n- update the docs\n- keep the change",
            "choice",
            ["update the docs", "keep the change"],
        ),
        question("Should I run the tests?", "yes_no", []),
        question("What name do you want?", "open", []),
    ]
}


def test_a_good_label_has_ranges_in_text_order() -> None:
    assert label_errors(TEXT, GOOD) == []
    found = questions_of(TEXT, GOOD)
    assert [TEXT[q.start : q.end] for q in found] == [
        item["question"] for item in GOOD["questions"]
    ]
    assert found[0] == Question(0, 62, "choice", ("update the docs", "keep the change"))


def test_no_question_is_an_empty_list() -> None:
    assert label_errors(TEXT, {"questions": []}) == []


def rejected(label: dict[str, object], text: str = TEXT) -> str:
    return "; ".join(label_errors(text, label))


def test_every_rule_of_the_validator() -> None:
    assert "exact copy" in rejected({"questions": [question("Which  one?", "open", [])]})
    assert "after the previous" in rejected(
        {"questions": [GOOD["questions"][2], GOOD["questions"][1]]}
    )
    assert "choice with no options" in rejected(
        {"questions": [question("Should I run the tests?", "choice", [])]}
    )
    assert "has options" in rejected({"questions": [question("Which one?", "open", ["Which one"])]})
    base = GOOD["questions"][0]["question"]
    for option, reason in (
        ("update the docs.", "full stop"),
        ("- keep the change", "list marker"),
        ("a) keep the change", "list marker"),
        ("ab", "too short"),
        ("nothing", "exactly once"),
    ):
        assert reason in rejected({"questions": [question(base, "choice", [option])]})
    assert "duplicate" in rejected(
        {"questions": [question(base, "choice", ["keep the change", "keep the change"])]}
    )
    assert "kind" in rejected({"questions": [question(base, "maybe", ["keep the change"])]})
    assert rejected({"questions": "x"}) != ""


def test_an_option_that_overlaps_itself_occurs_twice() -> None:
    assert occurrences("ababa", "aba") == 2
    assert "exactly once" in rejected(
        {"questions": [question("Choose ababa?", "choice", ["aba"])]}, "Choose ababa?"
    )


def run(tmp_path: Path, text: str, replies: list[object]):
    client = FakeClient(replies)
    result = label_text(
        client,
        text,
        spend=Spend(tmp_path / "usage.jsonl"),
        cache_dir=tmp_path / "cache",
        stage="t",
        user=USER,
        sleep=lambda _: None,
    )
    return result, client


def test_a_rejected_label_goes_back_once_then_is_dropped(tmp_path: Path) -> None:
    bad = json.dumps({"questions": [question("Which  one?", "open", [])]})
    result, client = run(tmp_path, TEXT, [bad, json.dumps(GOOD)])
    assert result == {"label": GOOD}
    assert "rejected" in client.calls[1]["messages"][-1]["content"]
    result, client = run(tmp_path / "again", TEXT, [bad, bad])
    assert "errors" in result and len(client.calls) == 2


def test_the_correction_turn_is_redacted(tmp_path: Path) -> None:
    leaked = json.dumps(
        {
            "questions": [question("mail alice@example.com", "open", [])],
            "note": 'password="a b c d e"',
        }
    )
    result, client = run(tmp_path, TEXT, [leaked, json.dumps(GOOD)])
    assert result == {"label": GOOD}
    sent = json.dumps(client.calls[1]["messages"])
    assert "alice@example.com" not in sent and "a b c d e" not in sent


def test_unredacted_text_is_refused_without_a_call(tmp_path: Path) -> None:
    result, client = run(tmp_path, "mail alice@example.com?", [])
    assert result == {"errors": ["input is not redacted"]}
    assert client.calls == []


def test_a_cut_off_answer_is_dropped_after_one_call(tmp_path: Path) -> None:
    result, client = run(tmp_path, TEXT, [("", "length")])
    assert result == {"errors": ["finish reason length"]}
    assert len(client.calls) == 1


def test_the_prompt_states_the_validator_limits() -> None:
    assert "At least 3 characters" in SYSTEM and '"yes_no"' in SYSTEM
    assert len(PROMPT_HASH) == 12


def test_ranges_start_after_the_indent_and_marker_and_end_at_the_last_character() -> None:
    text = "⏺ Intro.\n  Which one?  \nrest"
    label = {"questions": [question("  Which one?  ", "open", [])]}
    found = questions_of(text, label)
    assert text[found[0].start : found[0].end] == "Which one?"
    label = {"questions": [question("⏺ Intro.\n  Which one?", "open", [])]}
    assert text[questions_of(text, label)[0].start :].startswith("Intro.")
