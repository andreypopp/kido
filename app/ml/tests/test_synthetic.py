import random

from synthetic import EVAL, TRAIN, make_example
from validate import label_errors


def test_every_template_has_exact_labels() -> None:
    rng = random.Random(0)
    for templates, session in ((TRAIN, "train"), (EVAL, "eval")):
        for template in templates:
            for positive in (True, False):
                record = make_example(rng, template, positive, f"{session}-{template[2]}")
                assert record is not None
                assert label_errors(str(record["prompt"]), record["label"]) == []
                classes = record["label"]["lines"]
                assert ("question" in classes) is positive


def test_eval_templates_are_disjoint_from_train() -> None:
    assert {template[2] for template in TRAIN}.isdisjoint({template[2] for template in EVAL})
    assert {template[0] for template in TRAIN}.isdisjoint({template[0] for template in EVAL})
