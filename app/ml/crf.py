"""A linear-chain CRF over the tagged segments of a chunk. O to I is forbidden, and I cannot
start a chunk that starts at the text start (lo = 0)."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import torch
from torch import nn

from chunks import I, O

TAGS = 3
FORBIDDEN = torch.zeros(TAGS, TAGS, dtype=torch.bool)
FORBIDDEN[O, I] = True


@dataclass(frozen=True)
class Transitions:
    trans: np.ndarray  # [from][to], -inf where forbidden (null in settings.json)
    start: np.ndarray  # scores of the first tag; the I of a chunk with lo = 0 is -inf

    def to_json(self) -> dict[str, list]:
        def nulls(a: np.ndarray) -> list:
            return [None if x == -np.inf else float(x) for x in a.ravel()]

        return {
            "transitions": [nulls(row) for row in self.trans],
            "start": nulls(self.start),
        }

    @staticmethod
    def from_json(data: dict[str, list]) -> Transitions:
        def array(values: list) -> np.ndarray:
            return np.array([-np.inf if x is None else x for x in values], dtype=np.float32)

        return Transitions(
            np.stack([array(row) for row in data["transitions"]]),
            array(data["start"]),
        )


class Crf(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.trans = nn.Parameter(torch.zeros(TAGS, TAGS))
        self.start = nn.Parameter(torch.zeros(TAGS))

    def transitions(self) -> Transitions:
        trans = self.trans.masked_fill(FORBIDDEN.to(self.trans.device), -torch.inf)
        return Transitions(trans.detach().cpu().numpy(), self.start.detach().cpu().numpy())

    def nll(
        self,
        emission: torch.Tensor,
        tags: torch.Tensor,
        lengths: torch.Tensor,
        inside: torch.Tensor,
    ) -> torch.Tensor:
        """NLL per example: emission (b, slots, 3), tags (b, slots), lengths and inside (b,)."""
        trans = self.trans.masked_fill(FORBIDDEN.to(self.trans.device), -torch.inf)
        no_i = torch.arange(TAGS, device=tags.device) == I
        start = torch.where(inside[:, None] | ~no_i, self.start, -torch.inf)
        if emission.shape[1] == 0:
            return emission.new_zeros(len(tags))
        rows = torch.arange(len(tags), device=tags.device)
        steps = emission.shape[1]
        alpha = start + emission[:, 0]
        gold = start[rows, tags[:, 0]] + emission[rows, 0, tags[:, 0]]
        for t in range(1, steps):
            live = t < lengths
            step = trans[tags[:, t - 1], tags[:, t]] + emission[rows, t, tags[:, t]]
            gold = gold + torch.where(live, step, torch.zeros_like(step))
            moved = torch.logsumexp(alpha[:, :, None] + trans, dim=1) + emission[:, t]
            alpha = torch.where(live[:, None], moved, alpha)
        loss = torch.logsumexp(alpha, dim=1) - gold
        return torch.where(lengths > 0, loss, torch.zeros_like(loss))


def viterbi(emission: np.ndarray, transitions: Transitions, inside: bool) -> list[int]:
    """The best tag path; emission is (slots, 3)."""
    if not len(emission):
        return []
    start = transitions.start
    if not inside:
        start = np.where(np.arange(TAGS) == I, -np.inf, start)
    score = start + emission[0]
    back = []
    for row in emission[1:]:
        moved = score[:, None] + transitions.trans
        back.append(moved.argmax(0))
        score = moved.max(0) + row
    path = [int(score.argmax())]
    for choice in reversed(back):
        path.append(int(choice[path[-1]]))
    return path[::-1]
