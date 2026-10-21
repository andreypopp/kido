"""Run the converted models of a directory made by `convert`: no compiling at start."""

import logging
from functools import cache, partial
from pathlib import Path

import numpy as np
from transformers import AutoTokenizer

from jsonl import DATA, read_json
from tagging import Span, encode, spans_of

logging.getLogger("coremltools").setLevel(logging.ERROR)

import coremltools as ct  # noqa: E402
from coremltools.models import CompiledMLModel  # noqa: E402

COREML = DATA / "coreml"
COMPUTE = {
    "cpu": ct.ComputeUnit.CPU_ONLY,
    "gpu": ct.ComputeUnit.CPU_AND_GPU,
    "all": ct.ComputeUnit.ALL,
}


def predict(
    tokenizer, model_of, shapes: list[int], pad: int, texts: list[str], trailing: str = ""
) -> list[list[Span]]:
    """The tagged character spans of each text. The smallest shape that holds the tokens of a
    text runs it."""
    out = []
    for text in texts:
        ids, offsets = encode(tokenizer, text)
        shape = next(s for s in shapes if len(ids) <= s)
        padded = np.full((1, shape), pad, dtype=np.int32)
        padded[0, : len(ids)] = ids
        mask = np.zeros((1, shape), dtype=np.int32)
        mask[0, : len(ids)] = 1
        logits = model_of(shape).predict({"input_ids": padded, "attention_mask": mask})["logits"]
        tags = np.asarray(logits)[0, : len(ids)].argmax(-1).tolist()
        out.append(spans_of(text, offsets, tags, trailing))
    return out


def load_coreml(directory: Path, compute: str):
    """The tokenizer and the taggers of the directory; a function loads when it first runs."""
    settings = read_json(directory / "settings.json")
    tokenizer = AutoTokenizer.from_pretrained(directory)
    taggers = {}
    for task, shapes in settings["shapes"].items():

        @cache
        def model_of(shape: int, task: str = task) -> CompiledMLModel:
            return CompiledMLModel(
                str(directory / f"{task}.mlmodelc"),
                compute_units=COMPUTE[compute],
                function_name=f"shape_{shape}",
            )

        taggers[task] = partial(
            predict, tokenizer, model_of, sorted(shapes), settings["pad_token_id"]
        )
    return tokenizer, taggers
