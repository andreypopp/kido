import json

from render import prompt_lines
from split import (
    Deduper,
    assign_dev,
    balance,
    extra_variants,
    family_set,
    select_eval,
)


def record(
    identifier: str,
    session: str,
    prompt: str,
    *,
    context_id: str | None = None,
    source: str = "pi",
    options: int = 0,
    question: bool = False,
) -> dict[str, object]:
    lines = prompt.splitlines()
    classes = ["other"] * len(lines)
    if question:
        classes[-1] = "question"
    return {
        "id": identifier,
        "session": session,
        "source": source,
        "context_id": context_id or identifier,
        "prompt": prompt,
        "lines": prompt_lines(prompt),
        "label": {"lines": classes, "options": [{"line": 1, "text": "x"}] * options},
        "ranges": [[0, 0]],
        "hovered": 0,
    }


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
    kept, exact, nearly, _ = Deduper().keep(records)
    assert [item["id"] for item in kept] == ["a", "d"]
    assert exact == 1
    assert nearly == 1


def test_hover_variants_survive_exact_dedup() -> None:
    first = "> 1: line 0 with several words\n  2: line 1 with several words"
    second = "  1: line 0 with several words\n> 2: line 1 with several words"
    records = [
        record("a1", "s1", first, context_id="family"),
        record("a2", "s1", second, context_id="family"),
        record("a1-again", "s2", first, context_id="other"),
    ]
    kept, exact, _, _ = Deduper(near=False).keep(records)
    assert sorted(item["id"] for item in kept) == ["a1", "a2"]
    assert exact == 1


def test_near_duplicates_block_train_against_eval() -> None:
    base = "\n".join(
        f"{'>' if index == 0 else ' '} {index + 1}: shared line {index} with words"
        for index in range(20)
    )
    other = base.replace("> 1:", "  1:").replace("  2:", "> 2:")
    deduper = Deduper()
    evaluation, _, _, _ = deduper.keep(
        [record("e", "eval", base, source="real", context_id="family")]
    )
    train, _, _, _ = deduper.keep(
        [record("t", "train", other, context_id="family")], block=True
    )
    assert len(evaluation) == 1
    assert train == []


def test_select_eval_uses_distinct_families_and_many_sessions() -> None:
    records = []
    for index in range(400):
        session = f"q{index // 5}"
        records.append(
            record(
                f"q{index}",
                session,
                f"> 1: question {index}?",
                context_id=f"qf{index}",
                question=True,
            )
        )
    for index in range(300):
        session = f"n{index // 5}"
        records.append(
            record(
                f"n{index}",
                session,
                f"  1: plain prose {index}",
                context_id=f"nf{index}",
            )
        )
    chosen, sessions, families = select_eval(records)
    assert len(chosen) == 600
    assert len(sessions) >= 100
    question = {
        family for family in chosen if any("?" in r["prompt"] for r in families[family])
    }
    assert len(question) == 300
    train = set(families) - chosen
    assert chosen.isdisjoint(train)


def test_extra_variants_covers_every_paragraph() -> None:
    prompt = "  1: first\n  2: \n> 3: second\n  4: \n  5: third"
    base = record("base", "s", prompt, context_id="family")
    base["ranges"] = [[0, 0], [2, 2], [4, 4]]
    base["hovered"] = 1
    base["lines"] = prompt_lines(prompt)
    expanded = extra_variants([base])
    assert len(expanded) == 3
    assert [item["hovered"] for item in expanded] == [0, 1, 2]


def test_dev_is_a_union_of_sessions_and_families() -> None:
    records = [
        record(
            f"r{index}",
            f"s{index // 4}",
            f"  1: text {index}",
            context_id=f"f{index}",
            options=3,
        )
        for index in range(80)
    ]
    train, dev, meta = assign_dev(records, fraction=0.2, target_spans=12)
    assert meta["option_spans"] >= 12
    assert family_set(dev).isdisjoint(family_set(train))
    assert {item["session"] for item in dev}.isdisjoint(
        {item["session"] for item in train}
    )


def test_balance_keeps_negatives_at_least_half() -> None:
    records = [
        record(
            f"p{index}",
            f"ps{index}",
            f"> 1: question {index}?",
            context_id=f"pf{index}",
            question=True,
        )
        for index in range(3)
    ] + [record("n", "ns", "  1: plain prose", context_id="nf")]
    kept, dropped = balance(records)
    assert sum(1 for item in kept if item["id"].startswith("p")) == 1
    assert dropped == 2
    assert json.dumps(kept)
