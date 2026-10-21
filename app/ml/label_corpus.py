"""Label the corpus units: `uv run label-corpus --take question:eval=4 --take pool=2`."""

import argparse
import sys
from collections import Counter

from corpus import (
    SPLITS,
    Row,
    labelling_rows,
    load_units,
    samples,
    uniform_order,
)
from deepseek import CACHE, LEDGER, Ledger, LedgerBusy, Session, open_client
from jsonl import DATA
from label import load_prompt, run
from redact import current_user
from units import category

LABELS = DATA / "labels.jsonl"
CATEGORIES = ("question", "pool", "other")


def take(rows: list[Row], spec: str) -> list[Row]:
    """CATEGORY[:SPLIT]=N|all: the first N units of the category in uniform order, so that a
    larger N holds the smaller one."""
    selector, count = spec.split("=")
    name, _, split = selector.partition(":")
    if name not in CATEGORIES or split and split not in SPLITS:
        raise ValueError(f"{spec}: the category is one of {CATEGORIES}, the split one of {SPLITS}")
    chosen = [r for r in uniform_order(rows) if category(r.text) == name and split in ("", r.split)]
    return chosen if count == "all" else chosen[: int(count)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--take", action="append", required=True, metavar="CATEGORY[:SPLIT]=N")
    parser.add_argument("--limit", type=int, help="at most this many units in all")
    parser.add_argument("--peak", action="store_true", help="allow a call in DeepSeek peak hours")
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args(argv)
    rows, _ = load_units()
    chosen = list(dict.fromkeys(r for spec in args.take for r in take(labelling_rows(rows), spec)))
    chosen = chosen[: args.limit]
    client = open_client()
    if client is None:
        return 1
    try:
        ledger = Ledger(LEDGER)
    except LedgerBusy as error:
        print(f"label-corpus: {error}", file=sys.stderr)
        return 1
    before = ledger.total
    session = Session(client, ledger, CACHE, current_user(), args.peak)
    try:
        counts = run(session, load_prompt(), chosen, LABELS, args.workers)
    finally:
        ledger.close()
    calls = sum(samples(r) for r in chosen)
    print(
        f"label-corpus: {len(chosen)} units, up to {calls} calls, "
        f"{dict(Counter(counts))}, this run ${ledger.total - before:.4f}, "
        f"ledger ${ledger.total:.4f}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
