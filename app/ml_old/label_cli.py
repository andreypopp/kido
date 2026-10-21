"""Label one text with one DeepSeek call: `uv run label [FILE]`."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
import tempfile
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

from openai import OpenAI

from deepseek import (
    MAX_TOKENS,
    MODELS,
    BudgetExceeded,
    LedgerBusy,
    PeakHours,
    Spend,
    now,
    usage_of,
)
from extract import contract, read_input
from paths import DATA, LEDGER, OLD_LEDGER
from questions import PROMPT_HASH, label_text, ordered_options, questions_of, view

CLI_CACHE = DATA / "cache" / "label-cli"


class Recorder:
    """Keeps what the model said, to show it under --raw."""

    def __init__(self, client: OpenAI) -> None:
        self.client = client
        self.replies: list[str] = []
        self.reasoning = 0
        self.chat = self

    @property
    def completions(self) -> Recorder:
        return self

    def create(self, **kwargs):
        response = self.client.chat.completions.create(**kwargs)
        self.replies.append(response.choices[0].message.content or "")
        self.reasoning += usage_of(getattr(response, "usage", None), False).reasoning_tokens
        return response


def main(
    argv: list[str] | None = None,
    *,
    client: OpenAI | None = None,
    ledger: Path = LEDGER,
    cache_dir: Path = CLI_CACHE,
    clock: Callable[[], datetime] = now,
) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", type=Path, help="plain text; stdin if absent")
    parser.add_argument("--json", action="store_true", help="only the questions, as JSON")
    parser.add_argument("--raw", action="store_true", help="also the model replies (not cached)")
    parser.add_argument("--no-cache", action="store_true", help="always make a fresh call")
    parser.add_argument("--peak", action="store_true", help="allow a call in DeepSeek peak hours")
    parser.add_argument("--effort", choices=["low", "high", "max"], help="reasoning effort")
    parser.add_argument("--model", choices=MODELS, default="pro", help="DeepSeek model")
    parser.add_argument("--max-tokens", type=int, default=MAX_TOKENS, help="output token limit")
    args = parser.parse_args(argv)
    try:
        text = read_input(args.file)
    except ValueError as error:
        print(f"label: {error}", file=sys.stderr)
        return 1
    if client is None:
        key = os.environ.get("DEEPSEEK_API_KEY", "")
        if not key:
            print(
                "label: DEEPSEEK_API_KEY is not set; run with `direnv exec . uv run label` "
                "or export it",
                file=sys.stderr,
            )
            return 1
        client = OpenAI(
            api_key=key, base_url="https://api.deepseek.com", max_retries=0, timeout=900
        )
    recorder = Recorder(client)
    try:
        spend = Spend(ledger, earlier=[OLD_LEDGER])
    except LedgerBusy as error:
        print(f"label: {error}", file=sys.stderr)
        return 1
    before = spend.total
    fresh = tempfile.TemporaryDirectory()
    try:
        result = label_text(
            recorder,  # type: ignore[arg-type]
            text,
            spend=spend,
            cache_dir=Path(fresh.name) if args.no_cache else cache_dir,
            stage="label-cli",
            user=getpass.getuser(),
            clock=clock,
            allow_peak=args.peak,
            max_tokens=args.max_tokens,
            effort=args.effort,
            model=MODELS[args.model],
        )
    except PeakHours:
        print("label: DeepSeek peak hours; pass --peak to call anyway", file=sys.stderr)
        return 1
    except BudgetExceeded:
        print("label: the budget is spent", file=sys.stderr)
        return 1
    finally:
        spend.close()
        fresh.cleanup()
    if args.raw:
        for number, reply in enumerate(recorder.replies, 1):
            print(f"--- model reply {number} ---\n{reply}", file=sys.stderr)
    if "label" not in result:
        print(f"label: no valid label: {'; '.join(map(str, result['errors']))}", file=sys.stderr)  # type: ignore[arg-type]
        return 1
    label = ordered_options(text, result["label"])  # type: ignore[arg-type]
    found = questions_of(text, label)
    out = contract(text, [(q.start, q.end, q.options) for q in found])
    if not args.json:
        print(view(text))
        for item, q in zip(out["questions"], found, strict=True):  # type: ignore[arg-type]
            item |= {"kind": q.kind, "first": q.first + 1, "last": q.last + 1}
    print(json.dumps(out, ensure_ascii=False, indent=None if args.json else 2))
    if not args.json:
        print(
            f"label: model {MODELS[args.model]}, prompt {PROMPT_HASH}, "
            f"effort {args.effort or 'default'}, "
            f"reasoning {recorder.reasoning} tokens, this call ${spend.total - before:.4f}, "
            f"ledger ${spend.total:.4f}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
