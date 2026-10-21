import io
import json
from pathlib import Path

import pytest
from conftest import OFF_PEAK, FakeClient

from label_cli import main

TEXT = "Pick one?\n- alpha one\n- beta two\n\nAnd which color?\n- red\n- blue\n"
LABEL = {
    "questions": [
        {"first": 1, "last": 3, "words": "Pick one?", "kind": "choice",
         "options": ["beta two", "alpha one"]},
        {"first": 5, "last": 7, "words": "And which color?", "kind": "choice",
         "options": ["red", "blue"]},
    ]
}  # fmt: skip


def run(tmp_path: Path, args: list[str], client=None):
    client = client or FakeClient([json.dumps(LABEL)])
    code = main(
        [*args, str(tmp_path / "in.txt")],
        client=client,
        ledger=tmp_path / "usage.jsonl",
        cache_dir=tmp_path / "cache",
        clock=OFF_PEAK,
    )
    return code, client


def test_the_default_output_has_the_view_the_questions_and_the_cost(tmp_path, capsys) -> None:
    (tmp_path / "in.txt").write_text(TEXT)
    code, client = run(tmp_path, [])
    out, err = capsys.readouterr()
    assert code == 0 and len(client.calls) == 1
    assert out.startswith("1: Pick one?\n2: - alpha one\n")
    found = json.loads(out[out.index("{") :])["questions"]
    assert found[0] == {
        "question": "Pick one?\n- alpha one\n- beta two",
        "options": ["alpha one", "beta two"],
        "kind": "choice",
        "first": 1,
        "last": 3,
    }
    assert found[1]["question"].startswith("And which color?") and found[1]["last"] == 7
    assert "this call $" in err and "ledger $" in err


def test_json_prints_only_the_contract_and_a_repeat_is_cached(tmp_path, capsys) -> None:
    (tmp_path / "in.txt").write_text(TEXT)
    run(tmp_path, ["--json"])
    first = capsys.readouterr().out
    assert [list(q) for q in json.loads(first)["questions"]] == [["question", "options"]] * 2
    code, client = run(tmp_path, ["--json"], FakeClient([]))
    assert code == 0 and client.calls == [] and capsys.readouterr().out == first


def test_raw_shows_the_reply_and_no_cache_calls_again(tmp_path, capsys) -> None:
    (tmp_path / "in.txt").write_text(TEXT)
    run(tmp_path, [])
    capsys.readouterr()
    _, client = run(tmp_path, ["--raw", "--no-cache"])
    assert len(client.calls) == 1 and "--- model reply 1 ---" in capsys.readouterr().err


def test_stdin_is_read_unchanged(tmp_path, capsys, monkeypatch) -> None:
    monkeypatch.setattr("sys.stdin", io.TextIOWrapper(io.BytesIO(TEXT.encode())))
    client = FakeClient([json.dumps(LABEL)])
    code = main(
        ["--json"], client=client, ledger=tmp_path / "u.jsonl", cache_dir=tmp_path / "c",
        clock=OFF_PEAK,
    )  # fmt: skip
    assert code == 0 and "Pick one?" in client.calls[0]["messages"][1]["content"]
    assert len(json.loads(capsys.readouterr().out)["questions"]) == 2


def test_a_missing_key_is_an_error_before_any_call(tmp_path, capsys, monkeypatch) -> None:
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    (tmp_path / "in.txt").write_text(TEXT)
    code = main([str(tmp_path / "in.txt")], ledger=tmp_path / "u.jsonl")
    assert code == 1 and "direnv exec . uv run label" in capsys.readouterr().err


def test_text_that_redaction_would_change_is_refused(tmp_path, capsys) -> None:
    (tmp_path / "in.txt").write_text("Mail me at someone@example.com?\n- yes\n- no\n")
    code, client = run(tmp_path, [])
    assert code == 1 and client.calls == []
    assert "input is not redacted" in capsys.readouterr().err


def test_peak_hours_need_the_flag(tmp_path, capsys) -> None:
    (tmp_path / "in.txt").write_text(TEXT)
    peak = lambda: OFF_PEAK().replace(hour=2)  # noqa: E731
    args = [str(tmp_path / "in.txt")]
    kwargs = {"ledger": tmp_path / "u.jsonl", "cache_dir": tmp_path / "c", "clock": peak}
    refused = FakeClient([])
    assert main(args, client=refused, **kwargs) == 1 and refused.calls == []
    assert "--peak" in capsys.readouterr().err
    allowed = FakeClient([json.dumps(LABEL)])
    assert main(["--peak", *args], client=allowed, **kwargs) == 0 and len(allowed.calls) == 1
    with pytest.raises(SystemExit):
        main(["--bogus"])


def test_effort_and_max_tokens_reach_the_body_and_the_cache_keeps_efforts_apart(
    tmp_path, capsys
) -> None:
    (tmp_path / "in.txt").write_text(TEXT)
    _, plain = run(tmp_path, [])
    assert "reasoning_effort" not in plain.calls[0] and plain.calls[0]["max_tokens"] == 12000
    assert "effort default, reasoning 4 tokens" in capsys.readouterr().err
    _, high = run(tmp_path, ["--effort", "max", "--max-tokens", "20000"])
    assert high.calls[0]["reasoning_effort"] == "max" and high.calls[0]["max_tokens"] == 20000
    assert "effort max, reasoning 4 tokens" in capsys.readouterr().err
    _, again = run(tmp_path, ["--effort", "max", "--max-tokens", "20000"], FakeClient([]))
    assert again.calls == []
    _, low = run(tmp_path, ["--effort", "low"])
    assert low.calls[0]["reasoning_effort"] == "low"
    with pytest.raises(SystemExit):
        main(["--effort", "extreme"])


def test_model_flash_reaches_the_body_the_cache_and_the_ledger(tmp_path, capsys) -> None:
    (tmp_path / "in.txt").write_text(TEXT)
    _, plain = run(tmp_path, [])
    assert plain.calls[0]["model"] == "deepseek-v4-pro"
    assert "model deepseek-v4-pro, prompt" in capsys.readouterr().err
    _, flash = run(tmp_path, ["--model", "flash"])
    assert flash.calls[0]["model"] == "deepseek-flash"
    assert {k: v for k, v in flash.calls[0].items() if k != "model"} == {
        k: v for k, v in plain.calls[0].items() if k != "model"
    }
    assert "model deepseek-flash, prompt" in capsys.readouterr().err
    _, again = run(tmp_path, ["--model", "flash"], FakeClient([]))
    assert again.calls == []
    entries = [json.loads(line) for line in (tmp_path / "usage.jsonl").read_text().splitlines()]
    pro, cheap = [e for e in entries if "cost" in e]
    assert pro["model"] == "deepseek-v4-pro" and cheap["model"] == "deepseek-flash"
    assert pro["cost"] == pytest.approx((20 * 0.022 + 80 * 0.66 + 10 * 1.98) / 1e6)
    assert cheap["cost"] == pytest.approx((20 * 0.003 + 80 * 0.15 + 10 * 0.6) / 1e6)
    with pytest.raises(SystemExit):
        main(["--model", "huge"])
