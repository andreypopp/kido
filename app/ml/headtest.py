"""One encoder with two heads or two models? Trains on the spike labels and scores against the
original gold ranges. A small, noisy test."""

from __future__ import annotations

import bisect
import copy
import json
import random
import statistics
import sys
from dataclasses import dataclass

import torch
from torch import nn
from transformers import AutoModel, AutoTokenizer, logging

from jsonl import read_jsonl
from questions import Question, questions_of
from segments import Segment, segments
from spike import TEXTS, labels_path

logging.set_verbosity_error()
MODEL = "jhu-clsp/ettin-encoder-32m"
TAGS = ["O", "B", "I"]
EPOCHS = 8
BATCH = 8
LEARNING_RATE = 5e-5
HEAD_LEARNING_RATE = 1e-3
WINDOW = 1024
OVERLAP = 512


class TwoHeads(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.encoder = AutoModel.from_pretrained(MODEL)
        size = self.encoder.config.hidden_size
        self.heads = nn.ModuleDict({"question": nn.Linear(size, 3), "option": nn.Linear(size, 3)})

    def forward(self, ids, mask, head: str):
        hidden = self.encoder(input_ids=ids, attention_mask=mask).last_hidden_state
        return self.heads[head](hidden)


@dataclass
class Chunk:
    start: int
    end: int
    cut_left: bool
    cut_right: bool


def chunks_of(tokenizer, text: str, cuts: list[Segment]) -> list[Chunk]:
    """Windows of at most WINDOW tokens that overlap by OVERLAP, cut after a blank row."""
    offsets = tokenizer(text, return_offsets_mapping=True, add_special_tokens=False)[
        "offset_mapping"
    ]
    ends = [b for _, b in offsets]
    first = [bisect.bisect_right(ends, s.start) for s in cuts]
    last = [bisect.bisect_left(ends, max(s.end, 1)) for s in cuts]
    room = WINDOW - 2
    out: list[Chunk] = []
    i = 0
    while True:
        j = i
        while j + 1 < len(cuts) and last[j + 1] - first[i] + 1 <= room:
            j += 1
        out.append(Chunk(cuts[i].start, cuts[j].end, i > 0, j + 1 < len(cuts)))
        if j + 1 >= len(cuts):
            return out
        after = [k for k in range(i + 1, j + 1) if first[k] - first[i] >= OVERLAP]
        paragraph = [k for k in after if cuts[k - 1].kind == "blank"]
        i = (paragraph or after or [j + 1])[0]


def question_example(tokenizer, text: str, chunk: Chunk, cuts: list[Segment], gold: list[Question]):
    part = text[chunk.start : chunk.end]
    encoded = tokenizer(part, return_offsets_mapping=True, truncation=True, max_length=WINDOW)
    offsets = encoded["offset_mapping"]
    labels = [-100] * len(offsets)
    spans, previous = [], None
    inside = [q for q in gold if chunk.start <= q.start and q.end <= chunk.end]
    for segment in cuts:
        if segment.kind == "blank" or not (
            chunk.start <= segment.start and segment.end <= chunk.end
        ):
            continue
        start = segment.start - chunk.start
        token = next((i for i, (a, b) in enumerate(offsets) if b > start and b > a), None)
        if token is None:
            continue
        index = next(
            (i for i, q in enumerate(inside) if q.start <= segment.start and segment.end <= q.end),
            None,
        )
        tag = "O" if index is None else ("I" if index == previous else "B")
        previous = index
        labels[token] = TAGS.index(tag)
        spans.append((token, segment.start, segment.end, tag))
    return {"ids": encoded["input_ids"], "labels": labels, "spans": spans}


def option_example(tokenizer, text: str, question: Question):
    part = text[question.start : question.end]
    encoded = tokenizer(part, return_offsets_mapping=True, truncation=True, max_length=WINDOW)
    labels = [-100 if a == b else 0 for a, b in encoded["offset_mapping"]]
    for option in question.options:
        at = part.find(option)
        previous = False
        for i, (a, b) in enumerate(encoded["offset_mapping"]):
            if a != b and a < at + len(option) and b > at:
                labels[i] = 2 if previous else 1
                previous = True
    return {
        "ids": encoded["input_ids"],
        "labels": labels,
        "offsets": encoded["offset_mapping"],
        "text": part,
    }


def batches(examples, rng, device):
    order = list(range(len(examples)))
    rng.shuffle(order)
    for start in range(0, len(order), BATCH):
        chunk = [examples[i] for i in order[start : start + BATCH]]
        width = max(len(e["ids"]) for e in chunk)
        pad = [width - len(e["ids"]) for e in chunk]
        ids = torch.tensor(
            [e["ids"] + [0] * p for e, p in zip(chunk, pad, strict=True)], device=device
        )
        mask = torch.tensor(
            [[1] * len(e["ids"]) + [0] * p for e, p in zip(chunk, pad, strict=True)], device=device
        )
        labels = torch.tensor(
            [e["labels"] + [-100] * p for e, p in zip(chunk, pad, strict=True)], device=device
        )
        yield ids, mask, labels


def step(model, optimizer, batch, head: str) -> None:
    ids, mask, labels = batch
    loss = nn.functional.cross_entropy(
        model(ids, mask, head).transpose(1, 2), labels, ignore_index=-100
    )
    optimizer.zero_grad()
    loss.backward()
    optimizer.step()


def train(model, plans: list[tuple[str, list]], epochs: int, seed: int, device) -> None:
    """Each epoch runs one pass per plan (head, examples); with two plans the batches alternate."""
    optimizer = torch.optim.AdamW(
        [
            {"params": model.encoder.parameters(), "lr": LEARNING_RATE},
            {"params": model.heads.parameters(), "lr": HEAD_LEARNING_RATE},
        ]
    )
    rng = random.Random(seed)
    model.train()
    for _ in range(epochs):
        streams = [(head, list(batches(examples, rng, device))) for head, examples in plans]
        for position in range(max(len(stream) for _, stream in streams)):
            for head, stream in streams:
                if stream:
                    step(model, optimizer, stream[position % len(stream)], head)


def runs(spans: list[tuple[int, int, str]]) -> list[tuple[int, int]]:
    found: list[list[int]] = []
    current = None
    for start, end, tag in spans:
        if tag == "B" or (tag == "I" and current is None):
            current = [start, end]
            found.append(current)
        elif tag == "I":
            current[1] = end
        else:
            current = None
    return [(a, b) for a, b in found]


def f1(matched: int, predicted: int, gold: int) -> float:
    if not matched:
        return 0.0
    precision, recall = matched / predicted, matched / gold
    return 2 * precision * recall / (precision + recall)


def predict_questions(
    model, tokenizer, text: str, plan: list[Chunk], cuts, device
) -> set[tuple[int, int]]:
    best: dict[tuple[int, int], int] = {}
    for chunk in plan:
        example = question_example(tokenizer, text, chunk, cuts, [])
        ids = torch.tensor([example["ids"]], device=device)
        tags = model(ids, torch.ones_like(ids), "question")[0].argmax(-1).tolist()
        found = runs([(a, b, TAGS[tags[token]]) for token, a, b, _ in example["spans"]])
        for start, end in found:
            if (chunk.cut_left and start == example["spans"][0][1]) or (
                chunk.cut_right and end == example["spans"][-1][2]
            ):
                continue
            edge = min(
                start - chunk.start if chunk.cut_left else 10**9,
                chunk.end - end if chunk.cut_right else 10**9,
            )
            best[(start, end)] = max(best.get((start, end), -1), edge)
    return set(best)


def predict_options(model, example, device) -> list[str]:
    ids = torch.tensor([example["ids"]], device=device)
    tags = model(ids, torch.ones_like(ids), "option")[0].argmax(-1).tolist()
    spans = runs(
        [(a, b, TAGS[t]) for (a, b), t in zip(example["offsets"], tags, strict=True) if a != b]
    )
    return [example["text"][a:b].strip() for a, b in spans]


def evaluate(model, tokenizer, test, device) -> dict[str, float]:
    model.eval()
    q_match = q_pred = q_gold = o_match = o_pred = o_gold = 0
    with torch.no_grad():
        for text, plan, cuts, gold in test:
            truth = {(q.start, q.end) for q in gold}
            guess = predict_questions(model, tokenizer, text, plan, cuts, device)
            q_match, q_pred, q_gold = (
                q_match + len(truth & guess),
                q_pred + len(guess),
                q_gold + len(truth),
            )
            for q in gold:
                wanted = list(q.options)
                got = predict_options(model, option_example(tokenizer, text, q), device)
                o_gold, o_pred = o_gold + len(wanted), o_pred + len(got)
                for option in got:
                    if option in wanted:
                        wanted.remove(option)
                        o_match += 1
    return {
        "question_f1": round(f1(q_match, q_pred, q_gold), 4),
        "option_f1": round(f1(o_match, o_pred, o_gold), 4),
    }


def main() -> int:
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    tokenizer = AutoTokenizer.from_pretrained(MODEL)
    texts = {str(r["id"]): r for r in read_jsonl(TEXTS)}
    items = []
    for item in read_jsonl(labels_path("think")):
        record = texts[str(item["id"])]
        text = str(record["text"])
        cuts = [s for s in segments(text) if s.kind != "blank"]
        gold = questions_of(text, item["label"])  # type: ignore[arg-type]
        items.append(
            (str(record["session"]), text, chunks_of(tokenizer, text, segments(text)), cuts, gold)
        )
    sessions = sorted({item[0] for item in items})
    random.Random(0).shuffle(sessions)
    held = set(sessions[: len(sessions) // 5])
    split = {
        "train": [i for i in items if i[0] not in held],
        "test": [i for i in items if i[0] in held],
    }
    coverage = {}
    for name, part in split.items():
        total = learnable = 0
        for _, _, plan, cuts, gold in part:
            begins, finishes = {s.start for s in cuts}, {s.end for s in cuts}
            total += len(gold)
            learnable += sum(
                q.start in begins
                and q.end in finishes
                and any(c.start <= q.start and q.end <= c.end for c in plan)
                for q in gold
            )
        coverage[name] = f"{learnable}/{total}"
    train_q = [
        question_example(tokenizer, text, chunk, cuts, gold)
        for _, text, plan, cuts, gold in split["train"]
        for chunk in plan
    ]
    train_o = [
        option_example(tokenizer, text, q) for _, text, _, _, gold in split["train"] for q in gold
    ]
    test = [(text, plan, cuts, gold) for _, text, plan, cuts, gold in split["test"]]
    multi = sum(len(plan) > 1 for _, _, plan, _, _ in items)
    results = []
    for seed in range(3):
        torch.manual_seed(seed)
        shared = TwoHeads().to(device)
        train(shared, [("question", train_q)], EPOCHS, seed, device)
        row = {"seed": seed, "question_only": evaluate(shared, tokenizer, test, device)}
        control = copy.deepcopy(shared)
        train(control, [("question", train_q)], 1, seed + 100, device)
        row["plus_one_question_epoch"] = evaluate(control, tokenizer, test, device)
        train(shared, [("option", train_o)], 1, seed + 200, device)
        row["sequential_plus_one_option_epoch"] = evaluate(shared, tokenizer, test, device)
        torch.manual_seed(seed)
        joint = TwoHeads().to(device)
        train(joint, [("question", train_q), ("option", train_o)], EPOCHS, seed, device)
        row["joint"] = evaluate(joint, tokenizer, test, device)
        torch.manual_seed(seed)
        for epochs in (1, EPOCHS):
            alone = TwoHeads().to(device)
            train(alone, [("option", train_o)], epochs, seed, device)
            row[f"option_model_{epochs}_epochs"] = evaluate(alone, tokenizer, test, device)
        results.append(row)
        print(json.dumps(row), flush=True)
    keys = [key for key in results[0] if key != "seed"]
    summary = {
        key: {
            metric: round(statistics.fmean(r[key][metric] for r in results), 4)
            for metric in ("question_f1", "option_f1")
        }
        for key in keys
    }
    print(
        json.dumps(
            {
                "summary": summary,
                "train_texts": len(split["train"]),
                "test_texts": len(split["test"]),
                "gold_learnable": coverage,
                "texts_needing_chunks": multi,
                "train_option_examples": len(train_o),
                "test_gold_questions": sum(len(i[4]) for i in split["test"]),
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
