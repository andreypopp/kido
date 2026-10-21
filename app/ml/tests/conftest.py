import re
from datetime import UTC, datetime
from types import SimpleNamespace

from transformers import AutoConfig

from chunks import ids_of, slots
from model import MODEL, REVISION, Tagger

USER = "alice"


def OFF_PEAK() -> datetime:  # noqa: N802
    return datetime(2026, 10, 21, 12, 0, tzinfo=UTC)


def response(content: str, finish: str = "stop", prompt: int = 100, usage: bool = True):
    return SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=content), finish_reason=finish)],
        usage=SimpleNamespace(
            prompt_tokens=prompt,
            completion_tokens=10,
            prompt_cache_hit_tokens=20,
            prompt_cache_miss_tokens=prompt - 20,
            completion_tokens_details=SimpleNamespace(reasoning_tokens=4),
        )
        if usage
        else None,
    )


class FakeClient:
    """Replies are a content string, a (content, finish) pair, an Exception or a response."""

    def __init__(self, replies: list[object]) -> None:
        self.replies = list(replies)
        self.calls: list[dict[str, object]] = []
        self.chat = SimpleNamespace(completions=self)

    def create(self, **kwargs):
        self.calls.append(kwargs)
        item = self.replies.pop(0)
        if isinstance(item, Exception):
            raise item
        if isinstance(item, tuple):
            return response(*item)
        return item if isinstance(item, SimpleNamespace) else response(item)


class WordTokenizer:
    """One token for each word with its leading space, as a byte-level tokenizer gives. The id is
    the word's index plus 10; [CLS] is 1 and [SEP] is 2."""

    cls_token_id, sep_token_id, pad_token_id = 1, 2, 0

    def __call__(
        self,
        text,
        return_offsets_mapping=True,
        add_special_tokens=True,
        truncation=False,
        max_length=None,
    ):
        spans = [m.span() for m in re.finditer(r"\s*\S+", text)]
        if truncation:
            spans = spans[: max_length - 2]
        ids = [10 + n for n in range(len(spans))]
        if add_special_tokens:
            ids, spans = [1, *ids, 2], [(0, 0), *spans, (0, 0)]
        return {"input_ids": ids, "offset_mapping": spans}


class FakeBackend:
    """Tags a token B or I by the word index; the question pass and the option pass share it."""

    def __init__(self, begin: set[int], inside: set[int] = frozenset()) -> None:
        self.begin, self.inside = begin, inside

    def tags(self, task: str, ids: list[int]) -> list[int]:
        return [1 if i - 10 in self.begin else 2 if i - 10 in self.inside else 0 for i in ids]

    def question_tags(self, enc, chunk) -> list[int]:
        tags = self.tags("question", ids_of(enc, chunk))
        return [tags[head] for _, head, _ in slots(enc, chunk)]


def paragraphs(count: int, words: int = 60) -> str:
    return "\n\n".join(" ".join(f"p{p}w{w}" for w in range(words)) for p in range(count))


def tiny(tasks: tuple[str, ...], two_ends: bool = False) -> Tagger:
    config = AutoConfig.from_pretrained(
        MODEL,
        revision=REVISION,
        hidden_size=64,
        intermediate_size=128,
        num_hidden_layers=2,
        num_attention_heads=2,
        layer_types=["full_attention", "sliding_attention"],
    )
    return Tagger(tasks, config, two_ends).eval()


def tiny_two_ends() -> Tagger:
    return tiny(("question",), two_ends=True)
