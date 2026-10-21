from metrics import Counts, add_text, f1, summary
from segments import segments

TEXT = "Which one? Why?\n\nShould I stop?\n\nWhat now? Really?\n\nIt is done."
CUTS = segments(TEXT)


def test_f1() -> None:
    assert f1(1, 2, 2) == 0.5
    assert f1(0, 0, 0) == 1.0
    assert f1(0, 1, 1) == 0.0


def test_perfect_and_wrong_outputs() -> None:
    counts = Counts()
    gold = [(0, 10, ("aaa", "bbb")), (20, 30, ())]
    add_text(counts, gold, list(gold), CUTS)
    add_text(counts, [], [], CUTS)
    add_text(counts, [], [(0, 5, ())], CUTS)
    result = summary(counts)
    assert result["question_f1"] == 0.8
    assert result["whole_output_exact"] == round(2 / 3, 4)
    assert result["false_positive_rate"] == 0.5
    assert result["option_f1_end_to_end"] == 1.0
    assert result["errors"]["false_question"] == 1


def test_merge_split_and_options() -> None:
    counts = Counts()
    add_text(counts, [(0, 5, ()), (6, 10, ())], [(0, 10, ())], CUTS)
    assert (counts.errors["merge"], counts.errors["split"], counts.matched) == (1, 0, 0)
    add_text(counts, [(0, 10, ("abc",))], [(0, 4, ()), (5, 10, ())], CUTS)
    assert (counts.errors["merge"], counts.errors["split"]) == (1, 1)
    add_text(counts, [(0, 10, ("abc", "def"))], [(0, 10, ("abc", "xyz"))], CUTS)
    assert (counts.option_matched, counts.option_gold, counts.option_predicted) == (1, 3, 2)
    assert (counts.errors["missed_option"], counts.errors["spurious_option"]) == (1, 1)


def test_boundary_and_missed_questions_and_the_lenient_match() -> None:
    first, second, third = CUTS[0], CUTS[1], CUTS[3]
    gold = [(first.start, second.end, ()), (third.start, third.end, ())]
    counts = Counts()
    add_text(counts, gold, [(first.start, first.end, ())], CUTS)
    assert counts.errors["boundary"] == 1 and counts.errors["missed_question"] == 1
    assert counts.matched == 0 and counts.lenient_matched == 1
    add_text(counts, gold, [(first.start, CUTS[2].end, ())], CUTS)
    assert counts.lenient_matched == 2


def test_the_option_pass_alone_inside_gold_questions() -> None:
    counts = Counts()
    add_text(counts, [(0, 10, ("abc", "def"))], [], CUTS, [("abc",)])
    result = summary(counts)
    assert result["option_f1_in_gold"] == round(2 * 1 * 0.5 / 1.5, 4)
    assert summary(Counts())["option_f1_in_gold"] is None
