from datetime import UTC, datetime
from types import SimpleNamespace

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
