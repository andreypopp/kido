import random

import torch
from conftest import WordTokenizer

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
