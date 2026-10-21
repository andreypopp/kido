"""Train the question tagger and the option tagger, and select a seed on the real dev split.

`uv run train` trains the seeds on the labelled train units and keeps the best on the dev units.
"""

import argparse
import json
import random
import shutil
import sys
from pathlib import Path

import torch
from transformers import get_linear_schedule_with_warmup

from corpus import load_units
from evaluate import evaluate
from jsonl import DATA
from label import gold_of, load_labelled, load_prompt
from model import CHECKPOINT, batch_tensors, device, load, load_tokenizer, new_model, save
from tagging import Span, encode, tags_for

LABELS = DATA / "labels.jsonl"
LEARNING_RATE = 1e-4
EPOCHS = 10
SEEDS = (0, 1, 2)
CLIP = 1.0
BATCH = 16
WARMUP = 0.1
MAX_FPR = 0.02

Example = tuple[str, list[Span]]


def fit(tokenizer, data: list[Example], seed: int, epochs: int):
    """Train a tagger on (text, spans) examples. A text over MAX_TOKENS tokens is cut there, and
    the spans that end after the cut are left out. The batches hold texts of similar length;
    their order changes with each epoch."""
    random.seed(seed)
    torch.manual_seed(seed)
    hardware = device()
    encoded = []
    for text, spans in data:
        ids, offsets = encode(tokenizer, text)
        seen = max(end for _, end in offsets)
        encoded.append((ids, tags_for(offsets, [s for s in spans if s[1] <= seen])))
    encoded.sort(key=lambda item: len(item[0]))
    batches = [encoded[first : first + BATCH] for first in range(0, len(encoded), BATCH)]
    model = new_model().to(hardware).train()
    optimizer = torch.optim.AdamW(model.parameters(), lr=LEARNING_RATE)
    steps = epochs * len(batches)
    schedule = get_linear_schedule_with_warmup(optimizer, max(1, int(WARMUP * steps)), steps)
    rng = random.Random(seed)
    for _ in range(epochs):
        rng.shuffle(batches)
        for batch in batches:
            tensors = batch_tensors(
                tokenizer, [i for i, _ in batch], hardware, [t for _, t in batch]
            )
            model(**tensors).loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), CLIP)
            optimizer.step()
            schedule.step()
            optimizer.zero_grad()
    return model.eval()


def train(tokenizer, records: list[dict], seed: int, epochs: int = EPOCHS) -> dict:
    """The question tagger reads each unit; the option tagger reads each question."""
    gold = [(r["text"], gold_of(r)) for r in records]
    return {
        "question": fit(tokenizer, [(t, [q for q, _ in g]) for t, g in gold], seed, epochs),
        "option": fit(
            tokenizer,
            [(t[a:b], list(options)) for t, g in gold for (a, b), options in g],
            seed,
            epochs,
        ),
    }


def select(scores: dict[int, dict]) -> int | None:
    """Of the seeds with a dev FPR under MAX_FPR, the best mean of question F1 and end-to-end
    option F1."""
    ok = {seed: s for seed, s in scores.items() if s["fpr"] < MAX_FPR}
    return max(ok, key=lambda s: (ok[s]["question_f1"] + ok[s]["option_f1"]) / 2, default=None)


def run(
    tokenizer,
    train_records: list[dict],
    dev_records: list[dict],
    out: Path,
    seeds=SEEDS,
    epochs: int = EPOCHS,
) -> tuple[int | None, dict[int, dict]]:
    """Train each seed under out/seed<N>, score it on dev, and copy the selected one to
    out/selected. Returns the selected seed and the dev scores."""
    scores = {}
    for seed in seeds:
        taggers = train(tokenizer, train_records, seed, epochs)
        save(taggers, tokenizer, out / f"seed{seed}")
        scores[seed] = evaluate(tokenizer, taggers, dev_records)["all"]
    chosen = select(scores)
    if chosen is not None:
        shutil.copytree(out / f"seed{chosen}", out / "selected", dirs_exist_ok=True)
    return chosen, scores


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=EPOCHS)
    parser.add_argument("--seeds", type=int, nargs="+", default=list(SEEDS))
    parser.add_argument("--eval", action="store_true", help="score the selected checkpoint on eval")
    args = parser.parse_args(argv)
    rows, _ = load_units()
    labelled, skipped = load_labelled(LABELS, rows, load_prompt())
    print(f"train: skipped records {skipped}", file=sys.stderr)
    tokenizer = load_tokenizer()
    if args.eval:
        scores = evaluate(tokenizer, load(CHECKPOINT), labelled["eval"])
    else:
        chosen, scores = run(
            tokenizer,
            labelled["train"],
            labelled["dev"],
            CHECKPOINT.parent,
            args.seeds,
            args.epochs,
        )
        scores = {"selected": chosen, "dev": scores}
    print(json.dumps(scores, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
