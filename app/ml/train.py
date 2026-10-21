"""Train the question and the option pass: `train.py --kind two|joint --output DIR`.

`joint` trains one encoder with both heads (saved in DIR); `two` trains one model for each task
(saved in DIR/question and DIR/option); `question` trains only DIR/question and copies
DIR/option from --option-from.
`--crf` replaces the per-slot cross-entropy of the question model with a CRF over its slots (its
transitions go into DIR/settings.json); `--two-ends` reads the last token of a segment too.
In every run each task sees each of its batches once per epoch; a joint epoch interleaves the two
tasks in a random order, one optimizer step each.
"""

from __future__ import annotations

import argparse
import hashlib
import random
import shutil
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import torch
from torch import nn

from chunks import IGNORE, question_example, sample_chunks
from crf import Crf, Transitions
from evaluate import dev_score, score_backend
from examples import Item, make_item, perturbed_examples
from flat import INPUT
from jsonl import file_digest, read_jsonl, write_json
from model import (
    REVISION,
    WEIGHTS,
    Tagger,
    TorchBackend,
    device,
    load_tokenizer,
    require_flat,
    save,
    update_settings,
)
from paths import output_path
from provenance import code_state, input_hashes
from split import is_synthetic

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
    crf: bool = False
    two_ends: bool = False
    fraction: float = 1.0


Batch = list[dict]


def subsample(records: list[dict], fraction: float, seed: int) -> tuple[list[dict], str]:
    """The records of a random share of the sessions, real and synthetic each (a synthetic text
    is its own unit), and the hash of the sampled units."""
    kept: set[str] = set()
    for synthetic in (False, True):
        units = sorted(
            {
                r["id"] if synthetic else r["session"]
                for r in records
                if is_synthetic(r) == synthetic
            }
        )
        kept |= set(random.Random(seed).sample(units, round(fraction * len(units))))
    chosen = [r for r in records if (r["id"] if is_synthetic(r) else r["session"]) in kept]
    return chosen, hashlib.sha256("\n".join(sorted(kept)).encode()).hexdigest()[:16]


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


def slot_tensors(batch: Batch, hardware: torch.device):
    """Slot positions, tags, counts and inside flags of a batch, for the CRF."""
    width = max(len(e["heads"]) for e in batch)
    pad = lambda values: values + [0] * (width - len(values))  # noqa: E731
    heads = [pad(e["heads"]) for e in batch]
    lasts = [pad(e["lasts"]) for e in batch]
    tags = [pad([e["labels"][h] for h in e["heads"]]) for e in batch]
    lengths = [len(e["heads"]) for e in batch]
    inside = [e["inside"] for e in batch]
    return tuple(torch.tensor(x, device=hardware) for x in (heads, lasts, tags, lengths, inside))


def clipped(model: Tagger, crf: Crf | None) -> list[nn.Parameter]:
    return [*model.parameters(), *(crf.parameters() if crf else [])]


def gather(out: torch.Tensor, index: torch.Tensor) -> torch.Tensor:
    return out.gather(1, index[..., None].expand(-1, -1, out.shape[-1]))


def epoch_streams(
    tasks: tuple[str, ...], tokenizer, items: list[Item], settings: Settings, rng: random.Random
) -> dict[str, list[Batch]]:
    streams = {}
    if "question" in tasks:
        examples = [
            question_example(item.enc, chunk, item.gold)
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
) -> tuple[Tagger, Transitions | None, dict[str, object]]:
    random.seed(settings.seed)
    np.random.seed(settings.seed)
    torch.manual_seed(settings.seed)
    rng = random.Random(settings.seed)
    hardware = device()
    model = Tagger(tasks, two_ends=settings.two_ends).to(hardware).train()
    crf = Crf().to(hardware) if settings.crf and "question" in tasks else None
    optimizer = torch.optim.AdamW(
        [
            {"params": model.encoder.parameters(), "lr": settings.learning_rate},
            {"params": model.heads.parameters(), "lr": HEAD_LEARNING_RATE},
            *(
                [{"params": crf.parameters(), "lr": HEAD_LEARNING_RATE, "weight_decay": 0.0}]
                if crf
                else []
            ),
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
            out = model(ids, mask, task)
            if crf and task == "question":
                heads, lasts, tags, lengths, inside = slot_tensors(
                    streams[task][cursor[task] - 1], hardware
                )
                emission = gather(out, heads)[..., :3]
                if settings.two_ends:
                    emission = emission + gather(out, lasts)[..., 3:]
                loss = crf.nll(emission, tags, lengths, inside).sum() / lengths.sum().clamp(min=1)
            else:
                loss = nn.functional.cross_entropy(out.transpose(1, 2), labels, ignore_index=IGNORE)
            loss.backward()
            norms.append(float(nn.utils.clip_grad_norm_(clipped(model, crf), 1.0)))
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
    return (
        model.eval(),
        crf.transitions() if crf else None,
        {
            "epochs": epochs,
            "train_seconds": round(seconds, 1),
            "tokens_per_second": round(tokens / seconds),
        },
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=["two", "joint", "question"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--learning-rate", type=float, default=5e-5)
    parser.add_argument("--question-batch", type=int, default=32)
    parser.add_argument("--option-batch", type=int, default=64)
    parser.add_argument("--limit", type=int, help="a random subset of N texts, for a smoke run")
    parser.add_argument("--dev-each-epoch", action="store_true", help="score the dev set (joint)")
    parser.add_argument("--option-from", type=Path, help="the run whose option/ is copied")
    parser.add_argument("--fraction", type=float, default=1.0, help="a share of the train sessions")
    parser.add_argument("--crf", action="store_true", help="a CRF over the question slots")
    parser.add_argument("--two-ends", action="store_true", help="read each segment's last token")
    args = parser.parse_args(argv)
    if args.output.exists() and any(args.output.iterdir()):
        parser.error(f"{args.output} is not empty")
    if args.dev_each_epoch and args.kind != "joint":
        parser.error("--dev-each-epoch needs --kind joint")
    if args.kind == "joint" and (args.crf or args.two_ends):
        parser.error("--crf and --two-ends need separate question and option models")
    if (args.kind == "question") != bool(args.option_from):
        parser.error("--kind question needs --option-from, and only it takes one")
    if args.option_from:
        try:
            require_flat(args.option_from)
        except ValueError as error:
            parser.error(str(error))
    if args.two_ends and not args.crf:
        parser.error("--two-ends needs --crf")
    settings = Settings(
        args.kind, str(args.output), args.seed, args.epochs, args.learning_rate,
        args.question_batch, args.option_batch, args.limit, args.dev_each_epoch,
        args.crf, args.two_ends, args.fraction,
    )  # fmt: skip
    records = [r for r in read_jsonl(output_path("train")) if r["split"] == "train"]
    sessions = None
    if args.fraction < 1:
        records, sessions = subsample(records, args.fraction, args.seed)
    if args.limit:
        random.Random(0).shuffle(records)
        records = records[: args.limit]
    tokenizer = load_tokenizer()
    items = [make_item(tokenizer, record) for record in records]
    dev = read_jsonl(output_path("dev"))

    def dev_scores(model: Tagger) -> dict[str, object]:
        backend = TorchBackend({task: model for task in model.heads})
        return dev_score(score_backend(dev, tokenizer, backend))

    groups = {
        "joint": [("question", "option")],
        "two": [("question",), ("option",)],
        "question": [("question",)],
    }[args.kind]
    results = {}
    for tasks in groups:
        model, transitions, results[tasks[0] if args.kind != "joint" else "joint"] = fit(
            tasks, items, tokenizer, settings, dev_scores if args.dev_each_epoch else None
        )
        save(model, tokenizer, args.output if args.kind == "joint" else args.output / tasks[0])
        if transitions:
            update_settings(args.output, crf=transitions.to_json())
    if args.option_from:
        shutil.copytree(args.option_from / "option", args.output / "option")
    update_settings(args.output, input=INPUT)
    write_json(
        args.output / "train.json",
        {
            "settings": asdict(settings),
            "texts": len(items),
            "sampled_sessions_hash": sessions,
            "option_from": str(args.option_from) if args.option_from else None,
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
