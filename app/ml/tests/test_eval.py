from eval import IGNORE, line_classes, make_case, metrics_only, unit_from_classes
from render import prompt_lines

PROMPT = "  1: Prose.\n  2: \n> 3: Is this a question?\n  4: \n  5: 1. Red"
RANGES = [[0, 0], [2, 2], [4, 4]]


def test_unit_snaps_to_paragraphs() -> None:
    classes = ["other", "other", "question", "other", "other"]
    assert unit_from_classes(PROMPT, classes, RANGES, 1) == (2, 2)


def test_non_question_hover_beside_question_is_not_a_false_positive() -> None:
    classes = ["question", "other", "other", "other", "other"]
    assert unit_from_classes(PROMPT, classes, RANGES, 0) == (0, 0)
    record = {
        "ranges": RANGES,
        "hovered": 0,
        "label": {"lines": ["other", "other", "other", "other", "other"], "options": []},
        "source": "pi",
    }
    offsets = [[0, 0]] + [[index, index + 1] for index in range(len(PROMPT))] + [[0, 0]]
    tags = ["O"] * len(offsets)
    start = PROMPT.index("Is this")
    for index in range(start, start + 5):
        tags[index + 1] = "B-QUESTION" if index == start else "I-QUESTION"
    case = make_case(record, PROMPT, [], offsets, tags)
    result = metrics_only([case])
    assert result["question_false_positive_rate"] == 0.0


def test_ignored_positions_do_not_score() -> None:
    record = {
        "ranges": RANGES,
        "hovered": 1,
        "label": {"lines": ["other", "other", "question", "other", "other"], "options": []},
        "source": "pi",
    }
    offsets = [[0, 0], [0, 1], [1, 2], [0, 0]]
    case = make_case(record, PROMPT, [], offsets, ["B-OPTION", "O", "O", "B-QUESTION"])
    case["gold_tags"] = [IGNORE, "O", "O", IGNORE]
    result = metrics_only([case])
    assert result["token_f1"]["option"]["fp"] == 0
    assert result["token_f1"]["question"]["tp"] == 0


def test_repeated_option_text_uses_ranges() -> None:
    prompt = "  1: Red alpha\n  2: \n> 3: Red beta"
    record = {
        "ranges": [[0, 0], [2, 2]],
        "hovered": 1,
        "label": {"lines": ["other", "other", "question"], "options": []},
        "source": "pi",
    }
    offsets = [[0, 0]] + [[index, index + 1] for index in range(len(prompt))] + [[0, 0]]
    second = prompt.index("Red", prompt.index("Red") + 1)
    gold = [(second, second + 3, "option")]
    start = prompt.index("Red")
    tags = ["O"] * len(offsets)
    for index in range(start, start + 3):
        tags[index + 1] = "B-OPTION" if index == start else "I-OPTION"
    case = make_case(record, prompt, gold, offsets, tags)
    assert sum(case["gold_options"].values()) == 1
    assert sum(case["predicted_options"].values()) == 1
    assert metrics_only([case])["option"]["f1"] == 0.0


def test_line_classes_majority() -> None:
    rows = prompt_lines(PROMPT)
    offsets = [[0, 0]] + [[index, index + 1] for index in range(len(PROMPT))] + [[0, 0]]
    tags = ["O"] * len(offsets)
    for index in range(int(rows[0]["start"]), int(rows[0]["end"])):
        tags[index + 1] = "B-QUESTION" if index == int(rows[0]["start"]) else "I-QUESTION"
    assert line_classes(PROMPT, offsets, tags)[0] == "question"


def test_unit_snaps_partial_tag_to_whole_paragraph() -> None:
    classes = ["other", "other", "other", "question", "other"]
    ranges = [[0, 0], [2, 4]]
    assert unit_from_classes(PROMPT, classes, ranges, 1) == (2, 4)
