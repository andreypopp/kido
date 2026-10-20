from render import CLAUDE, PI, render_markdown
from segments import segments


def pieces(markdown: str, style, width: int = 80) -> list[str]:
    text = "\n".join(render_markdown(markdown, width, style))
    return [text[s.start : s.end] for s in segments(text)]


QUESTION = "I checked the config. Which one do you want?\n\n- update the docs\n- keep the change"


def test_a_question_with_options_in_both_tuis() -> None:
    expected = [
        "I checked the config.",
        "Which one do you want?",
        "",
        "- update the docs",
        "- keep the change",
    ]
    assert pieces(QUESTION, PI) == expected
    assert pieces(QUESTION, CLAUDE) == expected


def test_a_wrapped_item_and_a_wrapped_paragraph_stay_whole() -> None:
    markdown = "1. " + "word " * 12 + "end.\n\n" + "para " * 12 + "end. Next?"
    for style in (PI, CLAUDE):
        got = pieces(markdown, style, 30)
        assert len(got) == 4
        assert got[0].startswith("1. word") and "\n" in got[0]
        assert got[2].count("\n") >= 1 and got[3] == "Next?"


def test_pi_code_never_joins_the_question_after_it() -> None:
    markdown = "Run it:\n\n```sh\nmake test\nmake lint\n```\nShould I go on?"
    assert pieces(markdown, PI) == [
        "Run it:",
        "",
        "```sh",
        "make test",
        "make lint",
        "```",
        "",
        "Should I go on?",
    ]


def test_claude_code_is_split_by_its_blank_rows() -> None:
    markdown = "Run it:\n\n```sh\nmake test\n```\n\nShould I go on?"
    assert pieces(markdown, CLAUDE) == ["Run it:", "", "make test", "", "Should I go on?"]
