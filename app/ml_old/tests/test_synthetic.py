import random

from questions import label_errors
from segments import segments
from split import families
from synthetic import ACTIONS, OBJECTS, THINGS, VERBS, YES_NO_STEMS, Maker, generate

FILLERS = [f"This is filler sentence number {n} about the build." for n in range(40)]


def test_every_text_has_a_valid_label_in_both_layouts() -> None:
    records, refused = generate("train", 200, FILLERS, "nobody")
    assert refused["invalid"] == 0
    assert {r["layout"] for r in records} == {"pi", "claude"}
    for record in records:
        assert label_errors(str(record["text"]), record["label"]) == []
    assert {len(r["label"]["questions"]) for r in records} == {0, 1, 2, 3, 4}  # type: ignore[index]


def test_negative_texts_can_carry_a_question_mark() -> None:
    maker = Maker("train", FILLERS, random.Random(0))
    assert any("?" in maker.negative() for _ in range(80))


def test_eval_families_share_no_vocabulary_with_train() -> None:
    assert not set(VERBS["train"]) & set(VERBS["eval"])
    assert not set(OBJECTS["train"]) & set(OBJECTS["eval"])
    assert not set(ACTIONS["train"]) & set(ACTIONS["eval"])
    assert not set(THINGS["train"]) & set(THINGS["eval"])
    assert not set(YES_NO_STEMS["train"]) & set(YES_NO_STEMS["eval"])


def test_the_near_duplicate_rate_is_small() -> None:
    records, _ = generate("train", 300, FILLERS, "nobody")
    family = families(records)
    assert sum(family[str(r["id"])] != str(r["id"]) for r in records) / len(records) < 0.1


def test_options_are_in_their_question() -> None:
    for record in generate("eval", 100, FILLERS, "nobody")[0]:
        text = str(record["text"])
        cuts = segments(text)
        for q in record["label"]["questions"]:  # type: ignore[index]
            body = text[cuts[q["first"] - 1].start : cuts[q["last"] - 1].end]
            assert all(option in body for option in q["options"])


def test_no_text_repeats_a_question_and_templates_are_marked() -> None:
    import re

    from questions import questions_of

    records, refused = generate("train", 300, FILLERS, "nobody")
    assert refused["repeated"] > 0
    for record in records:
        text = str(record["text"])
        spans = [
            re.sub(r"^\d+[.)]\s*", "", " ".join(text[q.start : q.end].split()))
            for q in questions_of(text, record["label"])
        ]
        assert len(set(spans)) == len(spans)
        assert record["shared_template"] == (
            "inline" in record["forms"] or "negative" in record["forms"]
        )
