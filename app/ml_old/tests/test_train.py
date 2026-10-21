import random

import torch
from conftest import WordTokenizer, tiny, tiny_two_ends

from examples import make_item
from questions import question_item
from train import Settings, batches, epoch_streams, schedule, tensors

TOKENIZER = WordTokenizer()
TEXT = "Intro line.\n\nWhich one?\n- alpha beta\n- gamma\n\nOk to stop?"


def items(count: int):
    label = {
        "questions": [
            question_item(TEXT, 3, 5, "choice", ["alpha beta", "gamma"]),
            question_item(TEXT, 7, 7, "yes_no"),
        ]
    }
    return [make_item(TOKENIZER, {"text": TEXT, "label": label}) for _ in range(count)]


def test_batches_have_similar_lengths_and_pad_to_a_multiple_of_32() -> None:
    examples = [{"ids": [1] * n, "labels": [0] * n} for n in (3, 9, 4, 8, 30, 31, 5, 7)]
    out = batches(examples, 2, random.Random(0))
    assert sorted(len(e["ids"]) for b in out for e in b) == sorted(len(e["ids"]) for e in examples)
    ids, mask, labels = tensors(out[0], 0, torch.device("cpu"))
    assert ids.shape == mask.shape == labels.shape
    assert ids.shape[1] % 32 == 0


def test_each_task_sees_each_batch_once_in_both_architectures() -> None:
    settings = Settings("joint", "", 0, 1, 5e-5, 4, 8, None, False)
    rng = random.Random(0)
    joint = epoch_streams(("question", "option"), TOKENIZER, items(20), settings, rng)
    two = [
        epoch_streams((task,), TOKENIZER, items(20), settings, rng)[task]
        for task in ("question", "option")
    ]
    assert [len(joint["question"]), len(joint["option"])] == [len(t) for t in two]
    order = schedule(joint, rng)
    assert order.count("question") == len(joint["question"])
    assert order.count("option") == len(joint["option"])


def test_the_crf_loss_trains_the_slot_scores_of_a_two_ends_head() -> None:
    from chunks import O, question_example, sample_chunks
    from crf import Crf
    from train import gather, slot_tensors

    (item,) = items(1)
    (chunk,) = sample_chunks(item.enc, item.gold, random.Random(0))
    example = question_example(item.enc, chunk, item.gold)
    assert [example["labels"][h] for h in example["heads"]] == [O, 1, 2, 2, 1]
    heads, lasts, tags, lengths, inside = slot_tensors([example], torch.device("cpu"))
    model, crf = tiny_two_ends(), Crf()
    ids, mask = torch.tensor([example["ids"]]), torch.ones(1, len(example["ids"]), dtype=torch.long)
    out = model(ids, mask, "question")
    emission = gather(out, heads)[..., :3] + gather(out, lasts)[..., 3:]
    loss = crf.nll(emission, tags, lengths, inside).sum() / lengths.sum()
    loss.backward()
    assert torch.isfinite(loss) and model.heads["question"].weight.grad.abs().sum() > 0
    assert crf.trans.grad.abs().sum() > 0


def test_the_clip_list_holds_each_parameter_once() -> None:
    from crf import Crf
    from train import clipped

    for crf in (None, Crf()):
        params = clipped(tiny_two_ends(), crf)
        assert len({id(p) for p in params}) == len(params)
    assert len(clipped(tiny_two_ends(), Crf())) == len(clipped(tiny_two_ends(), None)) + 2


def test_two_models_with_crf_keep_the_question_transitions(tmp_path, monkeypatch) -> None:
    import train
    from crf import Crf

    seen = {}

    def fake_fit(tasks, items, tokenizer, settings, after_epoch):
        crf = Crf() if settings.crf and "question" in tasks else None
        seen[tasks] = crf
        return tiny(tasks), crf.transitions() if crf else None, {}

    monkeypatch.setattr(train, "fit", fake_fit)
    monkeypatch.setattr(train, "make_item", lambda tokenizer, record: record)
    monkeypatch.setattr(train, "load_tokenizer", lambda: __import__("model").load_tokenizer())
    monkeypatch.setattr(train, "read_jsonl", lambda path: [])
    monkeypatch.setattr(train, "code_state", lambda: {})
    monkeypatch.setattr(train, "input_hashes", lambda **_: {})
    train.main(["--kind", "two", "--crf", "--output", str(tmp_path)])
    assert seen[("question",)] is not None and seen[("option",)] is None
    assert "crf" in (tmp_path / "settings.json").read_text()


def test_a_subsample_is_deterministic_per_seed_and_whole_by_session() -> None:
    from train import subsample

    records = [{"id": f"r{n}", "session": f"s{n % 10}", "source": "pi"} for n in range(50)]
    records += [{"id": f"syn{n}", "source": "synthetic"} for n in range(20)]
    first, digest = subsample(records, 0.5, 0)
    again, same = subsample(records, 0.5, 0)
    other, different = subsample(records, 0.5, 1)
    assert first == again and digest == same and digest != different
    real = [r for r in first if r["source"] == "pi"]
    assert len({r["session"] for r in real}) == 5 and len(real) == 25
    assert all(r["session"] in {x["session"] for x in real} for r in records if r in real)
    assert {r["session"] for r in real}.isdisjoint(
        {r["session"] for r in records if r["source"] == "pi" and r not in real}
    )
    assert sum(r["source"] == "synthetic" for r in first) == 10 and other != first


def test_a_question_run_needs_the_option_model_of_a_flat_run(tmp_path) -> None:
    import pytest

    import train

    with pytest.raises(SystemExit):
        train.main(["--kind", "question", "--output", str(tmp_path / "a")])
    (tmp_path / "old").mkdir()
    with pytest.raises(SystemExit):
        train.main(
            [
                "--kind",
                "question",
                "--option-from",
                str(tmp_path / "old"),
                "--output",
                str(tmp_path / "b"),
            ]
        )
    with pytest.raises(SystemExit):
        train.main(
            ["--kind", "two", "--option-from", str(tmp_path), "--output", str(tmp_path / "c")]
        )
