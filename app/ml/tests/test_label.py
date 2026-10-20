import json
from pathlib import Path

from label import dry_run, label_one, parse_response, request_body

PROMPT = "  1: Intro.\n> 2: Pick one? alpha or beta"


def test_request_body_asks_for_json_without_thinking() -> None:
    body = request_body("deepseek-flash", PROMPT)
    assert body["model"] == "deepseek-flash"
    assert body["response_format"] == {"type": "json_object"}
    assert body["thinking"] == {"type": "disabled"}
    assert body["max_tokens"] == 2048
    assert "exactly 2 line classes" in str(body["messages"][0])
    assert body["messages"][1]["content"] == PROMPT


def test_dry_run_writes_bodies(tmp_path: Path) -> None:
    output = tmp_path / "requests.jsonl"
    counts = dry_run([{"id": "a", "prompt": PROMPT}], output, "deepseek-flash")
    assert counts == {"requests": 1}
    body = json.loads(output.read_text())
    assert body["messages"][1]["content"] == PROMPT


def test_unredacted_input_is_refused_without_network() -> None:
    label, errors = label_one(None, "deepseek-flash", "email me at alice@example.com", "alice")
    assert label is None
    assert errors == ["input is not redacted"]


def test_parse_response_accepts_fences() -> None:
    assert parse_response('```json\n{"lines": []}\n```') == {"lines": []}


def test_one_retry_uses_the_rejection_reason() -> None:
    from types import SimpleNamespace

    replies = [
        '{"lines": ["other"]}',
        '{"lines": ["other", "question"], "options": []}',
    ]

    class Completions:
        def __init__(self) -> None:
            self.calls: list[dict[str, object]] = []

        def create(self, **kwargs):
            self.calls.append(kwargs)
            content = replies[len(self.calls) - 1]
            return SimpleNamespace(
                choices=[SimpleNamespace(message=SimpleNamespace(content=content))]
            )

    completions = Completions()
    client = SimpleNamespace(chat=SimpleNamespace(completions=completions))
    label, errors = label_one(client, "deepseek-flash", PROMPT, "a-user")
    assert errors == []
    assert label == {"lines": ["other", "question"], "options": []}
    assert len(completions.calls) == 2
    retry = completions.calls[1]
    assert "rejected" in retry["messages"][-1]["content"]


def test_ask_gold_comes_from_the_tool_call() -> None:
    from render import ask_label

    record = {
        "prompt": "> 1: Which one?\n  2: \n  3: 1. **Red**\n  4: 2. **Blue**",
        "ranges": [[0, 0], [2, 3]],
        "hovered": 0,
        "ask": {"question": "Which one?", "labels": ["Red", "Blue"]},
    }
    label = ask_label(record)
    assert label == {
        "lines": ["question", "other", "option", "option"],
        "options": [
            {"line": 3, "text": "Red"},
            {"line": 4, "text": "Blue"},
        ],
    }
