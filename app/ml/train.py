"""Train the question and the option pass: `train.py --kind two|joint --output DIR`.

`joint` trains one encoder with both heads (saved in DIR); `two` trains one model for each task
(saved in DIR/question and DIR/option). In every run each task sees each of its batches once
per epoch; a joint epoch interleaves the two tasks in a random order, one optimizer step each.
"""

from __future__ import annotations

import argparse
import random
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import torch
from torch import nn

from chunks import IGNORE, ids_of, labels_of, sample_chunks
from evaluate import dev_score, score_backend
from examples import Item, make_item, perturbed_examples
from jsonl import file_digest, read_jsonl, write_json
from model import REVISION, WEIGHTS, Tagger, TorchBackend, device, load_tokenizer, save
from paths import output_path
from provenance import code_state, input_hashes

HEAD_LEARNING_RATE = 1e-3
WARMUP_FRACTION = 0.1
POOL = 50
WIDTH_STEP = 32


@dataclass(frozen=True)
class Settings:
    kind: str
    output: str
    seed: int
    epochs: int
    learning_rate: float
    question_batch: int
    option_batch: int
    limit: int | None
    dev_each_epoch: bool


Batch = list[dict]


def batches(examples: list[dict], size: int, rng: random.Random) -> list[Batch]:
    """Batches of similar length: sort, cut into pools, shuffle the pools."""
    order = sorted(examples, key=lambda e: len(e["ids"]))
    pools = [order[i : i + size * POOL] for i in range(0, len(order), size * POOL)]
    rng.shuffle(pools)
    out = [pool[i : i + size] for pool in pools for i in range(0, len(pool), size)]
    rng.shuffle(out)
    return out


def tensors(batch: Batch, pad: int, hardware: torch.device):
    longest = max(len(e["ids"]) for e in batch)
    width = -(-longest // WIDTH_STEP) * WIDTH_STEP
    ids = [e["ids"] + [pad] * (width - len(e["ids"])) for e in batch]
    mask = [[1] * len(e["ids"]) + [0] * (width - len(e["ids"])) for e in batch]
    labels = [e["labels"] + [IGNORE] * (width - len(e["labels"])) for e in batch]
    return tuple(torch.tensor(x, device=hardware) for x in (ids, mask, labels))


def epoch_streams(
    tasks: tuple[str, ...], tokenizer, items: list[Item], settings: Settings, rng: random.Random
) -> dict[str, list[Batch]]:
    streams = {}
    if "question" in tasks:
        examples = [
            {"ids": ids_of(item.enc, chunk), "labels": labels_of(item.enc, chunk, item.gold)}
            for item in items
            for chunk in sample_chunks(item.enc, item.gold, rng)
        ]
        streams["question"] = batches(examples, settings.question_batch, rng)
    if "option" in tasks:
        examples = [e for item in items for e in item.options]
        examples += perturbed_examples(tokenizer, items, rng)
        streams["option"] = batches(examples, settings.option_batch, rng)
    return streams


def schedule(streams: dict[str, list[Batch]], rng: random.Random) -> list[str]:
    """The task of each step of an epoch: each stream once, in a random order."""
    order = [task for task, stream in streams.items() for _ in stream]
    rng.shuffle(order)
    return order


def fit(
    tasks: tuple[str, ...],
    items: list[Item],
    tokenizer,
    settings: Settings,
    after_epoch: Callable[[Tagger], dict[str, object]] | None,
) -> tuple[Tagger, dict[str, object]]:
    random.seed(settings.seed)
    np.random.seed(settings.seed)
    torch.manual_seed(settings.seed)
    rng = random.Random(settings.seed)
    hardware = device()
    model = Tagger(tasks).to(hardware).train()
    optimizer = torch.optim.AdamW(
        [
            {"params": model.encoder.parameters(), "lr": settings.learning_rate},
            {"params": model.heads.parameters(), "lr": HEAD_LEARNING_RATE},
        ],
        fused=True,
    )
    streams = epoch_streams(tasks, tokenizer, items, settings, rng)
    total = sum(len(stream) for stream in streams.values()) * settings.epochs
    warmup = max(1, int(total * WARMUP_FRACTION))
    scheduler = torch.optim.lr_scheduler.LambdaLR(
        optimizer,
        lambda n: (n + 1) / warmup if n < warmup else max(0.0, (total - n) / (total - warmup)),
    )
    epochs: list[dict[str, object]] = []
    tokens = 0
    started = time.monotonic()
    for epoch in range(settings.epochs):
        if epoch:
            streams = epoch_streams(tasks, tokenizer, items, settings, rng)
        cursor = dict.fromkeys(streams, 0)
        losses, norms = [], []
        for task in schedule(streams, rng):
            ids, mask, labels = tensors(
                streams[task][cursor[task]], tokenizer.pad_token_id, hardware
            )
            cursor[task] += 1
            loss = nn.functional.cross_entropy(
                model(ids, mask, task).transpose(1, 2), labels, ignore_index=IGNORE
            )
            loss.backward()
            norms.append(float(nn.utils.clip_grad_norm_(model.parameters(), 1.0)))
            optimizer.step()
            scheduler.step()
            optimizer.zero_grad(set_to_none=True)
            tokens += int(mask.sum())
            losses.append(loss.item())
        info: dict[str, object] = {
            "loss": round(sum(losses) / len(losses), 4),
            "clip_norm_mean": round(sum(norms) / len(norms), 3),
            "clip_norm_max": round(max(norms), 3),
            "clip_share_over_1": round(sum(n > 1.0 for n in norms) / len(norms), 3),
        }
        if after_epoch:
            model.eval()
            info["dev"] = after_epoch(model)
            model.train()
        epochs.append(info)
        print(f"{'+'.join(tasks)} epoch {epoch + 1}/{settings.epochs} {info}", flush=True)
    seconds = time.monotonic() - started
    return model.eval(), {
        "epochs": epochs,
        "train_seconds": round(seconds, 1),
        "tokens_per_second": round(tokens / seconds),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=["two", "joint"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--learning-rate", type=float, default=5e-5)
    parser.add_argument("--question-batch", type=int, default=32)
    parser.add_argument("--option-batch", type=int, default=64)
    parser.add_argument("--limit", type=int, help="a random subset of N texts, for a smoke run")
    parser.add_argument("--dev-each-epoch", action="store_true", help="score the dev set (joint)")
    args = parser.parse_args(argv)
    if args.output.exists() and any(args.output.iterdir()):
        parser.error(f"{args.output} is not empty")
    if args.dev_each_epoch and args.kind != "joint":
        parser.error("--dev-each-epoch needs --kind joint")
    settings = Settings(
        args.kind, str(args.output), args.seed, args.epochs, args.learning_rate,
        args.question_batch, args.option_batch, args.limit, args.dev_each_epoch,
    )  # fmt: skip
    records = [r for r in read_jsonl(output_path("train")) if r["split"] == "train"]
    if args.limit:
        random.Random(0).shuffle(records)
        records = records[: args.limit]
    tokenizer = load_tokenizer()
    items = [make_item(tokenizer, record) for record in records]
    dev = read_jsonl(output_path("dev"))

    def dev_scores(model: Tagger) -> dict[str, object]:
        backend = TorchBackend({task: model for task in model.heads})
        return dev_score(score_backend(dev, tokenizer, backend))

    groups = [("question", "option")] if args.kind == "joint" else [("question",), ("option",)]
    results = {}
    for tasks in groups:
        model, results[tasks[0] if args.kind == "two" else "joint"] = fit(
            tasks, items, tokenizer, settings, dev_scores if args.dev_each_epoch else None
        )
        save(model, tokenizer, args.output if args.kind == "joint" else args.output / tasks[0])
    write_json(
        args.output / "train.json",
        {
            "settings": asdict(settings),
            "texts": len(items),
            "hub_revision": REVISION,
            "code": code_state(),
            "inputs": input_hashes(train=output_path("train"), dev=output_path("dev")),
            "weights": {
                str(p.relative_to(args.output)): file_digest(p)
                for p in sorted(args.output.rglob(WEIGHTS))
            },
            "results": results,
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
