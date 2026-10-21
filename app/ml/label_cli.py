"""Label one text with one DeepSeek call for each unit: `uv run label [FILE]`."""

import argparse
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from corpus import has_letters
from deepseek import (
    CACHE,
    LEDGER,
    BudgetExceeded,
    Ledger,
    LedgerBusy,
    PeakHours,
    Session,
    open_client,
)
from label import Dropped, label_unit, load_prompt
from normalise import normalise
from redact import current_user, redact
from units import units

WORKERS = 8


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", type=Path, help="UTF-8 text; stdin if absent")
    parser.add_argument("--no-cache", action="store_true", help="always make a fresh call")
    parser.add_argument("--peak", action="store_true", help="allow a call in DeepSeek peak hours")
    args = parser.parse_args(argv)
    text = args.file.read_text(encoding="utf-8") if args.file else sys.stdin.read()
    client = open_client()
    if client is None:
        return 1
    try:
        spend = Ledger(LEDGER)
    except LedgerBusy as error:
        print(f"label: {error}", file=sys.stderr)
        return 1
    before = spend.total
    fresh = tempfile.TemporaryDirectory()
    user = current_user()
    directory = Path(fresh.name) if args.no_cache else CACHE
    session = Session(client, spend, directory, user, args.peak)
    prompt = load_prompt()
    lines = [redact(u.text, user=user) for u in units(normalise(text, screen=True))]
    lines = [line for line in lines if has_letters(line)]
    code = 0
    try:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for line, (result, _) in zip(
                lines,
                pool.map(lambda line: label_unit(session, prompt, line, "sample0"), lines),
                strict=True,
            ):
                print(line)
                if isinstance(result, Dropped):
                    print(f"  dropped: {result.reason}")
                for q in [] if isinstance(result, Dropped) else result:
                    print(f"  [{q.kind}] {q.question}")
                    for option in q.options:
                        print(f"    - {option}")
    except PeakHours:
        print("label: DeepSeek peak hours; pass --peak to call anyway", file=sys.stderr)
        code = 1
    except BudgetExceeded:
        print("label: the budget is spent", file=sys.stderr)
        code = 1
    finally:
        spend.close()
        fresh.cleanup()
    print(
        f"label: prompt {prompt.digest}, this run ${spend.total - before:.4f}, "
        f"ledger ${spend.total:.4f}",
        file=sys.stderr,
    )
    return code


if __name__ == "__main__":
    sys.exit(main())
