"""The Ettin encoder with one three-way tagging head for each task, and its checkpoints.

A checkpoint directory holds the weights, the encoder config and the tokenizer, so that loading
needs no hub access. The hub model is pinned to one revision.
"""

from __future__ import annotations

import json
import logging as std_logging
from pathlib import Path

import numpy as np
import torch
from huggingface_hub import logging as hub_logging
from safetensors.torch import load_file, save_file
from torch import nn
from transformers import AutoConfig, AutoModel, AutoTokenizer, logging
from transformers.initialization import no_init_weights

from chunks import decode

std_logging.getLogger("torch.distributed.elastic.multiprocessing.redirects").setLevel(
    std_logging.ERROR
)
hub_logging.set_verbosity_error()
logging.set_verbosity_error()
MODEL = "jhu-clsp/ettin-encoder-32m"
REVISION = "1b8ba06455dd44f80fc9c1ca9e22806157a57379"
TASKS = ("question", "option")
WEIGHTS = "model.safetensors"
SETTINGS = "settings.json"
COMPUTE_UNITS = ("cpu", "gpu", "ane", "all")
DEFAULT_COMPUTE = "gpu"


def device() -> torch.device:
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def checkpoint_dir(path: Path) -> Path:
    """The directory with the files of the first model; a two-model checkpoint has one for
    each task."""
    return path / TASKS[0] if (path / TASKS[0]).is_dir() else path


def load_tokenizer(path: Path | None = None):
    """The tokenizer of a checkpoint, or the pinned hub one."""
    if path is None:
        tokenizer = AutoTokenizer.from_pretrained(MODEL, revision=REVISION)
    else:
        tokenizer = AutoTokenizer.from_pretrained(checkpoint_dir(path))
    tokenizer.model_max_length = 10**9
    return tokenizer


class Tagger(nn.Module):
    def __init__(self, tasks: tuple[str, ...], config=None) -> None:
        """A tagger from the pinned hub weights, or with a given config and random weights."""
        super().__init__()
        if config is None:
            self.encoder = AutoModel.from_pretrained(
                MODEL, revision=REVISION, attn_implementation="sdpa"
            )
        else:
            self.encoder = AutoModel.from_config(config, attn_implementation="sdpa")
        self.heads = nn.ModuleDict(
            {task: nn.Linear(self.encoder.config.hidden_size, 3) for task in tasks}
        )

    def forward(self, ids: torch.Tensor, mask: torch.Tensor, task: str) -> torch.Tensor:
        hidden = self.encoder(input_ids=ids, attention_mask=mask).last_hidden_state
        return self.heads[task](hidden)


def save(model: Tagger, tokenizer, path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    save_file({k: v.contiguous().cpu() for k, v in model.state_dict().items()}, path / WEIGHTS)
    model.encoder.config.save_pretrained(path)
    tokenizer.save_pretrained(path)


def load(path: Path) -> Tagger:
    weights = load_file(path / WEIGHTS)
    tasks = tuple(
        key.split(".")[1] for key in weights if key.startswith("heads.") and key.endswith("weight")
    )
    with no_init_weights():  # the random init costs 1.6 s and the weights replace it
        model = Tagger(tasks, AutoConfig.from_pretrained(path))
    model.load_state_dict(weights)
    return model.eval()


def load_models(path: Path) -> dict[str, Tagger]:
    """A directory with question/ and option/ is two models; else one model for its tasks."""
    if (path / TASKS[0]).is_dir():
        return {task: load(path / task) for task in TASKS}
    model = load(path)
    return dict.fromkeys(model.heads, model)


def load_threshold(path: Path) -> float | None:
    """The B-Q probability threshold stored with a checkpoint; None means the likeliest tag."""
    settings = path / SETTINGS
    return json.loads(settings.read_text()).get("question_threshold") if settings.exists() else None


def save_threshold(path: Path, threshold: float) -> None:
    (path / SETTINGS).write_text(json.dumps({"question_threshold": threshold}) + "\n")


class Backend:
    """A source of logits for the two passes; the question tags use the threshold."""

    def __init__(self, threshold: float | None = None) -> None:
        self.threshold = threshold

    def logits(self, task: str, ids: list[int]) -> np.ndarray:
        raise NotImplementedError

    def tags(self, task: str, ids: list[int]) -> list[int]:
        return decode(self.logits(task, ids), self.threshold if task == "question" else None)


class TorchBackend(Backend):
    def __init__(self, models: dict[str, Tagger], threshold: float | None = None) -> None:
        super().__init__(threshold)
        self.hardware = device()
        self.models = {task: model.to(self.hardware).eval() for task, model in models.items()}

    def logits(self, task: str, ids: list[int]) -> np.ndarray:
        with torch.no_grad():
            tensor = torch.tensor([ids], device=self.hardware)
            return self.models[task](tensor, torch.ones_like(tensor), task)[0].float().cpu().numpy()
