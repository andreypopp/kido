import json
from pathlib import Path

import pytest

from tagger import read_context, summarise

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


class CharTokenizer:
    pad_token_id = 0

    def __call__(self, text: str, **_: object) -> dict[str, list]:
        return {
            "input_ids": list(range(1, len(text) + 2)),
            "attention_mask": [1] * (len(text) + 2),
            "offset_mapping": [(0, 0)]
            + [(index, index + 1) for index in range(len(text))]
            + [(0, 0)],
        }


TOKENIZER = CharTokenizer()


def text_of(name: str) -> str:
    return (FIXTURES / name).read_bytes().decode()


def offsets(prompt: str) -> list[list[int]]:
    return [[0, 0]] + [[index, index + 1] for index in range(len(prompt))] + [[0, 0]]


def tag(prompt: str, spans: list[tuple[int, int, str]]) -> list[str]:
    tags = ["O"] * (len(prompt) + 2)
    for start, end, name in spans:
        for index in range(start, end):
            prefix = "B" if index == start else "I"
            tags[index + 1] = f"{prefix}-{name.upper()}"
    return tags


def list_context():
    text = text_of("list_question.txt")
    return (text,) + read_context(text, None, TOKENIZER)


def test_list_fixture_marks_one_hovered_paragraph() -> None:
    text, prompt, mapping, ranges, hovered, dropped, shape, _, _, _ = list_context()
    assert hovered == 1
    assert dropped == 0
    assert shape == 512
    assert ranges == [[0, 0], [2, 2], [4, 6], [8, 8]]
    assert prompt.splitlines()[2].startswith("> 3: Which colour")
    assert "**" not in prompt
    assert len(mapping) == len(prompt)


def test_hover_flag_marks_another_paragraph() -> None:
    prompt, mapping, ranges, hovered, _, _, _, _, _ = read_context(
        text_of("list_question.txt"), 5, TOKENIZER
    )
    assert hovered == 2
    assert prompt.splitlines()[4].startswith("> 5: 1. Teal")
    assert prompt.splitlines()[2].startswith("  3: Which colour")


def test_missing_hover_and_empty_input_are_errors() -> None:
    with pytest.raises(ValueError, match="no hovered line"):
        read_context("Plain line\n", None, TOKENIZER)
    with pytest.raises(ValueError, match="empty context"):
        read_context("", None, TOKENIZER)


def test_list_question_unit_and_options_address_the_input() -> None:
    text, prompt, mapping, ranges, hovered, _, _, _, _, _ = list_context()
    question = prompt.index("Which colour should the banner use?")
    spans = [
        (question, question + len("Which colour should the banner use?"), "question")
    ]
    for name in ("Teal", "Amber", "Slate"):
        start = prompt.index(name)
        spans.append((start, start + len(name), "option"))
    result = summarise(
        prompt, offsets(prompt), tag(prompt, spans), ranges, hovered, mapping
    )
    payload = json.loads(json.dumps(result))
    assert list(payload)[:2] == ["question", "options"]
    assert result["question"] == "Which colour should the banner use?"
    assert result["options"] == ["Teal", "Amber", "Slate"]
    assert result["isQuestion"] is True
    assert (result["firstLine"], result["lastLine"]) == (3, 7)
    for option in result["optionRanges"]:
        assert text[option["start"] : option["end"]] == option["text"]


def test_crlf_bold_tab_and_leading_space_keep_input_offsets() -> None:
    text = text_of("tricky.txt")
    assert "\r\n" in text
    prompt, mapping, ranges, hovered, dropped, _, _, _, _ = read_context(
        text, None, TOKENIZER
    )
    assert dropped == 0
    spans = []
    line = prompt.splitlines()[2]
    start = prompt.index(line[5:])
    spans.append((start, start + len(line[5:]), "question"))
    for name in ("Alpha", "Beta"):
        index = prompt.index(name)
        spans.append((index, index + len(name), "option"))
    result = summarise(
        prompt, offsets(prompt), tag(prompt, spans), ranges, hovered, mapping
    )
    assert [option["text"] for option in result["optionRanges"]] == ["Alpha", "Beta"]
    for option in result["optionRanges"]:
        assert text[option["start"] : option["end"]] == option["text"]
        assert "\t" not in option["text"]


def test_inline_question_keeps_the_sentence() -> None:
    text = text_of("inline_question.txt")
    prompt, mapping, ranges, hovered, _, _, _, _, _ = read_context(
        text, None, TOKENIZER
    )
    question = prompt.splitlines()[2][5:]
    start = prompt.index(question)
    spans = [(start, start + len(question), "question")]
    for name in ("update the docs", "keep the change small"):
        index = prompt.index(name)
        spans.append((index, index + len(name), "option"))
    result = summarise(
        prompt, offsets(prompt), tag(prompt, spans), ranges, hovered, mapping
    )
    assert result["isQuestion"] is True
    assert result["question"] == question
    assert (result["firstLine"], result["lastLine"]) == (3, 3)
    assert [option["text"] for option in result["optionRanges"]] == [
        "update the docs",
        "keep the change small",
    ]
    assert {option["kind"] for option in result["optionRanges"]} == {"inline"}
    for option in result["optionRanges"]:
        assert text[option["start"] : option["end"]] == option["text"]


def test_unit_with_only_list_options_has_no_question() -> None:
    text = text_of("list_question.txt")
    prompt, mapping, ranges, hovered, _, _, _, _, _ = read_context(
        text, 5, TOKENIZER
    )
    spans = []
    for name in ("Teal", "Amber", "Slate"):
        index = prompt.index(name)
        spans.append((index, index + len(name), "option"))
    result = summarise(
        prompt, offsets(prompt), tag(prompt, spans), ranges, hovered, mapping
    )
    assert result["isQuestion"] is True
    assert result["question"] is None
    assert result["options"] == ["Teal", "Amber", "Slate"]


def test_plain_context_has_no_unit_question_or_options() -> None:
    text = text_of("plain.txt")
    prompt, mapping, ranges, hovered, _, _, _, _, _ = read_context(
        text, None, TOKENIZER
    )
    result = summarise(prompt, offsets(prompt), tag(prompt, []), ranges, hovered, mapping)
    assert result["isQuestion"] is False
    assert result["options"] == []
    assert result["question"] is None
    assert (result["firstLine"], result["lastLine"]) == (3, 3)


def test_long_context_drops_outer_paragraphs_and_keeps_the_hovered_one() -> None:
    paragraphs = [f"Paragraph {index} says " + "word " * 20 for index in range(80)]
    text = "\n\n".join(paragraphs) + "\n\n> Final question?"
    prompt, mapping, ranges, hovered, dropped, shape, ids, _, _ = read_context(
        text, None, TOKENIZER
    )
    assert dropped > 0
    assert shape == 2048
    assert len(ids) <= 2048
    assert "Final question?" in prompt
    assert ranges[hovered] == [len(prompt.splitlines()) - 1, len(prompt.splitlines()) - 1]


def test_hovered_paragraph_longer_than_the_largest_shape_is_an_error() -> None:
    with pytest.raises(ValueError, match="longer than 2048"):
        read_context("> " + "x" * 3000, None, TOKENIZER)


def test_coreml_smoke_on_the_list_fixture() -> None:
    from eval import CoreML, tags_from_logits, tokenize
    from runtime import PACKAGE, chosen_checkpoint

    checkpoint = chosen_checkpoint()
    if not PACKAGE.exists() or not checkpoint.exists():
        pytest.skip("the converted package and checkpoint are absent")
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(checkpoint)
    text = text_of("list_question.txt")
    prompt, mapping, ranges, hovered, _, _, _, _, _ = read_context(text, None, tokenizer)
    ids, mask, positions = tokenize(tokenizer, prompt, 1024)
    backend = CoreML(PACKAGE, "gpu", tokenizer.pad_token_id)
    backend.load([512])
    tags = tags_from_logits(backend.logits(ids, mask))
    result = summarise(prompt, positions, tags, ranges, hovered, mapping)
    assert len(result["tags"]) == len(positions)
    assert result["firstLine"] <= result["lastLine"]
    for option in result["optionRanges"]:
        assert option["start"] < option["end"] <= len(text)
        assert text[option["start"] : option["end"]] == option["text"]


def test_measure_load_covers_construction_and_the_first_prediction(monkeypatch) -> None:
    from bench import measure_load

    events = []

    class Clock:
        def __init__(self) -> None:
            self.values = iter((10.0, 15.0))

        def __call__(self) -> float:
            return next(self.values)

    class Backend:
        def load(self) -> None:
            events.append("load")

        def predict(self, shape) -> None:
            events.append(("predict", shape))

    backend = Backend()
    monkeypatch.setattr("bench.time.perf_counter", Clock())
    assert measure_load(backend.load, lambda: backend.predict(512)) == 5000.0
    assert events == ["load", ("predict", 512)]


def test_coreml_cli_json_and_clean_stderr(capsys) -> None:
    import tagger
    from runtime import PACKAGE, chosen_checkpoint

    if not PACKAGE.exists() or not chosen_checkpoint().exists():
        pytest.skip("the converted package and checkpoint are absent")
    code = tagger.main(
        [
            str(FIXTURES / "list_question.txt"),
            "--backend",
            "coreml",
            "--compute",
            "gpu",
            "--json",
        ]
    )
    captured = capsys.readouterr()
    assert code == 0
    assert captured.err == ""
    payload = json.loads(captured.out)
    assert list(payload)[:2] == ["question", "options"]
    assert payload["isQuestion"] is True


def test_torch_cli_keeps_stderr_clean(capsys) -> None:
    import tagger
    from runtime import chosen_checkpoint

    if not chosen_checkpoint().exists():
        pytest.skip("the checkpoint is absent")
    code = tagger.main([str(FIXTURES / "list_question.txt"), "--json"])
    captured = capsys.readouterr()
    assert code == 0
    assert captured.err == ""
