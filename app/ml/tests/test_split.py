from split import assign_sessions, deduplicate, normalized


def record(identifier: str, session: str, prompt: str, source: str = "pi") -> dict[str, object]:
    return {
        "id": identifier,
        "session": session,
        "source": source,
        "prompt": prompt,
        "label": {"lines": [], "options": []},
    }


def test_normalized_ignores_markers_and_spacing() -> None:
    assert normalized("> 1:  hello   world\n  2: next") == "hello world\nnext"


def test_exact_and_near_dedup() -> None:
    lines = [f"  1: line {index} with several words in it" for index in range(20)]
    trailing = [f"  {index + 2}: line {index} with several words in it" for index in range(20)]
    base = "\n".join(lines + trailing)
    near = "\n".join(lines + trailing[:-1] + ["  21: one changed line"])
    records = [
        record("a", "s1", base),
        record("b", "s2", base),
        record("c", "s3", near),
        record("d", "s4", "  1: completely different text here"),
    ]
    kept, exact, nearly = deduplicate(records)
    assert [item["id"] for item in kept] == ["a", "d"]
    assert exact == 1
    assert nearly == 1


def test_split_keeps_sessions_together_and_ask_in_eval() -> None:
    records = [
        record(f"a{index}", "same", f"  1: text {index}") for index in range(3)
    ] + [
        record("b", "ask-session", "  1: ask", "ask"),
        record("c", "other", "  1: other"),
    ]
    train, evaluation = assign_sessions(records, 0.34)
    assert sorted(train) == ["a0", "a1", "a2", "c"]
    assert evaluation == ["b"]
