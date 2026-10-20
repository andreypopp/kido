from corpus import digest_of, question_segments, width_of


def test_question_segments_ignore_code_and_tables() -> None:
    assert question_segments("Is it ok? Yes. Why?") == 2
    assert question_segments("```\n$ grep 'why?'\n```\nDone.") == 0
    assert question_segments("┌──┐\n│ a? │\n└──┘") == 0
    assert question_segments("Pick:\n- a?\n- b") == 1


def test_ids_and_widths_depend_on_the_session_and_text_only() -> None:
    assert digest_of("s", "t") == digest_of("s", "t") != digest_of("s2", "t")
    assert 60 <= width_of(digest_of("s", "t")) <= 220


def test_pick_caps_texts_per_session() -> None:
    from select_texts import PER_SESSION, pick

    pool = [{"id": f"i{n}", "session": f"s{n % 2}"} for n in range(400)]
    chosen = pick(pool, 300, set(), {})
    assert len(chosen) == 2 * PER_SESSION
