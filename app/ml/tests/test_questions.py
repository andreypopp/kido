import json
from pathlib import Path

from conftest import OFF_PEAK, USER, FakeClient

from deepseek import Spend
from questions import (
    EXAMPLES,
    LENGTH,
    PROMPT_HASH,
    SYSTEM,
    canonical,
    first_words,
    label_errors,
    label_text,
    occurrences,
    ordered_options,
    question_item,
    questions_of,
    span,
    view,
)

TEXT = (
    "I see two ways. Which one?\n- update the docs\n- keep the change\n\n"
    "Should I run the tests?\nWhat name do you want?"
)


def item(first: int, last: int, words: str, kind: str, options: list[str]) -> dict[str, object]:
    return {"first": first, "last": last, "words": words, "kind": kind, "options": options}


GOOD = {
    "questions": [
        item(1, 4, "I see two", "choice", ["update the docs", "keep the change"]),
        item(6, 6, "Should I run", "yes_no", []),
        item(7, 7, "What name do", "open", []),
    ]
}


def test_the_view_numbers_segments_and_keeps_blank_ones() -> None:
    assert view(TEXT).splitlines() == [
        "1: I see two ways.",
        "2: Which one?",
        "3: - update the docs",
        "4: - keep the change",
        "5:",
        "6: Should I run the tests?",
        "7: What name do you want?",
    ]


def test_a_segment_with_several_rows_keeps_its_breaks() -> None:
    assert view("A long row that\nwraps. Next.") == "1: A long row that\nwraps.\n2: Next."


def test_every_prompt_example_is_a_valid_label() -> None:
    for _, text, questions in EXAMPLES:
        assert label_errors(text, {"questions": questions}) == [], text


def test_a_good_label_has_ranges_in_text_order() -> None:
    assert label_errors(TEXT, GOOD) == []
    found = questions_of(TEXT, GOOD)
    assert [TEXT[q.start : q.end] for q in found] == [
        "I see two ways. Which one?\n- update the docs\n- keep the change",
        "Should I run the tests?",
        "What name do you want?",
    ]


def test_ranges_start_after_the_marker() -> None:
    text = "⏺ Intro. Which one?\n  - first\n  - second"
    label = {"questions": [item(1, 4, "Intro.", "choice", ["first", "second"])]}
    assert label_errors(text, label) == []
    assert text[questions_of(text, label)[0].start :].startswith("Intro.")


def test_no_question_is_an_empty_list() -> None:
    assert label_errors(TEXT, {"questions": []}) == []


def rejected(label: dict[str, object], text: str = TEXT) -> str:
    return "; ".join(label_errors(text, label))


def test_every_rule_of_the_validator() -> None:
    q = GOOD["questions"]
    assert "segment numbers" in rejected({"questions": [item(1, 99, "I see two", "open", [])]})
    assert "segment numbers" in rejected({"questions": [item(0, 1, "I see two", "open", [])]})
    assert "after" in rejected({"questions": [item(3, 2, "- update the", "open", [])]})
    assert "overlaps" in rejected({"questions": [q[0], item(4, 6, "- keep the", "open", [])]})
    assert "overlaps" in rejected({"questions": [q[1], q[0]]})
    assert "not blank" in rejected({"questions": [item(5, 6, "", "open", [])]})
    assert "words" in rejected({"questions": [item(1, 1, "I see", "open", [])]})
    assert "choice with no options" in rejected(
        {"questions": [item(6, 6, "Should I run", "choice", [])]}
    )
    assert "has options" in rejected(
        {"questions": [item(2, 2, "Which one?", "open", ["Which one"])]}
    )
    for option, reason in (
        ("update the docs.", "full stop"),
        ("- keep the change", "list marker"),
        ("a) keep the change", "list marker"),
        ("ab", "too short"),
        ("nothing", "exactly once"),
    ):
        assert reason in rejected({"questions": [item(1, 4, "I see two", "choice", [option])]})
    assert "duplicate" in rejected(
        {"questions": [item(1, 4, "I see two", "choice", ["keep the change", "keep the change"])]}
    )
    assert "kind" in rejected({"questions": [item(2, 2, "Which one?", "maybe", [])]})
    assert rejected({"questions": "x"}) != ""


def test_an_option_that_overlaps_itself_occurs_twice() -> None:
    assert occurrences("ababa", "aba") == 2
    text = "Choose ababa?"
    label = {"questions": [item(1, 1, "Choose ababa?", "choice", ["aba"])]}
    assert "exactly once" in rejected(label, text)


def test_agreement_ignores_option_order() -> None:
    a = {"questions": [item(1, 4, "I see two", "choice", ["x y z", "a b c"])]}
    b = {"questions": [item(1, 4, "I see two", "choice", ["a b c", "x y z"])]}
    assert canonical(a) == canonical(b)
    assert first_words("one two three four") == "one two three"


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
        clock=OFF_PEAK,
    )
    return result, client


def test_a_rejected_label_goes_back_once_then_is_dropped(tmp_path: Path) -> None:
    bad = json.dumps({"questions": [item(1, 99, "x", "open", [])]})
    result, client = run(tmp_path, TEXT, [bad, json.dumps(GOOD)])
    assert result == {"label": GOOD}
    assert "rejected" in client.calls[1]["messages"][-1]["content"]
    assert client.calls[0]["messages"][-1]["content"].startswith("Text:\n1: I see two ways.")
    result, client = run(tmp_path / "again", TEXT, [bad, bad])
    assert "errors" in result and len(client.calls) == 2


def test_the_correction_turn_is_redacted(tmp_path: Path) -> None:
    leaked = json.dumps(
        {
            "questions": [item(1, 99, "x", "open", [])],
            "note": 'mail alice@example.com password="a b c d e"',
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
    assert result == {"errors": [LENGTH]}
    assert len(client.calls) == 1


def test_the_prompt_states_the_validator_limits() -> None:
    assert "at least 3 characters" in SYSTEM and '"yes_no"' in SYSTEM
    assert len(PROMPT_HASH) == 12


def test_question_item_derives_the_words_and_the_span() -> None:
    made = question_item(TEXT, 1, 4, "choice", ["update the docs", "keep the change"])
    assert made == GOOD["questions"][0]
    from segments import segments

    assert span(segments(TEXT), 6, 7) == (TEXT.index("Should"), len(TEXT))


def test_options_follow_the_text_order() -> None:
    label = {
        "questions": [item(1, 4, "I see two", "choice", ["keep the change", "update the docs"])]
    }
    assert ordered_options(TEXT, label)["questions"][0]["options"] == [  # type: ignore[index]
        "update the docs",
        "keep the change",
    ]
