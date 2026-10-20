"""Shared model identity, checkpoint selection and device selection."""

from __future__ import annotations

import json
from pathlib import Path

MODEL = "jhu-clsp/ettin-encoder-32m"
PACKAGE = Path("data/output/ParagraphTagger.mlpackage")
FUNCTIONS = Path("data/output/ParagraphTagger-functions")


def device():
    import torch

    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def chosen_checkpoint() -> Path:
    experiment = json.loads(Path("data/experiment.json").read_text())
    chosen = experiment["chosen"]
    return Path("data/output") / f"phase2-{chosen['variant']}-s{chosen['seed']}"
