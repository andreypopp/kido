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
