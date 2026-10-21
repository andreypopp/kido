from conftest import WordTokenizer

from chunks import encode
from examples import make_item
from extract import options
from flat import flatten, question_body
from model import load_tokenizer
from questions import question_item

TOKENIZER = WordTokenizer()


def test_paragraphs_join_with_a_blank_line_and_segments_with_one_space() -> None:
    text = "  First  line\n  wraps here. Second one?\n\n\n- Item   one\n- Item two\n\nEnd."
    flat = flatten(text)
    assert flat.text == "First line wraps here. Second one?\n\n- Item one - Item two\n\nEnd."


def test_markers_are_normalised_and_the_case_is_kept() -> None:
    text = (
        "Pick:\n* Alpha\n• Beta\n+ Gamma\n\n1) One\n12. Two\n(3) Three\na. Four\nB) Five\n\n- Six"
    )
    flat = flatten(text)
    two = flat.text.index("1. Two")
    assert text[flat.origin[two + 1]] == "." and text[flat.origin[two]] == "1"
    assert (
        flat.text
        == "Pick: - Alpha - Beta - Gamma\n\n1. One 1. Two (3) Three 1. Four 1. Five\n\n- Six"
    )


def test_each_flat_character_maps_to_the_same_character_of_the_text() -> None:
    text = "⏺ Which one\n  do you want?\n\n  1. alpha\n  2. beta\n"
    flat = flatten(text)
    for n, o in enumerate(flat.origin):
        assert flat.text[n] == " " or flat.text[n] == text[o] or text[o].isdigit()
    assert flat.origin == sorted(flat.origin)


def test_an_option_on_a_row_break_snaps_to_its_own_characters() -> None:
    text = "Should I update\n  the docs or keep\n  the change?"
    flat = flatten(text)
    assert flat.text == "Should I update the docs or keep the change?"

    class Tags:
        def __init__(self, spans):
            self.spans = spans

        def tags(self, task, ids):
            out = [0] * len(ids)
            for a, b in self.spans:
                out[a] = 1
                for n in range(a + 1, b):
                    out[n] = 2
            return out

    # token 0 is [CLS]; 3 update 4 the 5 docs 6 or 7 keep 8 the 9 change?
    got = options(TOKENIZER, Tags([(3, 6), (7, 10)]), text, flat, 0, len(text))
    assert got == ("update\n  the docs", "keep\n  the change?")
    spaced = "Should I update the \n\n docs or keep?"
    padded = options(TOKENIZER, Tags([(4, 6)]), spaced, flatten(spaced), 0, 30)
    assert padded == ("the \n\n docs",)


def test_a_gutter_row_collapses_and_a_span_never_starts_or_ends_on_space() -> None:
    text = "⏺ Which one\n  do you want?\n  - alpha\n  - beta"
    flat = flatten(text)
    assert flat.text == "Which one do you want? - alpha - beta"
    body, shift = question_body(flat, 2, len(text))
    assert body == flat.text and shift == 0
    cuts = flat.cuts
    assert text[flat.origin[flat.ranges[1][0]] :].startswith("- alpha")
    assert flat.ranges[0] == (0, len("Which one do you want?")) and cuts[0].start == 2


def test_option_labels_follow_the_flat_tokens() -> None:
    text = "Which one?\n  1. the first\n     one\n  2. other"
    item = make_item(
        TOKENIZER,
        {
            "text": text,
            "label": {
                "questions": [question_item(text, 1, 3, "choice", ["the first\n     one", "other"])]
            },
        },
    )
    (example,) = item.options
    words = flatten(text).text.split()
    tagged = list(zip(words, example["labels"][1:-1], strict=True))
    assert tagged == [
        ("Which", 0), ("one?", 0), ("1.", 0), ("the", 1), ("first", 2), ("one", 2),
        ("1.", 0), ("other", 1),
    ]  # fmt: skip


def test_the_first_token_of_a_segment_starts_with_the_segments_own_text() -> None:
    tokenizer = load_tokenizer()
    text = (
        "Which one? Pick one.\n- Alpha, beta?\n- Gamma?\n1. First\n2) Second.\n\n"
        'Unmarked after space? Yes. (Maybe) "quoted"? ...dots\n\n- Last'
    )
    enc = encode(tokenizer, text)
    out = tokenizer(enc.flat.text, return_offsets_mapping=True, add_special_tokens=False)
    for k, (first, stop) in enumerate(enc.flat.ranges):
        if enc.flat.cuts[k].kind == "blank":
            continue
        a, b = out["offset_mapping"][enc.head[k]]
        assert a in (first, first - 1) and b > first, (k, enc.flat.text[first:stop], a, b)
        assert enc.flat.text[max(a, first) : b].strip() != "" and enc.flat.text[
            a:b
        ].lstrip().startswith(enc.flat.text[first])
        assert out["offset_mapping"][enc.last[k]][1] == stop
