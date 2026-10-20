"""Train the Ettin token tagger, or export the Create ML baseline."""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import resource
import subprocess
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader
from transformers import AutoModelForTokenClassification, AutoTokenizer

from render import SEED, read_jsonl
from runtime import MODEL, device
from validate import TAGS, bio, example

WORD = re.compile(r"\n|\S+")
WARMUP = 5
MEMORY_EVERY = 10


def encode(records, tokenizer, bold: bool, max_length: int) -> list[dict[str, object]]:
    items = []
    for record in records:
        prompt, spans = example(record, bold)
        encoded = tokenizer(
            prompt,
            return_offsets_mapping=True,
            add_special_tokens=True,
            truncation=True,
            max_length=max_length,
        )
        offsets = [list(pair) for pair in encoded["offset_mapping"]]
        items.append(
            {
                "input_ids": encoded["input_ids"],
                "attention_mask": encoded["attention_mask"],
                "labels": bio(offsets, spans),
                "length": len(encoded["input_ids"]),
            }
        )
    return items


def batches(items: list[dict[str, object]], batch_size: int, seed: int) -> list[list[int]]:
    rng = random.Random(seed)
    order = sorted(range(len(items)), key=lambda index: int(items[index]["length"]))
    chunks = [
        order[index : index + batch_size * 50]
        for index in range(0, len(order), batch_size * 50)
    ]
    rng.shuffle(chunks)
    result = []
    for chunk in chunks:
        chunk = sorted(chunk, key=lambda index: int(items[index]["length"]))
        result.extend(
            chunk[index : index + batch_size] for index in range(0, len(chunk), batch_size)
        )
    return result


def collate(batch: list[dict[str, object]], pad_id: int):
    width = max(len(item["input_ids"]) for item in batch)
    input_ids = []
    masks = []
    labels = []
    for item in batch:
        count = width - len(item["input_ids"])
        input_ids.append(list(item["input_ids"]) + [pad_id] * count)
        masks.append(list(item["attention_mask"]) + [0] * count)
        labels.append(list(item["labels"]) + [-100] * count)
    return (
        torch.tensor(input_ids, dtype=torch.long),
        torch.tensor(masks, dtype=torch.long),
        torch.tensor(labels, dtype=torch.long),
    )


def train_ettin(args: argparse.Namespace) -> dict[str, object]:
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    tokenizer = AutoTokenizer.from_pretrained(MODEL)
    model = AutoModelForTokenClassification.from_pretrained(
        MODEL, num_labels=len(TAGS), attn_implementation="sdpa"
    )
    hardware = device()
    model.to(hardware)
    train_records = read_jsonl(args.train)
    eval_records = read_jsonl(args.eval)
    started = time.monotonic()
    data = encode(train_records, tokenizer, args.bold, args.max_length)
    prep_seconds = time.monotonic() - started
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate)
    steps_per_epoch = len(batches(data, args.batch_size, args.seed))
    total_steps = steps_per_epoch * args.epochs
    warmup_steps = max(1, int(total_steps * args.warmup_fraction))

    def schedule(step: int) -> float:
        if step < warmup_steps:
            return (step + 1) / warmup_steps
        return max(0.0, (total_steps - step) / max(1, total_steps - warmup_steps))

    scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, schedule)
    model.train()
    peak_current = 0
    peak_driver = 0
    real_tokens = torch.zeros((), dtype=torch.long, device=hardware)
    padded_tokens = 0
    examples_seen = 0
    step_index = 0
    autocast = hardware.type == "mps" and args.autocast
    started = time.monotonic()
    for epoch in range(args.epochs):
        loader = DataLoader(
            data,
            batch_sampler=batches(data, args.batch_size, args.seed + epoch),
            collate_fn=lambda batch: collate(batch, tokenizer.pad_token_id),
        )
        for input_ids, masks, labels in loader:
            input_ids = input_ids.to(hardware)
            masks = masks.to(hardware)
            labels = labels.to(hardware)
            try:
                with torch.autocast(
                    device_type=hardware.type, dtype=torch.bfloat16, enabled=autocast
                ):
                    loss = model(
                        input_ids=input_ids, attention_mask=masks, labels=labels
                    ).loss
                loss.backward()
            except (RuntimeError, TypeError):
                if not autocast:
                    raise
                autocast = False
                optimizer.zero_grad(set_to_none=True)
                loss = model(input_ids=input_ids, attention_mask=masks, labels=labels).loss
                loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            scheduler.step()
            optimizer.zero_grad(set_to_none=True)
            if step_index >= WARMUP:
                real_tokens += masks.sum()
                padded_tokens += masks.numel()
                examples_seen += input_ids.shape[0]
            if hardware.type == "mps" and step_index % MEMORY_EVERY == 0:
                peak_current = max(peak_current, torch.mps.current_allocated_memory())
                peak_driver = max(peak_driver, torch.mps.driver_allocated_memory())
            step_index += 1
    seconds = time.monotonic() - started
    args.output.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(args.output, safe_serialization=True)
    tokenizer.save_pretrained(args.output)
    tokens = int(real_tokens.item())
    metrics: dict[str, object] = {
        "backend": "ettin",
        "model": MODEL,
        "bold": args.bold,
        "seed": args.seed,
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "max_length": args.max_length,
        "learning_rate": args.learning_rate,
        "warmup_fraction": args.warmup_fraction,
        "total_steps": total_steps,
        "train": len(data),
        "eval": len(eval_records),
        "prep_seconds": round(prep_seconds, 3),
        "train_seconds": round(seconds, 3),
        "warmup_steps": WARMUP,
        "real_tokens_per_second": round(tokens / seconds, 1),
        "padded_tokens_per_second": round(padded_tokens / seconds, 1),
        "examples_per_second": round(examples_seen / seconds, 2),
        "peak_current_bytes": peak_current,
        "peak_driver_bytes": peak_driver
        if hardware.type == "mps"
        else resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "device": str(hardware),
        "bf16_autocast": autocast,
    }
    (args.output / "training.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, sort_keys=True))
    return metrics


def word_example(
    record: dict[str, object], bold: bool
) -> tuple[list[str], list[dict[str, int]], list[str]]:
    prompt, spans = example(record, bold)
    tokens: list[str] = []
    offsets: list[dict[str, int]] = []
    for match in WORD.finditer(prompt):
        tokens.append("<NL>" if match.group(0) == "\n" else match.group(0))
        offsets.append({"start": match.start(), "end": match.end()})
    pairs = [(item["start"], item["end"]) for item in offsets]
    labels = [TAGS[value] for value in bio(pairs, spans)]
    return tokens, offsets, labels


def train_createml(args: argparse.Namespace) -> dict[str, object]:
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    train = [word_example(record, args.bold) for record in read_jsonl(args.train)]
    evaluation = [word_example(record, args.bold) for record in read_jsonl(args.eval)]
    (output / "train.json").write_text(
        json.dumps([{"tokens": tokens, "labels": labels} for tokens, _, labels in train])
        + "\n"
    )
    (output / "eval-data.json").write_text(
        json.dumps([{"tokens": tokens, "labels": labels} for tokens, _, labels in evaluation])
        + "\n"
    )
    (output / "eval-text.json").write_text(
        json.dumps(
            [
                {"id": record["id"], "tokens": tokens, "offsets": offsets}
                for record, (tokens, offsets, _) in zip(
                    read_jsonl(args.eval), evaluation, strict=True
                )
            ]
        )
        + "\n"
    )
    script = Path(__file__).with_name("train_createml.swift")
    environment = dict(os.environ)
    environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    started = time.monotonic()
    result = subprocess.run(
        [
            "xcrun",
            "swift",
            str(script),
            str(output / "train.json"),
            str(output / "eval-data.json"),
            str(output / "ParagraphTaggerCreateML.mlmodel"),
            str(output / "predictions.json"),
        ],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    seconds = time.monotonic() - started
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit(result.returncode)
    model_path = output / "ParagraphTaggerCreateML.mlmodel"
    metrics: dict[str, object] = {
        "backend": "createml",
        "bold": args.bold,
        "seed": args.seed,
        "train": len(train),
        "eval": len(evaluation),
        "train_seconds": round(seconds, 3),
        "model_bytes": model_path.stat().st_size if model_path.exists() else 0,
        "swift": result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "",
    }
    (output / "training.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, sort_keys=True))
    return metrics


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["ettin", "createml"], default="ettin")
    parser.add_argument("--train", type=Path, default=Path("data/train.jsonl"))
    parser.add_argument("--eval", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--max-length", type=int, default=1024)
    parser.add_argument("--learning-rate", type=float, default=5e-5)
    parser.add_argument("--warmup-fraction", type=float, default=0.1)
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--no-bold", dest="bold", action="store_false")
    parser.add_argument("--no-autocast", dest="autocast", action="store_false")
    args = parser.parse_args(argv)
    if args.backend == "ettin":
        train_ettin(args)
    else:
        train_createml(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
