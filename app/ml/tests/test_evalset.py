from evalset import agreement, expand_real

PROMPT = "  1: Plain\n> 2: Pick one?\n  3: \n  4: 1. Red\n  5: 2. Blue"
LABEL = {
    "lines": ["other", "question", "other", "option", "option"],
    "options": [{"line": 4, "text": "Red"}, {"line": 5, "text": "Blue"}],
}
BASE = {"id": "a", "context_id": "family", "prompt": PROMPT, "session": "s"}


def samples(labels: list[object]) -> list[dict[str, object]]:
    return [
        {"id": "a", "sample": index + 1, "label": label}
        for index, label in enumerate(labels)
    ]


def test_five_equal_samples_agree() -> None:
    records, stats, rejected = agreement([BASE], samples([LABEL] * 5))
    assert rejected == 0
    assert len(records) == 1
    assert stats == {
        "attempted": 1,
        "agreed": 1,
        "disagreement": 0,
        "invalid": 0,
        "not_attempted": 0,
        "normalization_families": 0,
        "normalization_lines": 0,
    }


def test_one_different_sample_is_a_disagreement() -> None:
    other = {**LABEL, "lines": ["other", "question", "question", "option", "option"]}
    _, stats, _ = agreement([BASE], samples([LABEL] * 4 + [other]))
    assert stats["disagreement"] == 1
    assert stats["agreed"] == 0


def test_an_invalid_sample_is_counted_invalid() -> None:
    bad = {"lines": ["other"], "options": []}
    _, stats, rejected = agreement([BASE], samples([LABEL] * 4 + [bad]))
    assert stats["invalid"] == 1
    assert stats["disagreement"] == 0
    assert rejected == 1


def test_wrong_sample_count_is_invalid() -> None:
    _, stats, _ = agreement([BASE], samples([LABEL] * 4))
    assert stats["invalid"] == 1
    assert stats["attempted"] == 1


def test_two_different_samples_are_a_disagreement_even_without_five() -> None:
    other = {**LABEL, "lines": ["other", "question", "question", "option", "option"]}
    _, stats, _ = agreement([BASE], samples([LABEL, other]))
    assert stats["disagreement"] == 1
    assert stats["invalid"] == 0


def test_sample_errors_are_invalid() -> None:
    values = samples([LABEL] * 4)
    values.append({"id": "a", "sample": 5, "errors": ["not JSON"]})
    _, stats, rejected = agreement([BASE], values)
    assert stats["invalid"] == 1
    assert rejected == 0


def test_not_attempted_family_is_counted() -> None:
    second = {**BASE, "id": "b", "context_id": "other"}
    _, stats, _ = agreement([BASE, second], samples([LABEL] * 5))
    assert stats["attempted"] == 1
    assert stats["not_attempted"] == 0


def test_expand_real_attaches_one_label_to_every_hover_variant() -> None:
    variants = [
        {**BASE, "id": "v1", "session": "s"},
        {**BASE, "id": "v2", "session": "s"},
    ]
    records, stats, rejected, decided = expand_real(
        [BASE], variants, samples([LABEL] * 5)
    )
    assert stats["agreed"] == 1
    assert rejected == 0
    assert decided == 1
    assert all(record["label"] == LABEL for record in records)
    assert all(record["part"] == "real" for record in records)
