"""The Ettin encoder as a BIO token tagger: the question model and the option model."""

import logging as std_logging
from functools import partial
from pathlib import Path

import torch
from huggingface_hub import logging as hub_logging
from transformers import AutoModelForTokenClassification, AutoTokenizer, logging

from jsonl import DATA
from tagging import Span, encode, spans_of

logging.set_verbosity_error()
logging.disable_progress_bar()
hub_logging.set_verbosity_error()
std_logging.getLogger("torch.distributed.elastic.multiprocessing.redirects").setLevel(
    std_logging.ERROR
)
MODEL = "jhu-clsp/ettin-encoder-32m"
REVISION = "1b8ba06455dd44f80fc9c1ca9e22806157a57379"
TASKS = ("question", "option")
CHECKPOINT = DATA / "model" / "selected"
BATCH = 32
CPU_TOKENS = 5000  # measured: the GPU costs 100 ms to start and saves 20 ms per 1000 tokens


def device() -> torch.device:
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def pretrained(loader, source, **options):
    """The cached files; the hub only when they are not cached yet."""
    try:
        return loader.from_pretrained(source, local_files_only=True, **options)
    except OSError:
        return loader.from_pretrained(source, **options)


def load_tokenizer(path: Path | None = None):
    if path is None:
        return pretrained(AutoTokenizer, MODEL, revision=REVISION)
    return AutoTokenizer.from_pretrained(path / TASKS[0])


def new_model():
    return pretrained(AutoModelForTokenClassification, MODEL, revision=REVISION, num_labels=3)


def save(taggers: dict, tokenizer, path: Path) -> None:
    for task, model in taggers.items():
        model.save_pretrained(path / task)
        tokenizer.save_pretrained(path / task)


def load(path: Path) -> dict:
    return {
        task: AutoModelForTokenClassification.from_pretrained(path / task).eval() for task in TASKS
    }


def batch_tensors(tokenizer, ids: list[list[int]], hardware, labels=None) -> dict:
    """Padded input_ids and attention_mask, and padded labels when given."""
    width = max(map(len, ids))
    batch = {
        "input_ids": [i + [tokenizer.pad_token_id] * (width - len(i)) for i in ids],
        "attention_mask": [[1] * len(i) + [0] * (width - len(i)) for i in ids],
    }
    if labels is not None:
        batch["labels"] = [t + [-100] * (width - len(t)) for t in labels]
    return {key: torch.tensor(value, device=hardware) for key, value in batch.items()}


def torch_taggers(tokenizer, models: dict) -> dict:
    """For each task, a function from texts (and trailing characters to cut) to their spans."""
    return {task: partial(predict, tokenizer, model) for task, model in models.items()}


def predict(tokenizer, model, texts: list[str], trailing: str = "") -> list[list[Span]]:
    """The tagged character spans of each text."""
    encoded = [encode(tokenizer, text) for text in texts]
    hardware = torch.device("cpu")
    if sum(len(ids) for ids, _ in encoded) >= CPU_TOKENS:
        hardware = device()
    model.to(hardware).eval()
    out: list[list[Span]] = [[] for _ in texts]
    order = sorted(range(len(texts)), key=lambda i: len(encoded[i][0]))
    for first in range(0, len(order), BATCH):
        batch = order[first : first + BATCH]
        with torch.no_grad():
            output = model(**batch_tensors(tokenizer, [encoded[i][0] for i in batch], hardware))
        tags = output.logits.argmax(-1).cpu().tolist()
        for row, i in enumerate(batch):
            ids, offsets = encoded[i]
            out[i] = spans_of(texts[i], offsets, tags[row][: len(ids)], trailing)
    return out
