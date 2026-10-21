from evaluate import aggregate, dev_score, gold_of, part_names, same_but_seed, score
from questions import question_item

TEXT = "Should I stop or go on? What name? Fine."
CHOICE = question_item(TEXT, 1, 1, "choice", ["stop", "go on"])
OPEN = question_item(TEXT, 2, 2, "open")
FIRST = (0, len("Should I stop or go on?"))
SECOND = (len("Should I stop or go on? "), len("Should I stop or go on? What name?"))


def record(part: str, items: list[dict], **extra) -> dict[str, object]:
    base = {"text": TEXT, "label": {"questions": items}, "source": "pi", "split": "eval"}
    return base | {"part": part} | extra


def test_part_names() -> None:
    real = record("eval-real", [CHOICE], question_segments=2, agree=2)
    assert part_names(real) == ["eval-real", "eval-real-multi"]
    assert part_names(real | {"agree": 3}) == [
        "eval-real",
        "eval-real-multi",
        "eval-real-unanimous",
    ]
    assert part_names(record("eval-real-noq", [CHOICE])) == ["eval-real-noq"]
    empty = record("eval-real", [], question_segments=1, agree=3)
    assert {"eval-negatives", "eval-negatives-with-question-mark"} <= set(part_names(empty))
    plain = record("eval-negative", [], question_segments=0)
    assert {"eval-negatives", "eval-negatives-no-question-mark"} <= set(part_names(plain))
    synthetic = {"source": "synthetic", "split": "eval", "part": "eval"}
    assert part_names(synthetic | {"shared_template": False, "forms": ["single"]}) == [
        "synthetic",
        "synthetic-unshared",
        "synthetic-no-inline",
    ]
    assert part_names(synthetic | {"shared_template": True, "forms": ["inline"]}) == ["synthetic"]
    dev = {"source": "claude", "split": "dev", "part": "dev", "question_segments": 0}
    assert part_names(dev | {"label": {"questions": []}}) == [
        "dev",
        "dev-real",
        "dev-real-no-question-mark",
    ]


def test_gold_has_options_in_text_order() -> None:
    swapped = question_item(TEXT, 1, 1, "choice", ["go on", "stop"])
    ((found, kind),) = gold_of(record("eval-real", [swapped]))
    assert found[2] == ("stop", "go on") and kind == "choice"


def test_no_open_view_keeps_the_other_questions_of_a_mixed_text() -> None:
    mixed = record("eval-real", [CHOICE, OPEN], question_segments=2, agree=3)
    stray = (len(TEXT) - 5, len(TEXT), ())
    perfect = [(*FIRST, ("stop", "go on")), (*SECOND, ())]
    result = score([mixed], lambda r: perfect + [stray], lambda *_: ("stop", "go on"))
    assert result["eval-real"]["gold_questions"] == 2
    assert result["eval-real"]["errors"]["false_question"] == 1
    clean = result["eval-real/no-open"]
    assert (clean["texts"], clean["gold_questions"], clean["predicted_questions"]) == (1, 1, 2)
    assert clean["question_f1"] == round(2 * 0.5 / 1.5, 4)
    assert result["eval-real-unanimous/no-open"]["texts"] == 1
    exact = score([mixed], lambda r: perfect, None)
    assert exact["eval-real"]["whole_output_exact"] == 1.0
    assert exact["eval-real/no-open"]["whole_output_exact"] == 1.0
    missed = score([mixed], lambda r: perfect[:1], None)
    assert missed["eval-real"]["whole_output_exact"] == 0.0
    assert missed["eval-real/no-open"]["whole_output_exact"] == 1.0


def test_two_of_three_labels_are_not_unanimous() -> None:
    result = score(
        [record("eval-real", [CHOICE], question_segments=1, agree=2)], lambda r: [], None
    )
    assert "eval-real-unanimous" not in result


def test_aggregate_gives_mean_and_sd() -> None:
    runs = [{"a": {"f1": 0.5, "none": None}}, {"a": {"f1": 0.7, "none": None}}]
    assert aggregate(runs) == {"a": {"f1": {"mean": 0.6, "sd": 0.1414}, "none": None}}


def test_runs_compare_only_when_they_differ_in_seed() -> None:
    def model(seed: int, epochs: int = 10) -> dict:
        return {"train": {"settings": {"seed": seed, "epochs": epochs, "output": f"d{seed}"}}}

    assert same_but_seed([model(0), model(1)])
    assert not same_but_seed([model(0), model(1, 15)])
    assert not same_but_seed([model(0), model(0)])


def test_dev_score_is_the_real_mean_and_the_synthetic_is_a_diagnostic() -> None:
    scores = {
        "dev-real": {"false_positive_rate": 0.01, "question_f1": 0.5, "option_f1_end_to_end": 0.3},
        "dev-synthetic": {"question_f1": 1.0, "option_f1_end_to_end": 1.0},
    }
    assert dev_score(scores) == {"fpr": 0.01, "score": 0.4, "synthetic_score": 1.0}
