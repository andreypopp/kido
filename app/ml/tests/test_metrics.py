from metrics import Counts, add_text, f1, summary


def test_f1() -> None:
    assert f1(1, 2, 2) == 0.5
    assert f1(0, 0, 0) == 1.0
    assert f1(0, 1, 1) == 0.0


def test_perfect_and_wrong_outputs() -> None:
    counts = Counts()
    gold = [(0, 10, ("aaa", "bbb")), (20, 30, ())]
    add_text(counts, gold, list(gold))
    add_text(counts, [], [])
    add_text(counts, [], [(0, 5, ())])
    result = summary(counts)
    assert result["question_f1"] == 0.8
    assert result["whole_output_exact"] == round(2 / 3, 4)
    assert result["false_positive_rate"] == 0.5
    assert result["option_f1_end_to_end"] == 1.0


def test_merge_split_and_options() -> None:
    counts = Counts()
    add_text(counts, [(0, 5, ()), (6, 10, ())], [(0, 10, ())])
    assert (counts.merges, counts.splits, counts.matched) == (1, 0, 0)
    add_text(counts, [(0, 10, ("abc",))], [(0, 4, ()), (5, 10, ())])
    assert (counts.merges, counts.splits) == (1, 1)
    add_text(counts, [(0, 10, ("abc", "def"))], [(0, 10, ("abc", "xyz"))])
    assert (counts.option_matched, counts.option_gold, counts.option_predicted) == (1, 3, 2)
