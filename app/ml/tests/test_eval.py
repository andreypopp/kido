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


def test_error_analysis_counts_boundaries_and_units() -> None:
    from collections import Counter

    from eval import error_analysis

    prompt = "  1: prose\n  2: \n  3: Pick one?\n  4: 1. Red\n  5: 2. Blue"
    red = prompt.index("Red")
    one = prompt.index("one")
    blue = prompt.index("Blue")
    pick = prompt.index("Pick")
    case = {
        "prompt": prompt,
        "gold_options": Counter({(red, red + 3): 1, (one, one + 3): 1, (blue, blue + 4): 1}),
        "predicted_options": Counter(
            {(red - 3, red + 3): 1, (one, one + 3): 1, (pick, pick + 4): 1}
        ),
        "gold_unit": (0, 4),
        "predicted_unit": (2, 4),
        "ranges": [[0, 0], [2, 2], [3, 3], [4, 4]],
        "gold_question": False,
        "predicted_question": True,
    }
    result = error_analysis([case])
    assert result["missed"] == 1
    assert result["missed_list"] == 1
    assert result["boundary_marker_included"] == 1
    assert result["boundary_start_early"] == 1
    assert result["unit_too_short"] == 1
    assert result["unit_missing_paragraphs"] == 1
    assert result["false_questions"] == 1
    assert result["false_questions_with_question_mark"] == 1
    assert result["spurious_visible"] == 1
    assert result.get("spurious_hidden", 0) == 0


def test_error_analysis_counts_inline_misses() -> None:
    from collections import Counter

    from eval import error_analysis

    prompt = "  1: Should I use alpha or beta?"
    start = prompt.index("alpha")
    case = {
        "prompt": prompt,
        "gold_options": Counter({(start, start + 5): 1}),
        "predicted_options": Counter(),
        "gold_unit": (0, 0),
        "predicted_unit": None,
        "ranges": [[0, 0]],
        "gold_question": True,
        "predicted_question": False,
    }
    result = error_analysis([case])
    assert result["missed_inline"] == 1
    assert result["unit_missed"] == 1
    assert result["missed_questions"] == 1


def test_app_visible_option_metric_drops_options_outside_predicted_unit() -> None:
    from collections import Counter

    from eval import metrics_only

    prompt = "  1: Pick?\n  2: 1. Red\n  3: 2. Blue"
    red = prompt.index("Red")
    blue = prompt.index("Blue")
    case = {
        "part": "real",
        "gold_tags": [],
        "predicted_tags": [],
        "gold_options": Counter({(red, red + 3): 1, (blue, blue + 4): 1}),
        "predicted_options": Counter({(red, red + 3): 1, (blue, blue + 4): 1}),
        "gold_unit": (0, 2),
        "predicted_unit": (0, 1),
        "gold_question": True,
        "predicted_question": True,
        "ranges": [[0, 2]],
        "prompt": prompt,
    }
    result = metrics_only([case])
    assert result["option"]["f1"] == 1.0
    assert result["option_visible"]["gold"] == 2
    assert result["option_visible"]["predicted"] == 1
    assert result["option_visible"]["recall"] == 0.5
    assert abs(result["option_visible"]["f1"] - 2 / 3) < 1e-9


def test_app_visible_option_metric_drops_all_options_without_a_question() -> None:
    from collections import Counter

    from eval import metrics_only

    prompt = "  1: Prose.\n  2: 1. Red"
    red = prompt.index("Red")
    case = {
        "part": "real",
        "gold_tags": [],
        "predicted_tags": [],
        "gold_options": Counter({(red, red + 3): 1}),
        "predicted_options": Counter({(red, red + 3): 1}),
        "gold_unit": (0, 1),
        "predicted_unit": (0, 1),
        "gold_question": True,
        "predicted_question": False,
        "ranges": [[0, 1]],
        "prompt": prompt,
    }
    result = metrics_only([case])
    assert result["option"]["f1"] == 1.0
    assert result["option_visible"]["predicted"] == 0
    assert result["option_visible"]["recall"] == 0.0



def test_app_visible_requires_the_whole_span_inside_the_unit() -> None:
    from collections import Counter

    from eval import metrics_only

    prompt = "  1: Pick?\n  2: 1. Red\n  3: 2. Blue"
    red = prompt.index("Red")
    blue = prompt.index("Blue")
    case = {
        "part": "real",
        "gold_tags": [],
        "predicted_tags": [],
        "gold_options": Counter({(red, red + 3): 1}),
        "predicted_options": Counter({(red, blue + 4): 1}),
        "gold_unit": (0, 2),
        "predicted_unit": (0, 1),
        "gold_question": True,
        "predicted_question": True,
        "ranges": [[0, 2]],
        "prompt": prompt,
    }
    result = metrics_only([case])
    assert result["option_visible"]["predicted"] == 0
    assert result["option_visible"]["recall"] == 0.0


def test_spurious_crossing_span_is_hidden() -> None:
    from collections import Counter

    from eval import error_analysis

    prompt = "  1: Pick?\n  2: 1. Red\n  3: 2. Blue"
    red = prompt.index("Red")
    blue = prompt.index("Blue")
    case = {
        "prompt": prompt,
        "gold_options": Counter(),
        "predicted_options": Counter({(red, blue + 4): 1}),
        "gold_unit": None,
        "predicted_unit": (0, 1),
        "ranges": [[0, 2]],
        "gold_question": False,
        "predicted_question": True,
    }
    result = error_analysis([case])
    assert result.get("spurious_visible", 0) == 0
    assert result.get("spurious_hidden", 0) == 1
