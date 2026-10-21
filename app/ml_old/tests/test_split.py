from split import assign_dev, families, is_multi, option_count


def record(key: str, text: str, session: str = "s", options: int = 0, questions: int = 1):
    label = {"questions": [{"options": ["abc"] * options}] * questions}
    return {"id": key, "text": text, "session": session, "source": "pi", "label": label}


def test_near_copies_join_the_first_family() -> None:
    base = "\n".join(f"line number {n} of the shared text" for n in range(12))
    changed = base + "\nan extra row"
    other = "\n".join(f"different words {n} entirely" for n in range(12))
    found = families([record("a", base), record("b", changed), record("c", other)])
    assert found == {"a": "a", "b": "a", "c": "c"}


def test_dev_takes_whole_sessions_and_stops_at_the_targets() -> None:
    records = [
        record(
            f"r{n}", f"text {n} " * 20 + str(n * 7919), session=f"s{n // 3}", options=1, questions=2
        )
        for n in range(300)
    ]
    dev = assign_dev(records, families(records))
    sessions = {r["session"] for r in records if r["id"] in dev}
    assert all((r["id"] in dev) == (r["session"] in sessions) for r in records)
    chosen = [r for r in records if r["id"] in dev]
    assert sum(option_count(r) for r in chosen) >= 100
    assert sum(is_multi(r) for r in chosen) >= 50
    assert len(chosen) < len(records)


def test_a_family_pulls_its_other_session_into_dev() -> None:
    twin = "\n".join(f"shared row {n} with some words" for n in range(10))
    records = [record("a", twin, "s1", 200, 60), record("b", twin, "s2", 0, 0)]
    records += [record(f"x{n}", f"unique {n} " * 9, f"t{n}", 1, 1) for n in range(20)]
    dev = assign_dev(records, families(records), seed=3)
    assert ("a" in dev) == ("b" in dev)


def numbered(start: int, stop: int) -> str:
    return " ".join(f"w{n}x" for n in range(start, stop))


def test_the_same_prose_at_other_widths_and_layouts_is_one_family() -> None:
    from render import CLAUDE, PI, render_markdown

    prose = "The cache was cold, so I rebuilt the index and ran the tests twice. " * 8
    texts = {
        f"{style.marker!r}-{width}": "\n".join(render_markdown(prose, width, style))
        for style in (PI, CLAUDE)
        for width in (60, 120)
    }
    assert len(set(texts.values())) == 4
    found = families([{"id": k, "text": v} for k, v in texts.items()])
    assert len(set(found.values())) == 1


def test_a_chain_of_near_copies_is_one_family() -> None:
    a, b, c = numbered(0, 300), numbered(20, 320), numbered(40, 340)
    found = families([{"id": k, "text": t} for k, t in (("a", a), ("c", c), ("b", b))])
    assert set(found.values()) == {"a"}


def test_the_first_record_wins_the_family() -> None:
    held, copy = numbered(0, 60), numbered(0, 60)
    found = families([{"id": "eval", "text": held}, {"id": "train", "text": copy}])
    assert found == {"eval": "eval", "train": "eval"}


def test_dev_never_takes_more_than_a_fifth() -> None:
    records = [
        record(f"r{n}", f"unique text {n} " * 8, f"s{n}", options=5, questions=2)
        for n in range(100)
    ]
    dev = assign_dev(records, families(records))
    assert 0 < len(dev) <= 20


def test_a_pair_just_above_the_threshold_is_found_by_exact_similarity() -> None:
    from split import shingles, words_of

    first, second = numbered(0, 260), numbered(25, 285)
    a, b = shingles(words_of(first)), shingles(words_of(second))
    assert 0.8 <= len(a & b) / len(a | b) < 0.85
    found = families([{"id": "a", "text": first}, {"id": "b", "text": second}])
    assert found == {"a": "a", "b": "a"}
    far = numbered(60, 320)
    assert families([{"id": "a", "text": first}, {"id": "c", "text": far}])["c"] == "c"
