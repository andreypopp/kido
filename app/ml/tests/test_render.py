import json
from pathlib import Path

from render import (
    Row,
    character_count,
    cut_context,
    logical_lines,
    render_ask,
    render_markdown,
)

FIXTURE = Path(__file__).parent.parent / "fixtures" / "context.json"


def test_shared_context_fixture() -> None:
    data = json.loads(FIXTURE.read_text())
    for case in data["cases"]:
        rows = [Row(text, wrapped) for text, wrapped in case["rows"]]
        context = cut_context(rows, case["row"])
        if case["hovered"] is None:
            assert context is None
            continue
        assert context is not None
        assert context.hovered == case["hovered"], case["name"]
        assert [list(pair) for pair in context.ranges] == case["ranges"], case["name"]
        assert context.prompt == case["prompt"], case["name"]


def test_wrapped_rows_join_without_separator_and_trim() -> None:
    rows = [Row("one  ", True), Row("two\t", True), Row("three \t", False)]
    lines = logical_lines(rows)
    assert [line.text for line in lines] == ["one  two\tthree"]


def test_blank_lines_split_paragraphs() -> None:
    rows = [Row("a", False), Row("", False), Row(" ", False), Row("b", False)]
    context = cut_context(rows, 3)
    assert context is not None
    assert context.prompt == "  1: a\n  2: \n  3: \n> 4: b"


def test_grapheme_character_count() -> None:
    assert character_count("e\u0301") == 1
    assert character_count("👨‍👩‍👧‍👦") == 1
    assert character_count("日本") == 2


def test_character_limit_stops_the_far_side() -> None:
    first = "a" * 2500
    hovered = "b" * 2500
    last = "c" * 2500
    rows = [
        Row(first, False),
        Row("", False),
        Row(hovered, False),
        Row("", False),
        Row(last, False),
    ]
    context = cut_context(rows, 2)
    assert context is not None
    assert context.prompt.count("\n") == 2
    assert context.prompt.startswith("  1: " + first)
    assert context.prompt.endswith(hovered)


def test_line_limit_stops_the_far_side() -> None:
    def paragraph(letter: str, count: int) -> list[Row]:
        return [Row(f"{letter}{index}", False) for index in range(count)]

    rows = (
        paragraph("a", 30)
        + [Row("", False)]
        + paragraph("b", 2)
        + [Row("", False)]
        + paragraph("c", 30)
    )
    context = cut_context(rows, 31)
    assert context is not None
    assert context.prompt.count("\n") == 32
    assert context.prompt.startswith("  1: a0")
    assert context.prompt.endswith("> 33: b1")


def test_render_markdown_keeps_structure() -> None:
    markdown = """# Title

Paragraph with **bold**, *em*, `code` and [link](https://example.com).

- one
  - nested
- two

1. first
2. second

> quoted
> line

```sh
echo **keep**
```

| a | b |
| - | - |
| 1 | 2 |
"""
    rows = render_markdown(markdown, 40)
    lines = [line.text for line in logical_lines(rows)]
    assert lines[0] == "Title"
    assert "Paragraph with **bold**, em, code and link." in lines
    assert "  - nested" in lines
    assert "1. first" in lines
    assert "│ quoted line" in lines
    assert "  echo **keep**" in lines
    assert "| a | b |" in lines
    assert all("#" not in line for line in lines)


def test_render_markdown_wraps_and_indents() -> None:
    markdown = "- " + "word " * 12
    rows = render_markdown(markdown, 30)
    lines = logical_lines(rows)
    assert len(lines) == 1
    assert all(len(row.text) <= 30 for row in rows)
    assert rows[0].text.startswith("- ")
    assert rows[1].text.startswith("  ")
    assert all(row.wrapped for row in rows[:-1])


def test_render_ask_is_question_and_numbered_bold_labels() -> None:
    rows = render_markdown(render_ask("Which one?", ["Red", "Blue"]), 80)
    lines = [line.text for line in logical_lines(rows)]
    assert lines == ["Which one?", "", "1. **Red**", "2. **Blue**"]


def test_hover_variants_keep_labels_and_context() -> None:
    from render import context_record, derive_variants

    rows = [
        Row("First paragraph.", False),
        Row("", False),
        Row("Which option should I use?", False),
        Row("", False),
        Row("1. alpha", False),
        Row("2. beta", False),
        Row("", False),
        Row("Last paragraph.", False),
    ]
    context = cut_context(rows, 2)
    assert context is not None
    record = context_record(
        session="s",
        source="pi",
        context=context,
        width=80,
        user="a-user",
        label={"lines": ["other", "other", "question", "other", "option", "option"], "options": []},
    )
    assert record is not None
    import random

    variants = derive_variants(record, random.Random(0), maximum=3)
    assert len(variants) == 3
    assert len({variant["context_id"] for variant in variants}) == 1
    assert len({variant["id"] for variant in variants}) == 3
    assert variants[0]["hovered"] == record["hovered"]
    for variant in variants:
        start, end = variant["ranges"][variant["hovered"]]
        assert all(
            line.startswith(">") or line.startswith(" ")
            for line in variant["prompt"].splitlines()
        )
        marked = [
            index
            for index, line in enumerate(variant["prompt"].splitlines())
            if line.startswith(">")
        ]
        assert marked == list(range(start, end + 1))


def test_detached_removes_the_hover_marker_only() -> None:
    from render import detached

    assert detached("> 1: alpha\n  2: beta") == "  1: alpha\n  2: beta"
    assert detached("no marker") == "no marker"


def test_normalized_ignores_hover_unless_asked() -> None:
    from render import normalized

    prompt = "> 1: alpha   beta\n  2: gamma"
    assert normalized(prompt) == "alpha beta\ngamma"
    assert normalized(prompt, hover=True) == "> alpha beta\n  gamma"


def test_hash_records_is_order_independent() -> None:
    from render import hash_records

    first = [{"id": "a", "prompt": "x"}, {"id": "b", "prompt": "y"}]
    second = list(reversed(first))
    assert hash_records(first) == hash_records(second)
