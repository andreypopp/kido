import itertools
import math

import numpy as np
import torch

from chunks import B, I, O
from crf import Crf, Transitions, viterbi


def random_crf(seed: int) -> Crf:
    torch.manual_seed(seed)
    crf = Crf()
    with torch.no_grad():
        crf.trans.copy_(torch.randn(3, 3))
        crf.start.copy_(torch.randn(3))
    return crf


def allowed(path: tuple[int, ...], inside: bool) -> bool:
    return (inside or path[0] != I) and all(
        not (a == O and b == I) for a, b in itertools.pairwise(path)
    )


def path_score(t: Transitions, e: np.ndarray, path: tuple[int, ...], inside: bool) -> float:
    start = t.start
    score = start[path[0]] + e[0, path[0]]
    for n in range(1, len(path)):
        score += t.trans[path[n - 1], path[n]] + e[n, path[n]]
    return float(score)


def test_nll_matches_brute_force_partition_and_masks_padding() -> None:
    rng = np.random.default_rng(0)
    for seed in range(5):
        crf = random_crf(seed)
        t = crf.transitions()
        lengths, inside = [4, 2, 3, 0], [False, True, False, True]
        emission = rng.normal(size=(4, 4, 3)).astype(np.float32)
        tags = torch.tensor([[O, B, I, I], [I, I, 0, 0], [B, O, O, 0], [0, 0, 0, 0]])
        loss = crf.nll(torch.tensor(emission), tags, torch.tensor(lengths), torch.tensor(inside))
        for n, (count, flag) in enumerate(zip(lengths, inside, strict=True)):
            if not count:
                assert loss[n] == 0
                continue
            paths = [p for p in itertools.product(range(3), repeat=count) if allowed(p, flag)]
            scores = [path_score(t, emission[n, :count], p, flag) for p in paths]
            expected = math.log(sum(math.exp(s) for s in scores)) - path_score(
                t, emission[n, :count], tuple(tags[n, :count].tolist()), flag
            )
            assert abs(float(loss[n].detach()) - expected) < 1e-4


def test_gradients_are_finite_with_forbidden_scores() -> None:
    crf = random_crf(1)
    emission = torch.randn(2, 3, 3, requires_grad=True)
    tags = torch.tensor([[O, B, I], [O, O, 0]])
    crf.nll(emission, tags, torch.tensor([3, 2]), torch.tensor([False, False])).sum().backward()
    assert torch.isfinite(emission.grad).all() and torch.isfinite(crf.trans.grad).all()
    assert crf.trans.grad[O, I] == 0


def test_viterbi_is_the_best_allowed_path_and_never_uses_a_forbidden_move() -> None:
    rng = np.random.default_rng(1)
    for seed in range(40):
        t = random_crf(seed).transitions()
        count, inside = 1 + seed % 5, bool(seed % 2)
        emission = rng.normal(size=(count, 3)).astype(np.float32) * 3
        emission[:, I] += 4  # a strong pull towards the forbidden moves
        best = max(
            (p for p in itertools.product(range(3), repeat=count) if allowed(p, inside)),
            key=lambda p: path_score(t, emission, p, inside),
        )
        got = viterbi(emission, t, inside)
        assert tuple(got) == best and allowed(tuple(got), inside)
    assert viterbi(np.zeros((0, 3), dtype=np.float32), t, False) == []


def test_only_a_chunk_inside_the_text_may_start_with_i() -> None:
    t = Crf().transitions()
    emission = np.array([[0.0, 0.0, 5.0], [0.0, 0.0, 5.0]], dtype=np.float32)
    assert viterbi(emission, t, True) == [I, I]
    assert viterbi(emission, t, False)[0] != I
    assert viterbi(emission, t, False) == [B, I]


def test_transitions_round_trip_through_json_with_null_for_forbidden() -> None:
    t = random_crf(2).transitions()
    data = t.to_json()
    assert data["transitions"][O][I] is None
    assert data["start"][I] is not None
    back = Transitions.from_json(data)
    assert np.array_equal(back.trans, t.trans) and np.array_equal(back.start, t.start)


def test_a_batch_without_slots_has_zero_loss() -> None:
    loss = Crf().nll(
        torch.zeros(2, 0, 3),
        torch.zeros(2, 0, dtype=torch.long),
        torch.zeros(2, dtype=torch.long),
        torch.tensor([False, True]),
    )
    assert loss.tolist() == [0, 0]
