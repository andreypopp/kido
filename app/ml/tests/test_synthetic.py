import random

from synthetic import (
    EVAL_FAMILIES,
    NEGATIVE_KINDS,
    TRAIN_FAMILIES,
    build,
    generate,
    make_example,
)
from validate import label_errors, option_kinds


def test_every_family_has_exact_labels() -> None:
    for families in (TRAIN_FAMILIES, EVAL_FAMILIES):
        for family in families:
            for seed in range(5):
                record = make_example(random.Random(seed), family, f"{family.id}-{seed}")
                assert label_errors(str(record["prompt"]), record["label"]) == []
                classes = record["label"]["lines"]
                if family.kind in NEGATIVE_KINDS:
                    assert "question" not in classes
                else:
                    assert "question" in classes


def test_negative_subtypes_keep_their_structure() -> None:
    by_id = {family.id: family for family in TRAIN_FAMILIES}
    code = make_example(random.Random(0), by_id["train-code"], "s")
    assert any("  def " in line or "  for " in line for line in code["prompt"].splitlines())
    assert "question" not in code["label"]["lines"]
    user = make_example(random.Random(0), by_id["train-userq"], "s")
    assert any("**User:**" in line for line in user["prompt"].splitlines())
    assert "question" not in user["label"]["lines"]
    diff = make_example(random.Random(0), by_id["train-diff"], "s")
    assert any("--- a/" in line for line in diff["prompt"].splitlines())
    assert "question" not in diff["label"]["lines"]


def test_list_and_inline_option_kinds() -> None:
    by_id = {family.id: family for family in TRAIN_FAMILIES}
    listed = make_example(random.Random(1), by_id["train-db"], "s")
    assert option_kinds(listed)["list"] > 0
    inline = make_example(random.Random(1), by_id["train-inline-one"], "s")
    assert option_kinds(inline)["inline"] > 0


def test_eval_families_are_disjoint_from_train() -> None:
    train = {family.id for family in TRAIN_FAMILIES}
    evaluation = {family.id for family in EVAL_FAMILIES}
    assert train.isdisjoint(evaluation)
    train_forms = {form for family in TRAIN_FAMILIES for form in family.questions}
    eval_forms = {form for family in EVAL_FAMILIES for form in family.questions}
    assert train_forms.isdisjoint(eval_forms)
    train_content = {value for family in TRAIN_FAMILIES for value in family.contents}
    eval_content = {value for family in EVAL_FAMILIES for value in family.contents}
    assert train_content.isdisjoint(eval_content)


def test_generation_has_both_classes_and_no_duplicates() -> None:
    rng = random.Random(0)
    records, dropped = generate(rng, TRAIN_FAMILIES, 60, "train")
    prompts = [str(record["prompt"]) for record in records]
    assert len(prompts) == len(set(prompts))
    assert dropped >= 0
    positives = sum(1 for record in records if "question" in record["label"]["lines"])
    assert 0 < positives < len(records)


def test_build_writes_split_files(tmp_path) -> None:
    counts = build(tmp_path, train_count=30, eval_count=10)
    assert counts["train"] > 0
    assert counts["eval"] > 0
    assert counts["train_option_spans"] > 0
    assert counts["train_option_kinds"]["list"] > 0
