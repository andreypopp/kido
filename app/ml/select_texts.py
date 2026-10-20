"""Freeze the eval sessions and choose the texts to label, before any labelling.

The session plan and the selection are written once. Both record the digests of the files
they stand on, and `frozen()` checks them before any paid or publishing step.
"""

from __future__ import annotations

import json
import random
import re
import sys

from corpus import (
    MAX_CHARACTERS,
    ROOTS,
    SETTINGS,
    candidates,
    is_multi_candidate,
    is_positive,
)
from jsonl import digest, file_digest, read_json, read_jsonl, write_once
from paths import (
    ASK,
    CANDIDATES,
    NEGATIVES,
    OLD_PLAN,
    PLAN,
    SELECTION,
    labels_path,
    samples_path,
)
from render import ask_sessions
from split import families

EVAL_REAL = 400
EVAL_MULTI = 160
EVAL_NEGATIVE = 300
SAMPLE_HALF = 75
PER_SESSION = 50
SEED = 0
BATCH = 5
TRAIN_NEGATIVES = 3000
UNIFORM_SHARE = 0.2
HARD = re.compile(
    r"\b(or|decide|decision|question|choose|prefer|want me|tell me|let me know|should|confirm"
    r"|approve|still open|which)\b",
    re.IGNORECASE,
)

Record = dict[str, object]


def pick(pool: list[Record], count: int, taken: set[str], used: dict[str, int]) -> list[str]:
    """Up to count ids of the pool, in order, at most PER_SESSION for each session."""
    out: list[str] = []
    for record in pool:
        session, key = str(record["session"]), str(record["id"])
        if len(out) >= count:
            break
        if key in taken or used.get(session, 0) >= PER_SESSION:
            continue
        out.append(key)
        taken.add(key)
        used[session] = used.get(session, 0) + 1
    return out


def choose_eval(pool: list[Record], first: set[str], seed: int) -> list[str] | None:
    """The eval-real ids from the positives of the eval sessions: the ids in first, then
    EVAL_MULTI texts with several question segments, then the rest; None if the pool is short."""
    rng = random.Random(seed)
    own = families(sorted(pool, key=lambda r: str(r["id"])))
    unique = [r for r in pool if own[str(r["id"])] == str(r["id"])]
    rng.shuffle(unique)
    taken: set[str] = set()
    used: dict[str, int] = {}
    chosen = pick([r for r in unique if str(r["id"]) in first], len(first), taken, used)
    several = [r for r in unique if is_multi_candidate(r)]
    several.sort(key=lambda r: int(r["question_paragraphs"]) < 2)  # type: ignore[call-overload]
    chosen += pick(several, EVAL_MULTI - len(chosen), taken, used)
    chosen += pick(unique, EVAL_REAL - len(chosen), taken, used)
    multi = sum(is_multi_candidate(r) for r in unique if str(r["id"]) in set(chosen))
    return chosen if len(chosen) == EVAL_REAL and multi >= EVAL_MULTI else None


def allocate(
    records: list[Record], old_eval: set[str], ask: set[str], smoke: set[str]
) -> tuple[set[str], list[str]]:
    """Eval sessions: every AskUserQuestion session, the sessions of the smoke texts and as
    few random old eval sessions as give EVAL_REAL real texts (EVAL_MULTI with several
    questions) and the negatives. All other sessions are train."""
    by_session: dict[str, list[Record]] = {}
    for record in records:
        by_session.setdefault(str(record["session"]), []).append(record)
    forced = ask | {str(r["session"]) for r in records if str(r["id"]) in smoke}
    rest = sorted(old_eval - forced)
    random.Random(SEED).shuffle(rest)
    chosen = set(forced)
    for taken in range(0, len(rest) + BATCH, BATCH):
        chosen |= set(rest[taken - BATCH : taken] if taken else [])
        pool = [r for s in chosen for r in by_session.get(s, []) if is_positive(r)]
        negatives = sum(not is_positive(r) for s in chosen for r in by_session.get(s, []))
        ids = choose_eval(pool, smoke, SEED)
        if ids is not None and negatives >= EVAL_NEGATIVE + SAMPLE_HALF:
            return chosen, ids
    raise SystemExit("the old eval sessions cannot fill the eval")


def freeze() -> dict[str, object]:
    records = candidates()
    ask = ask_sessions(ROOTS["claude"])
    old_eval = set(read_json(OLD_PLAN)["selected"]["sessions"])  # type: ignore[index]
    smoke = {str(s["id"]) for s in read_jsonl(samples_path("eval-real"))}
    ids = {str(r["id"]) for r in records}
    smoke &= ids
    eval_sessions, eval_real = allocate(records, old_eval, ask, smoke)
    plan = {
        "old_eval": len(old_eval),
        "ask": len(ask),
        "moved_to_train": len(old_eval - eval_sessions),
        "eval_sessions": sorted(eval_sessions),
        "hash": digest(eval_sessions),
    }
    in_eval = [r for r in records if str(r["session"]) in eval_sessions]
    in_train = [r for r in records if str(r["session"]) not in eval_sessions]
    rng = random.Random(SEED)
    eval_negative_pool = [r for r in in_eval if not is_positive(r)]
    eval_negative = [str(r["id"]) for r in rng.sample(eval_negative_pool, EVAL_NEGATIVE)]
    sample = [str(r["id"]) for r in rng.sample(eval_negative_pool, SAMPLE_HALF)]
    sample += [
        str(r["id"]) for r in rng.sample([r for r in in_train if not is_positive(r)], SAMPLE_HALF)
    ]
    first = set(eval_real)
    leading = [r for r in in_eval if str(r["id"]) in first]
    held_out = [r for r in in_eval if str(r["id"]) in set(eval_negative)]
    positives = sorted((r for r in in_train if is_positive(r)), key=lambda r: str(r["id"]))
    family = families(leading + held_out + positives)
    kept = [r for r in positives if family[str(r["id"])] == str(r["id"])]
    copies = sum(
        family[str(r["id"])] in {str(x["id"]) for x in leading + held_out} for r in positives
    )
    train_real = [str(r["id"]) for r in kept if is_multi_candidate(r)]
    train_real += [str(r["id"]) for r in kept if not is_multi_candidate(r)]
    selection: dict[str, object] = {
        "plan": plan["hash"],
        "candidates": file_digest(CANDIDATES),
        "ask": file_digest(ASK),
        "settings": SETTINGS,
        "eval_real": eval_real,
        "eval_negative": eval_negative,
        "negative_sample": sample,
        "train_real": train_real,
        "train_dropped_as_eval_copies": copies,
        "train_dropped_as_train_copies": len(positives) - len(kept) - copies,
    }
    selection["hashes"] = {
        name: digest(selection[name])  # type: ignore[arg-type]
        for name in ("eval_real", "eval_negative", "negative_sample", "train_real")
    }
    write_once(PLAN, plan)
    write_once(SELECTION, selection)
    return {
        "eval_sessions": len(eval_sessions),
        "moved_to_train": plan["moved_to_train"],
        "eval_real": len(eval_real),
        "eval_real_multi": sum(is_multi_candidate(r) for r in leading),
        "eval_real_multi_paragraphs": sum(int(r["question_paragraphs"]) >= 2 for r in leading),  # type: ignore[call-overload]
        "eval_negative": len(eval_negative),
        "negative_sample": len(sample),
        "train_real": len(train_real),
        "train_real_multi": sum(is_multi_candidate(r) for r in kept),
        "max_characters": MAX_CHARACTERS,
        "train_dropped_as_eval_copies": copies,
        "train_dropped_as_train_copies": selection["train_dropped_as_train_copies"],
        "hashes": selection["hashes"],
    }


def freeze_negatives() -> dict[str, object]:
    """The texts without a question mark to label: the eval negatives that the first sample
    found a question in, and the train negatives, the hard pool (decision words) first."""
    plan, selection = frozen()
    records = candidates()
    eval_sessions = set(plan["eval_sessions"])  # type: ignore[call-overload]
    by_id = {str(r["id"]): r for r in records}
    sampled = {str(k["id"]): k for k in read_jsonl(labels_path("negative-sample"))}
    asked = [
        i
        for i in selection["negative_sample"]  # type: ignore[attr-defined]
        if i in sampled
        and sampled[i]["label"]["questions"]  # type: ignore[index]
        and str(by_id[i]["session"]) in eval_sessions
        and i not in selection["eval_negative"]  # type: ignore[operator]
    ]
    held = [by_id[i] for i in [*selection["eval_real"], *selection["eval_negative"], *asked]]  # type: ignore[misc]
    pool = [r for r in records if str(r["session"]) not in eval_sessions and not is_positive(r)]
    family = families(held + sorted(pool, key=lambda r: str(r["id"])))
    pool = [r for r in pool if family[str(r["id"])] == str(r["id"])]
    random.Random(SEED).shuffle(pool)
    done = [str(r["id"]) for r in pool if str(r["id"]) in sampled]
    hard = [r for r in pool if HARD.search(str(r["text"])) and str(r["id"]) not in sampled]
    rest = [r for r in pool if not HARD.search(str(r["text"])) and str(r["id"]) not in sampled]
    quota = int(TRAIN_NEGATIVES * UNIFORM_SHARE)
    hard_take = min(len(hard), TRAIN_NEGATIVES - quota - len(done))
    uniform_take = TRAIN_NEGATIVES - len(done) - hard_take
    train_negative = done + [str(r["id"]) for r in hard[:hard_take] + rest[:uniform_take]]
    chosen = set(train_negative)
    negatives: dict[str, object] = {
        "plan": plan["hash"],
        "selection": digest([*selection["eval_real"], *selection["eval_negative"]]),  # type: ignore[misc]
        "candidates": selection["candidates"],
        "eval_negative_extra": asked,
        "train_negative": train_negative,
        "pools": {
            "sample_done": len(done),
            "hard": sum(str(r["id"]) in chosen for r in hard),
            "uniform": sum(str(r["id"]) in chosen for r in rest),
            "hard_available": len(hard),
            "uniform_available": len(rest),
        },
    }
    write_once(NEGATIVES, negatives)
    return {k: (len(v) if isinstance(v, list) else v) for k, v in negatives.items()}


def frozen_negatives() -> dict[str, object]:
    plan, selection = frozen()
    negatives = read_json(NEGATIVES)
    if negatives["plan"] != plan["hash"] or negatives["candidates"] != selection["candidates"]:
        raise SystemExit("the frozen negatives changed")
    return negatives


def frozen() -> tuple[dict[str, object], dict[str, object]]:
    """(plan, selection), checked against the files they stand on."""
    plan, selection = read_json(PLAN), read_json(SELECTION)
    if (
        selection["plan"] != plan["hash"]
        or digest(plan["eval_sessions"]) != plan["hash"]  # type: ignore[arg-type]
        or selection["candidates"] != file_digest(CANDIDATES)
        or selection["ask"] != file_digest(ASK)
        or selection["settings"] != SETTINGS
    ):
        raise SystemExit("the frozen inputs changed")
    return plan, selection


if __name__ == "__main__":
    print(json.dumps(freeze_negatives() if sys.argv[1:] == ["negatives"] else freeze()))
    sys.exit(0)
