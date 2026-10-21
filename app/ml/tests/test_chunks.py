import random

from conftest import WordTokenizer, paragraphs

from chunks import (
    IGNORE,
    ROOM,
    B,
    I,
    O,
    chunk_from,
    encode,
    labels_of,
    members,
    paragraph_starts,
    plan,
    sample_chunks,
    slots,
    training_starts,
)
from segments import BLANK

TOKENIZER = WordTokenizer()


def test_short_text_is_one_chunk_with_every_segment() -> None:
    enc = encode(TOKENIZER, "Hello there.\n\nWhich one?\n- alpha\n- beta")
    (chunk,) = plan(enc)
    assert (chunk.first, chunk.last, chunk.lo, chunk.hi) == (
        0,
        len(enc.flat.cuts) - 1,
        0,
        len(enc.ids),
    )
    assert chunk.lo == 0 and chunk.hi == len(enc.ids)
    assert [enc.flat.cuts[k].kind for k in members(enc, chunk)].count(BLANK) == 0


def test_plan_covers_the_text_and_cuts_at_paragraphs() -> None:
    enc = encode(TOKENIZER, paragraphs(40))
    chunks = plan(enc)
    assert len(chunks) > 2
    assert chunks[0].first == 0 and chunks[-1].last == len(enc.flat.cuts) - 1
    for before, after in zip(chunks, chunks[1:], strict=False):
        assert after.first <= before.last + 1
        assert enc.flat.cuts[after.first - 1].kind == BLANK
        assert 512 <= enc.begin[after.first] - enc.begin[before.first] <= 768
        assert before.hi < len(enc.ids) and after.lo > 0
    assert all(c.hi - c.lo <= ROOM for c in chunks)


def test_a_segment_longer_than_a_chunk_is_truncated() -> None:
    enc = encode(TOKENIZER, "start\n\n" + " ".join(["word"] * 1500) + "\n\nend")
    chunk = chunk_from(enc, 2)
    assert chunk.hi - chunk.lo == ROOM and chunk.hi < len(enc.ids)
    assert members(enc, chunk) == [2]


def test_labels_cut_at_the_left_keep_the_right() -> None:
    enc = encode(TOKENIZER, "Intro.\n\nWhich one?\n- alpha\n- beta\n\nOther.\n\nLast?")
    gold = [(2, 4), (8, 8)]  # segments: 0 Intro, 1 blank, 2 Which, 3 alpha, 4 beta, 5 blank, ...
    whole = plan(enc)[0]

    def tags(chunk):
        labels = labels_of(enc, chunk, gold)
        return [labels[enc.head[k] - chunk.lo + 1] for k in members(enc, chunk)]

    assert tags(whole) == [O, B, I, I, O, B]
    assert tags(chunk_from(enc, 2)) == [B, I, I, O, B]
    assert tags(chunk_from(enc, 3)) == [O, O, O, B]
    cut = labels_of(enc, whole, gold)
    assert cut[0] == IGNORE and cut[-1] == IGNORE


def test_training_chunks_start_at_paragraphs_or_inside_questions() -> None:
    enc = encode(TOKENIZER, paragraphs(40))
    gold = [(10, 12)]
    rng = random.Random(1)
    starts = {c.first for _ in range(30) for c in sample_chunks(enc, gold, rng)}
    assert starts - set(training_starts(enc)) <= {12}
    assert len(sample_chunks(enc, gold, rng)) == len(plan(enc))
    assert len(sample_chunks(encode(TOKENIZER, "Hi there."), [], rng)) == 1


def test_every_segment_of_a_long_paragraph_is_in_some_training_window() -> None:
    text = "Intro here.\n\n" + " ".join(f"Aaa bbb c{n}." for n in range(500))
    enc = encode(TOKENIZER, text)
    assert len(plan(enc)) > 1

    def covered(starts):
        windows = [chunk_from(enc, s) for s in starts]
        return {k for w in windows for k in range(w.first, w.last + 1)}

    everything = {k for k, c in enumerate(enc.flat.cuts) if c.kind != BLANK}
    assert everything <= covered(training_starts(enc))
    assert not everything <= covered(paragraph_starts(enc.flat.cuts))


def test_slots_clamp_the_last_token_of_a_segment_that_the_chunk_cuts() -> None:
    enc = encode(TOKENIZER, "start\n\n" + " ".join(["word"] * 1500) + "?\n\nend")
    chunk = chunk_from(enc, 2)
    ((k, head, last),) = slots(enc, chunk)
    assert k == 2 and enc.last[2] == len(enc.ids) - 2
    assert head == 1 and last == chunk.hi - chunk.lo
    whole = plan(encode(TOKENIZER, "Which one?\n- a\n- b"))[0]
    assert [(h, e) for _, h, e in slots(encode(TOKENIZER, "Which one?\n- a\n- b"), whole)] == [
        (1, 2),
        (3, 4),
        (5, 6),
    ]
