"""Shared model identity and device selection."""

from __future__ import annotations

import torch

MODEL = "jhu-clsp/ettin-encoder-32m"


def device() -> torch.device:
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")
