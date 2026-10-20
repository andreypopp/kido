from transformers import AutoTokenizer

from render import character_count
from runtime import MODEL
from validate import (
    TAGS,
    bio,
    example,
    label_errors,
    spans_from_label,
    strip_bold,
    tags_to_spans,
)

PROMPT = "  1: Intro.\n  2: \n> 3: Pick one?\n  4: \n  5: 1. **Red**\n  6: 2. **Blue**"
LABEL = {
    "lines": ["other", "other", "question", "other", "option", "option"],
    "options": [
        {"line": 5, "text": "Red"},
        {"line": 6, "text": "Blue"},
    ],
}


class CharTokenizer:
    def __call__(self, text: str, **_: object) -> dict[str, list]:
        return {
            "input_ids": list(range(len(text) + 2)),
            "attention_mask": [1] * (len(text) + 2),
            "offset_mapping": [(0, 0)]
            + [(index, index + 1) for index in range(len(text))]
            + [(0, 0)],
        }


def test_valid_label_has_no_errors() -> None:
    assert label_errors(PROMPT, LABEL) == []


def test_option_short_marker_bold_and_duplicate_are_rejected() -> None:
    base = {"lines": LABEL["lines"], "options": [{"line": 5, "text": "Red"}]}
    short = {**base, "options": [{"line": 5, "text": "Re"}]}
    assert any("shorter" in error for error in label_errors(PROMPT, short))
    marker = {**base, "options": [{"line": 5, "text": "1. Red"}]}
    assert any("marker" in error for error in label_errors(PROMPT, marker))
    bold = {**base, "options": [{"line": 5, "text": "**Red**"}]}
    assert any("marker" in error for error in label_errors(PROMPT, bold))
    duplicate = {
        "lines": LABEL["lines"],
        "options": [
            {"line": 5, "text": "Red"},
            {"line": 6, "text": "red"},
        ],
    }
    assert any("duplicate" in error for error in label_errors(PROMPT, duplicate))


def test_option_line_needs_an_exact_option() -> None:
    label = {"lines": LABEL["lines"], "options": [{"line": 5, "text": "Red"}]}
    assert any("no exact option" in error for error in label_errors(PROMPT, label))


def test_spans_are_exact_option_text_only() -> None:
    spans = spans_from_label(PROMPT, LABEL)
    assert [(PROMPT[start:end], value) for start, end, value in spans] == [
        ("Pick one?", "question"),
        ("Red", "option"),
        ("Blue", "option"),
    ]


def test_strip_bold_maps_spans() -> None:
    text, spans = strip_bold(PROMPT, spans_from_label(PROMPT, LABEL))
    assert "**" not in text
    assert [(text[start:end], value) for start, end, value in spans] == [
        ("Pick one?", "question"),
        ("Red", "option"),
        ("Blue", "option"),
    ]


def test_adjacent_options_get_two_b_tags() -> None:
    spans = [(5, 8, "option"), (8, 12, "option")]
    offsets = [(index, index + 1) for index in range(20)]
    labels = bio(offsets, spans)
    assert labels[5] == TAGS.index("B-OPTION")
    assert labels[8] == TAGS.index("B-OPTION")
    back = tags_to_spans(
        ["O"] * 5 + ["B-OPTION"] * 3 + ["B-OPTION"] * 4 + ["O"] * 8, offsets
    )
    assert back[-1][2] == "option"


def test_real_tokenizer_round_trip() -> None:
    tokenizer = AutoTokenizer.from_pretrained(MODEL)
    spans = spans_from_label(PROMPT, LABEL)
    encoded = tokenizer(PROMPT, return_offsets_mapping=True, add_special_tokens=True)
    offsets = [list(pair) for pair in encoded["offset_mapping"]]
    tags = [TAGS[value] if value >= 0 else "O" for value in bio(offsets, spans)]
    back = tags_to_spans(tags, offsets)
    options = [(start, end, value) for start, end, value in spans if value == "option"]
    assert [(start, end, value) for start, end, value in back if value == "option"] == options


def test_example_strips_bold_and_remaps() -> None:
    record = {"prompt": PROMPT, "label": LABEL}
    prompt, spans = example(record, False)
    assert "**" not in prompt
    assert [(prompt[start:end], value) for start, end, value in spans] == [
        ("Pick one?", "question"),
        ("Red", "option"),
        ("Blue", "option"),
    ]


def test_option_rules_use_graphemes() -> None:
    assert character_count("👨‍👩‍👧") == 1


def test_canonical_label_ignores_option_order() -> None:
    from validate import canonical_label

    first = {
        "lines": ["question", "option", "option"],
        "options": [{"line": 2, "text": "Red"}, {"line": 3, "text": "Blue"}],
    }
    second = {
        "lines": ["question", "option", "option"],
        "options": [{"line": 3, "text": "Blue"}, {"line": 2, "text": "Red"}],
    }
    assert canonical_label(first) == canonical_label(second)


def test_rejection_classes() -> None:
    from validate import rejection_class

    assert rejection_class([]) == "valid"
    assert rejection_class(["not JSON: bad"]) == "invalid_json"
    assert rejection_class(["samples disagree: 2 labels"]) == "disagreement"
    assert rejection_class(["sample invalid: no question"]) == "sample_invalid"
    assert rejection_class(["option 1: shorter than 3 characters"]) == "option_too_short"
    assert rejection_class(["option 1: contains a marker or bold markup"]) == "option_markup"
    assert rejection_class(["option 1: duplicate"]) == "duplicate_option"
    assert rejection_class(["option line 2: no exact option"]) == "missing_option"
    assert rejection_class(["line 3: unit is not contiguous"]) == "non_contiguous"


def test_two_units_are_allowed() -> None:
    prompt = (
        "  1: First question?\n"
        "  2: 1. **Red**\n"
        "  3: 2. **Blue**\n"
        "  4: Plain prose between units.\n"
        "  5: Second question?\n"
        "  6: - alpha\n"
        "  7: - beta"
    )
    label = {
        "lines": ["question", "option", "option", "other", "question", "option", "option"],
        "options": [
            {"line": 2, "text": "Red"},
            {"line": 3, "text": "Blue"},
            {"line": 6, "text": "alpha"},
            {"line": 7, "text": "beta"},
        ],
    }
    assert label_errors(prompt, label) == []


def test_option_must_belong_to_a_unit() -> None:
    prompt = "  1: Plain prose.\n  2: \n  3: Not tagged?"
    label = {
        "lines": ["other", "other", "other"],
        "options": [{"line": 1, "text": "Plain prose"}],
    }
    assert any("not adjacent" in error for error in label_errors(prompt, label))


def test_unit_containing_hovered_paragraph_not_the_whole_context() -> None:
    from validate import unit_from_classes

    prompt = "  1: First?\n  2: \n  3: Plain prose.\n  4: \n  5: Second?"
    classes = ["question", "other", "other", "other", "question"]
    assert unit_from_classes(prompt, classes, [[0, 0], [2, 2], [4, 4]], 0) == (0, 0)
    assert unit_from_classes(prompt, classes, [[0, 0], [2, 2], [4, 4]], 1) is None
    assert unit_from_classes(prompt, classes, [[0, 0], [2, 2], [4, 4]], 2) == (4, 4)


def test_is_positive_uses_the_hovered_paragraph() -> None:
    from validate import is_positive

    record = {
        "ranges": [[0, 0], [2, 2]],
        "hovered": 0,
        "label": {"lines": ["question", "other", "other"], "options": []},
    }
    assert is_positive(record)
    record["hovered"] = 1
    assert not is_positive(record)


def test_option_kinds_split_list_and_inline() -> None:
    from validate import option_kinds

    record = {
        "prompt": "  1: alpha or beta\n  2: 1. Red",
        "label": {
            "lines": ["question", "option"],
            "options": [{"line": 1, "text": "alpha"}, {"line": 2, "text": "Red"}],
        },
    }
    assert option_kinds(record) == {"list": 1, "inline": 1}


def test_attach_rejects_a_bad_label() -> None:
    from validate import attach

    record = {"prompt": PROMPT}
    assert attach(record, {"lines": ["other"]})[0] is None
    assert attach(record, LABEL)[0]["label"] == LABEL


def test_normalisation_moves_list_options_to_option() -> None:
    from validate import normalize_label

    prompt = "  1: Pick one?\n  2: 1. **Red**\n  3: 2. **Blue**"
    raw = {
        "lines": ["question", "question", "question"],
        "options": [{"line": 2, "text": "Red"}, {"line": 3, "text": "Blue"}],
    }
    label, changed = normalize_label(prompt, raw)
    assert label["lines"] == ["question", "option", "option"]
    assert changed == 2


def test_normalisation_moves_inline_options_to_question() -> None:
    from validate import normalize_label

    prompt = "  1: Pick one? alpha or beta\n  2: Plain prose"
    raw = {
        "lines": ["option", "other"],
        "options": [
            {"line": 1, "text": "alpha"},
            {"line": 1, "text": "beta"},
        ],
    }
    label, changed = normalize_label(prompt, raw)
    assert label["lines"] == ["question", "other"]
    assert changed == 1


def test_option_kinds_use_the_list_marker_not_the_line_class() -> None:
    from validate import option_kinds

    record = {
        "prompt": "  1: Pick one?\n  2: 1. Red\n  3: alpha or beta",
        "label": {
            "lines": ["question", "question", "question"],
            "options": [
                {"line": 2, "text": "Red"},
                {"line": 3, "text": "alpha"},
            ],
        },
    }
    assert option_kinds(record) == {"list": 1, "inline": 1}
