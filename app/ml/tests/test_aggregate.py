import json

from aggregate import main, summarize


def metric(value: float) -> dict[str, object]:
    return {
        "token_f1": {"question": {"f1": value}, "option": {"f1": value}},
        "option": {"precision": value, "recall": value, "f1": value},
        "option_visible": {"precision": value, "recall": value, "f1": value},
        "unit_accuracy": value,
        "unit_accuracy_positive": value,
        "unit_accuracy_negative": value,
        "unit_examples_positive": 1,
        "unit_examples_negative": 1,
        "question_false_positive_rate": value,
        "negatives": 1,
    }


def evaluation(value: float) -> dict[str, object]:
    parts = {part: metric(value) for part in ("ask", "real", "synthetic")}
    return {**metric(value), "parts": parts}


def test_summarize_reports_mean_and_sd_per_part(tmp_path) -> None:
    runs = []
    for index, value in enumerate((0.5, 0.7)):
        data = evaluation(value)
        path = tmp_path / f"eval-{index}.json"
        path.write_text(json.dumps(data))
        runs.append({"eval": str(path), "bold": False})
    result = summarize(runs)
    assert result["count"] == 2
    real = result["parts"]["real"]
    assert real["option_f1"]["mean"] == 0.6
    assert abs(real["option_f1"]["sd"] - 0.1414213562373095) < 1e-9
    assert result["parts"]["union"]["option_visible_f1"]["mean"] == 0.6


def test_summarize_single_run_has_zero_sd(tmp_path) -> None:
    data = evaluation(0.5)
    path = tmp_path / "eval.json"
    path.write_text(json.dumps(data))
    result = summarize([{"eval": str(path), "bold": False}])
    assert result["parts"]["real"]["option_f1"] == {"mean": 0.5, "sd": 0.0}


def test_chosen_checkpoint_is_seed_zero_even_when_another_seed_scores_higher(tmp_path) -> None:
    runs = []
    for seed, value in ((0, 0.5), (2, 0.9)):
        output = tmp_path / f"phase2-nobold-s{seed}"
        output.mkdir()
        data = evaluation(value)
        data["errors_by_part"] = {"ask": {"exact_range": 0}}
        eval_path = output / "eval.json"
        eval_path.write_text(json.dumps(data))
        runs.append(
            {
                "name": f"phase2-nobold-s{seed}",
                "bold": False,
                "seed": seed,
                "output": str(output),
                "eval": str(eval_path),
            }
        )
    input_path = tmp_path / "train-seeds.json"
    input_path.write_text(
        json.dumps(
            {
                "config": {"base_model": "m", "seeds": {"nobold": [0, 2], "bold": []}},
                "chosen": "phase2-nobold-s0",
                "decisions": {},
                "runs": runs,
            }
        )
    )
    output_path = tmp_path / "summary.json"
    main(["--input", str(input_path), "--output", str(output_path)])
    result = json.loads(output_path.read_text())
    assert result["chosen"] == "phase2-nobold-s0"
    assert result["groups"]["nobold"]["parts"]["real"]["option_f1"]["mean"] == 0.7
