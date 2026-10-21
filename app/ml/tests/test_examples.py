import random

from conftest import WordTokenizer

from chunks import IGNORE, B, I, O
from examples import make_item, moves, option_spans, perturbed_examples
from questions import question_item
from segments import segments

TOKENIZER = WordTokenizer()
TEXT = "Intro line.\n\nWhich one?\n- alpha beta\n- gamma\n\nTail note.\n\nOk to stop?"


def record() -> dict[str, object]:
    items = [
        question_item(TEXT, 3, 5, "choice", ["alpha beta", "gamma"]),
        question_item(TEXT, 9, 9, "yes_no"),
    ]
    return {"text": TEXT, "label": {"questions": items}}


def test_option_labels_mark_the_first_token_of_each_option() -> None:
    item = make_item(TOKENIZER, record())
    assert item.options[0]["labels"] == [IGNORE, O, O, O, B, I, O, B, IGNORE]
    assert set(item.options[1]["labels"]) == {IGNORE, O}


def test_moves_add_or_remove_one_segment_and_never_take_another_question() -> None:
    item = make_item(TOKENIZER, record())
    cuts = item.enc.cuts
    assert item.gold == [(2, 4), (8, 8)]
    assert moves(cuts, item.gold, 0) == [(0, 4), (2, 6), (3, 4), (2, 3)]
    assert moves(cuts, item.gold, 1) == [(6, 8)]
    near = [(2, 4), (6, 8)]
    assert (2, 6) not in moves(cuts, near, 0)


def test_perturbed_examples_are_a_share_of_the_gold_questions() -> None:
    items = [make_item(TOKENIZER, record()) for _ in range(10)]
    examples = perturbed_examples(TOKENIZER, items, random.Random(0))
    assert len(examples) == round(0.2 * 20)
    assert all(len(e["ids"]) == len(e["labels"]) for e in examples)


def test_a_removed_segment_takes_its_options_with_it() -> None:
    cuts = segments(TEXT)
    question = make_item(TOKENIZER, record()).questions[0]
    spans = option_spans(TEXT, question, cuts[2].start, cuts[3].end)
    assert [TEXT[a:b] for a, b in spans] == ["alpha beta"]
    assert len(option_spans(TEXT, question, question.start, question.end)) == 2
