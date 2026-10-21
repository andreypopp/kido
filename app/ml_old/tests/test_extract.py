import argparse
import io
import json

import numpy as np
import pytest
from conftest import FakeBackend, WordTokenizer, paragraphs

from chunks import B, I, O, decode, emissions, encode, plan
from extract import contract, options, positive, predict, questions, read_input, runs
from flat import flatten

TOKENIZER = WordTokenizer()


def test_runs_are_b_then_i_and_an_orphan_i_starts_nothing() -> None:
    assert runs([O, B, I, I, O, I, I, B, B]) == [(1, 3), (7, 7), (8, 8)]
    assert runs([I, I]) == []
    assert runs([O, O]) == []


def test_a_question_that_spans_a_blank_row_is_one_range() -> None:
    text = "Intro here.\n\nWhich branch\n\n- main\n- dev\n\nDone."
    words = text.split()
    backend = FakeBackend({words.index("Which")}, {4, 6})
    (start, end) = questions(backend, encode(TOKENIZER, text))[0]
    assert text[start:end] == "Which branch\n\n- main\n- dev"


def test_a_question_at_a_chunk_edge_is_taken_from_the_other_chunk() -> None:
    text = paragraphs(40)
    words = text.split()
    first = words.index("p15w0")
    backend = FakeBackend({first}, {words.index("p16w0")})
    found = questions(backend, encode(TOKENIZER, text))
    assert [text[a:b] for a, b in found] == [text[text.index("p15w0") : text.index("p16w59") + 6]]


def test_options_are_substrings_in_text_order() -> None:
    text = "Should I update the docs or keep the change? Reply soon."
    backend = FakeBackend({2, 6}, {3, 4, 7, 8})
    found = options(TOKENIZER, backend, text, flatten(text), 0, 44)
    assert found == ("update the docs", "keep the change?")
    assert all(option in text for option in found)


def test_contract_and_ranges() -> None:
    text = "A? B"
    assert contract(text, [(0, 2, ("A",))]) == {"questions": [{"question": "A?", "options": ["A"]}]}
    assert contract(text, [(0, 2, ())], ranges=True)["questions"][0]["range"] == [0, 2]
    assert json.dumps(contract(text, []))
    assert predict(TOKENIZER, FakeBackend(set()), "Nothing here.") == []


def test_decode_with_a_threshold_keeps_only_confident_b() -> None:
    logits = np.log(
        np.array([[0.1, 0.6, 0.3], [0.1, 0.9, 0.0001], [0.5, 0.2, 0.3], [0.1, 0.3, 0.6]])
    )
    assert decode(logits) == [1, 1, 0, 2]
    assert decode(logits, 0.8) == [2, 1, 0, 2]
    assert runs(decode(logits, 0.8)) == [(1, 1)]


def test_input_keeps_line_ends_and_rejects_bad_utf8(tmp_path, monkeypatch) -> None:
    crlf = tmp_path / "crlf.txt"
    crlf.write_bytes(b"Which one?\r\n- a\r\n- b\r\n")
    assert read_input(crlf) == "Which one?\r\n- a\r\n- b\r\n"
    monkeypatch.setattr("sys.stdin", io.TextIOWrapper(io.BytesIO("é?\r\n".encode())))
    assert read_input(None) == "é?\r\n"
    monkeypatch.setattr("sys.stdin", io.TextIOWrapper(io.BytesIO(b"")))
    assert read_input(None) == ""
    monkeypatch.setattr("sys.stdin", io.TextIOWrapper(io.BytesIO(b"ok \xff")))
    with pytest.raises(ValueError, match="UTF-8"):
        read_input(None)


def test_ranges_hold_on_crlf_text_and_empty_text() -> None:
    text = "Intro.\r\n\r\nWhich one?\r\n"
    words = text.split()
    found = predict(TOKENIZER, FakeBackend({words.index("Which")}, set()), text)
    out = contract(text, found, ranges=True)["questions"][0]
    assert text[slice(*out["range"])] == out["question"]
    assert predict(TOKENIZER, FakeBackend(set()), "") == []


def test_bench_counts_must_be_positive() -> None:
    assert positive("3") == 3
    with pytest.raises(argparse.ArgumentTypeError):
        positive("0")


def test_a_crf_backend_decodes_a_question_after_prose_where_argmax_would_start_with_i() -> None:
    from crf import Crf
    from model import Backend

    class Scored(Backend):
        def logits(self, task, ids):
            out = np.zeros((len(ids), 6))
            out[:, 2] = 2.0  # I
            out[:, 1] = 1.0  # B a little behind
            out[0, 0] = out[1, 0] = 0.0
            return out

    text = "I checked the build.\n\nWhich one do you prefer?"
    enc = encode(TOKENIZER, text)
    (chunk,) = plan(enc)
    plain = Scored()
    assert plain.question_tags(enc, chunk) == [I, I]
    assert questions(plain, encode(TOKENIZER, text)) == []
    crf = Scored(crf=Crf().transitions())
    assert crf.question_tags(enc, chunk) == [B, I]
    ((start, end),) = questions(crf, encode(TOKENIZER, text))
    assert text[start:end] == text


def test_two_ends_emissions_add_the_last_token_columns() -> None:
    out = np.arange(18, dtype=np.float32).reshape(3, 6)
    assert emissions(out, [(0, 0, 2), (1, 1, 1)]).tolist() == [
        [0 + 15, 1 + 16, 2 + 17],
        [6 + 9, 7 + 10, 8 + 11],
    ]
    assert emissions(out[:, :3], [(0, 1, 1)]).tolist() == [[6, 7, 8]]


def test_a_checkpoint_for_another_input_is_refused(tmp_path) -> None:
    from extract import load, main

    (tmp_path / "settings.json").write_text('{"question_threshold": 0.8}')
    with pytest.raises(ValueError, match="train or convert it again") as error:
        load(tmp_path)
    assert str(tmp_path) in str(error.value)
    (tmp_path / "in.txt").write_text("Which one?")
    with pytest.raises(SystemExit, match="extract: .*train or convert") as exit_:
        main([str(tmp_path / "in.txt"), "--model", str(tmp_path)])
    assert exit_.value.code != 0
    with pytest.raises(ValueError):
        load(tmp_path / "missing", "coreml")
