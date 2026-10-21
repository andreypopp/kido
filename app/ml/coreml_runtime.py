"""Run the converted models from one directory: the compiled models, the tokenizer and
settings.json, which holds the function shapes, the pad id and the question threshold.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

import numpy as np

# coremltools warns on import that it has not been tested with the installed torch
logging.getLogger("coremltools").setLevel(logging.ERROR)

import coremltools as ct  # noqa: E402
from coremltools.models import CompiledMLModel  # noqa: E402

from model import SETTINGS, Backend  # noqa: E402

UNITS = {"cpu": "CPU_ONLY", "gpu": "CPU_AND_GPU", "ane": "CPU_AND_NE", "all": "ALL"}


class CoreMLBackend(Backend):
    def __init__(self, directory: Path, compute: str) -> None:
        settings = json.loads((directory / SETTINGS).read_text())
        super().__init__(settings.get("question_threshold"))
        self.directory, self.compute = directory, compute
        self.shapes: dict[str, list[int]] = settings["shapes"]
        self.pad_id: int = settings["pad_token_id"]
        self.models: dict[tuple[str, int], CompiledMLModel] = {}

    def model(self, task: str, shape: int) -> CompiledMLModel:
        if (task, shape) not in self.models:
            self.models[task, shape] = CompiledMLModel(
                str(self.directory / f"{task}.mlmodelc"),
                compute_units=getattr(ct.ComputeUnit, UNITS[self.compute]),
                function_name=f"shape_{shape}",
            )
        return self.models[task, shape]

    def logits(self, task: str, ids: list[int]) -> np.ndarray:
        shape = next(s for s in self.shapes[task] if len(ids) <= s)
        padded = np.full((1, shape), self.pad_id, dtype=np.int32)
        padded[0, : len(ids)] = ids
        mask = np.zeros((1, shape), dtype=np.int32)
        mask[0, : len(ids)] = 1
        output = self.model(task, shape).predict({"input_ids": padded, "attention_mask": mask})
        return np.asarray(output["logits"])[0, : len(ids)].astype(np.float32)
