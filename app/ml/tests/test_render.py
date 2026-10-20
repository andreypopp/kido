from pathlib import Path

from conftest import USER

from jsonl import write_jsonl
from render import (
    CLAUDE,
    PI,
    Message,
    ask_sessions,
    render_markdown,
    render_text,
    text_width,
    transcript_messages,
    wrap_words,
)


def test_wide_characters_take_two_cells() -> None:
    assert text_width("日本") == 4
    assert text_width("e\u0301") == 1
    assert wrap_words("日本語 日本語", 6) == ["日本語", "日本語"]


def test_wrap_breaks_at_words_and_cuts_a_long_word() -> None:
    assert wrap_words("aaa bbb ccc", 7) == ["aaa bbb", "ccc"]
    assert wrap_words("abcdefghij", 4) == ["abcd", "efgh", "ij"]


def test_pi_layout() -> None:
    markdown = """# Title

### Small

Intro with **bold**, *em*, `code` and [link](https://example.com).
- one
  - nested
- two

1. first
2. second

```sh
echo hi
```

> quoted
"""
    assert render_markdown(markdown, 60, PI) == [
        "Title",
        "",
        "### Small",
        "",
        "Intro with bold, em, code and link.",
        "- one",
        "    - nested",
        "- two",
        "",
        "1. first",
        "2. second",
        "",
        "```sh",
        "  echo hi",
        "```",
        "",
        "│ quoted",
    ]


def test_pi_wraps_a_list_item_with_a_hanging_indent() -> None:
    rows = render_markdown("- " + "word " * 12, 30, PI)
    assert len(rows) > 1
    assert rows[0].startswith("- ")
    assert all(row.startswith("  ") for row in rows[1:])
    assert all(text_width(row) <= 30 for row in rows)


def test_claude_layout() -> None:
    markdown = "Intro:\n- one\n- two\n\n## Head\n\n```\ncode\n```\nAfter [a](https://x.io/p)."
    assert render_markdown(markdown, 40, CLAUDE) == [
        "⏺ Intro:",
        "  - one",
        "  - two",
        "",
        "  Head",
        "",
        "  code",
        "  After a (https://x.io/p).",
    ]


def test_a_source_newline_is_a_row_break() -> None:
    assert render_markdown("one\ntwo", 40, PI) == ["one", "two"]


def test_render_text_redacts_before_it_renders() -> None:
    assert render_text("mail alice@example.com", 80, PI, USER) == "mail user@example.com"


def write(path: Path, lines: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_jsonl(path, lines)


def test_transcript_messages_read_pi_and_claude_in_order(tmp_path: Path) -> None:
    long = "x" * 300
    write(
        tmp_path / "pi" / "a.jsonl",
        [
            {"type": "session", "id": "s1"},
            {
                "type": "message",
                "message": {"role": "user", "content": [{"type": "text", "text": long}]},
            },
            {
                "type": "message",
                "message": {
                    "role": "assistant",
                    "content": [
                        {"type": "text", "text": "Short question?"},
                        {"type": "toolCall"},
                        {"type": "text", "text": "  " + long + "?  "},
                    ],
                },
            },
        ],
    )
    write(
        tmp_path / "claude" / "b.jsonl",
        [
            {
                "type": "user",
                "sessionId": "c1",
                "message": {"content": [{"type": "text", "text": long}]},
            },
            {
                "type": "assistant",
                "sessionId": "c1",
                "message": {"content": [{"type": "text", "text": long}]},
            },
        ],
    )
    assert list(transcript_messages(tmp_path / "pi", "pi")) == [
        Message("s1", "Short question?"),
        Message("s1", long + "?"),
    ]
    assert list(transcript_messages(tmp_path / "claude", "claude")) == [Message("c1", long)]


def test_ask_sessions_need_only_the_call(tmp_path: Path) -> None:
    def call(payload: object) -> dict[str, object]:
        block = {"type": "tool_use", "name": "AskUserQuestion", "input": payload}
        return {"type": "assistant", "sessionId": "with-call", "message": {"content": [block]}}

    write(tmp_path / "a.jsonl", [call({"questions": []}), call("junk")])
    write(
        tmp_path / "b.jsonl",
        [
            {
                "type": "assistant",
                "sessionId": "plain",
                "message": {"content": [{"type": "text", "text": "x"}]},
            }
        ],
    )
    assert ask_sessions(tmp_path) == {"with-call"}
