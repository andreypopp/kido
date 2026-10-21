"""End-to-end smoke of `extract` on the trained checkpoint: it skips until a checkpoint exists."""

import json
from pathlib import Path

import pytest

from coreml import COREML, load_coreml
from extract import extract, main
from model import CHECKPOINT, load, load_tokenizer, torch_taggers

FIXTURES = [
    p.read_text(encoding="utf-8")
    for p in sorted(Path(__file__).parent.parent.glob("fixtures/*.txt"))
] + [""]

pytestmark = pytest.mark.skipif(
    not (CHECKPOINT / "question").is_dir(), reason="no trained checkpoint yet"
)


def test_questions_and_options_are_exact_substrings_in_text_order():
    tokenizer, taggers = load_tokenizer(CHECKPOINT), load(CHECKPOINT)
    taggers = torch_taggers(tokenizer, taggers)
    for text in FIXTURES:
        found, _ = extract(tokenizer, taggers, text)
        assert [q["range"][0] for q in found] == sorted(q["range"][0] for q in found)
        for q in found:
            start, end = q["range"]
            assert text[start:end] == q["question"]
            for option, (a, b) in zip(q["options"], q["option_ranges"], strict=True):
                assert text[a:b] == option and start <= a and b <= end


def test_invalid_utf8_is_refused(tmp_path, capsys):
    path = tmp_path / "in.txt"
    path.write_bytes(b"\xff\xfe")
    assert main([str(path)]) == 1
    assert "not UTF-8" in capsys.readouterr().err


@pytest.mark.skipif(not (COREML / "settings.json").is_file(), reason="no Core ML model yet")
def test_coreml_output_is_byte_identical_to_torch():
    tokenizer, taggers = load_tokenizer(CHECKPOINT), load(CHECKPOINT)
    torch_side = torch_taggers(tokenizer, taggers)
    coreml_tokenizer, coreml_side = load_coreml(COREML, "cpu")
    for text in FIXTURES:
        wanted = json.dumps(extract(tokenizer, torch_side, text)[0], ensure_ascii=False)
        assert (
            json.dumps(extract(coreml_tokenizer, coreml_side, text)[0], ensure_ascii=False)
            == wanted
        )
