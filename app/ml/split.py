"""Near-duplicate families, independent of the render width, and the dev split."""

from __future__ import annotations

import random

from datasketch import MinHash, MinHashLSH

from segments import CLAUDE_MARKER

NEAR_THRESHOLD = 0.8
RECALL_THRESHOLD = 0.5
PERMUTATIONS = 128
SHINGLE = 4
DEV_OPTIONS = 100
DEV_MULTI = 50
DEV_SHARE = 0.2


def words_of(text: str) -> list[str]:
    """The text without the turn marker and without row breaks or indents."""
    return text.replace(CLAUDE_MARKER, " ").split()


def shingles(words: list[str]) -> set[str]:
    if len(words) <= SHINGLE:
        return {" ".join(words)}
    return {" ".join(words[i : i + SHINGLE]) for i in range(len(words) - SHINGLE + 1)}


def sketch(words: list[str]) -> MinHash:
    value = MinHash(num_perm=PERMUTATIONS)
    for shingle in shingles(words):
        value.update(shingle.encode())
    return value


class UnionFind:
    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, value: str) -> str:
        self.parent.setdefault(value, value)
        while self.parent[value] != value:
            self.parent[value] = self.parent[self.parent[value]]
            value = self.parent[value]
        return value

    def union(self, left: str, right: str) -> None:
        self.parent[self.find(right)] = self.find(left)


def families(records: list[dict[str, object]]) -> dict[str, str]:
    """Map each record id to the id of the first record, in list order, of its family. A family
    is closed under near-duplicate links (exact word-shingle Jaccard of 0.8 or more; MinHash
    only finds the candidates) (a chain of matches is one family) and ignores the
    width and layout. Put the records that must win, such as the eval texts, first."""
    lsh = MinHashLSH(threshold=RECALL_THRESHOLD, num_perm=PERMUTATIONS)
    shingled: dict[str, set[str]] = {}
    union = UnionFind()
    exact: dict[str, str] = {}
    order: dict[str, int] = {}
    for position, record in enumerate(records):
        key = str(record["id"])
        order[key] = position
        union.find(key)
        words = words_of(str(record["text"]))
        same = exact.setdefault(" ".join(words), key)
        union.union(same, key)
        value, mine = sketch(words), shingles(words)
        for match in lsh.query(value):
            other = shingled[match]
            if len(mine & other) >= NEAR_THRESHOLD * len(mine | other):
                union.union(match, key)
        lsh.insert(key, value)
        shingled[key] = mine
    first: dict[str, str] = {}
    for key in order:
        root = union.find(key)
        if root not in first or order[key] < order[first[root]]:
            first[root] = key
    return {key: first[union.find(key)] for key in order}


def is_synthetic(record: dict[str, object]) -> bool:
    return record.get("source") == "synthetic"


def option_count(record: dict[str, object]) -> int:
    return sum(len(q["options"]) for q in record["label"]["questions"])  # type: ignore[index]


def is_multi(record: dict[str, object]) -> bool:
    return len(record["label"]["questions"]) >= 2  # type: ignore[index]


def assign_dev(records: list[dict[str, object]], family: dict[str, str], seed: int = 0) -> set[str]:
    """Ids of the dev records among real records: whole components of sessions and families,
    taken in random order until DEV_OPTIONS option spans and DEV_MULTI multi-question texts
    are in, and never more than DEV_SHARE of the records."""
    union = UnionFind()
    for record in records:
        key = str(record["id"])
        union.union("family:" + family[key], "id:" + key)
        union.union("session:" + str(record["session"]), "id:" + key)
    components: dict[str, list[dict[str, object]]] = {}
    for record in records:
        components.setdefault(union.find("id:" + str(record["id"])), []).append(record)
    roots = sorted(components)
    random.Random(seed).shuffle(roots)
    room = int(len(records) * DEV_SHARE)
    options = multi = 0
    dev: set[str] = set()
    for root in roots:
        if options >= DEV_OPTIONS and multi >= DEV_MULTI:
            break
        members = components[root]
        if len(dev) + len(members) > room:
            continue
        for record in members:
            dev.add(str(record["id"]))
            options += option_count(record)
            multi += is_multi(record)
    return dev
