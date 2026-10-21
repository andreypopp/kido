"""Core ML against PyTorch on the eval or dev set, both loaded through extract.load: tag
agreement, metric differences, and the 2,048-token question function (if converted) against
chunking at 1,024 on the texts longer than 1,024 tokens, and against PyTorch on the same input.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from chunks import LENGTH, LONG, Chunk, encode
from evaluate import score_backend
from extract import load, predict
from jsonl import file_digest, read_jsonl, write_json
from model import COMPUTE_UNITS, DEFAULT_COMPUTE, Backend
from paths import COREML, MODEL, REPORTS, output_path
from provenance import code_state, input_hashes

METRICS = ("question_f1", "option_f1_in_gold", "option_f1_end_to_end", "whole_output_exact")
LIMIT = 0.005


class Compared(Backend):
    """Answers with the candidate's logits; counts where the reference's tags differ."""

    def __init__(self, reference: Backend, candidate: Backend) -> None:
        super().__init__(candidate.threshold, candidate.crf)
        self.reference, self.candidate = reference, candidate
        self.same = {"question": 0, "option": 0}
        self.total = {"question": 0, "option": 0}

    def logits(self, task: str, ids: list[int]) -> np.ndarray:
        got = self.candidate.logits(task, ids)
        if task == "option":
            expected = self.reference.logits(task, ids).argmax(-1)
            self.same[task] += int((got.argmax(-1) == expected).sum())
            self.total[task] += len(ids)
        return got

    def question_tags(self, enc, chunk) -> list[int]:
        got = super().question_tags(enc, chunk)
        expected = self.reference.question_tags(enc, chunk)
        self.same["question"] += sum(a == b for a, b in zip(got, expected, strict=True))
        self.total["question"] += len(got)
        return got

    def agreement(self) -> dict[str, float]:
        return {t: round(self.same[t] / max(1, self.total[t]), 6) for t in self.total}


def whole_text(tokenizer, backend, text: str):
    """Predictions with the whole text in one window."""
    return predict(
        tokenizer, backend, text, lambda enc: [Chunk(0, len(enc.flat.cuts) - 1, 0, len(enc.ids))]
    )


def deltas(before: dict, after: dict) -> dict[str, dict[str, float]]:
    return {
        part: {
            m: round(after[part][m] - before[part][m], 4)
            for m in METRICS
            if before[part][m] is not None
        }
        for part in before
    }


def metrics_of(scores: dict) -> dict:
    return {part: {m: s[m] for m in METRICS} for part, s in scores.items()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split", choices=["dev", "eval"], default="eval")
    parser.add_argument("--model", type=Path, default=MODEL)
    parser.add_argument("--coreml", type=Path, default=COREML)
    parser.add_argument("--compute", choices=COMPUTE_UNITS, default=DEFAULT_COMPUTE)
    parser.add_argument("--output", type=Path, default=REPORTS / "parity.json")
    parser.add_argument("--limit", type=int)
    args = parser.parse_args(argv)
    records = read_jsonl(output_path(args.split))[: args.limit]
    tokenizer, reference_backend = load(args.model)
    _, coreml = load(args.coreml, "coreml", args.compute)
    if coreml.threshold != reference_backend.threshold:
        parser.error("the checkpoint and the Core ML directory have different thresholds")
    compared = Compared(reference_backend, coreml)
    reference = score_backend(records, tokenizer, reference_backend)
    candidate = score_backend(records, tokenizer, compared)
    delta = deltas(reference, candidate)
    worst = max(abs(v) for part in delta.values() for v in part.values())
    result: dict[str, object] = {
        "code": code_state(),
        "inputs": input_hashes(**{args.split: output_path(args.split)}),
        "manifest": file_digest(args.coreml / "manifest.json"),
        "compute": args.compute,
        "question_threshold": coreml.threshold,
        "texts": len(records),
        "tag_agreement": compared.agreement(),
        "torch": reference,
        "coreml": candidate,
        "delta": delta,
        "worst_delta": worst,
        "pass": worst <= LIMIT,
    }
    if LONG in coreml.shapes["question"]:
        lengths = [len(encode(tokenizer, str(r["text"])).ids) + 2 for r in records]
        long = [r for r, n in zip(records, lengths, strict=True) if n > LENGTH]
        fits = [r for r, n in zip(records, lengths, strict=True) if LENGTH < n <= LONG]
        same_input = Compared(reference_backend, coreml)
        chunked = score_backend(fits, tokenizer, coreml)
        whole = score_backend(fits, tokenizer, same_input, whole_text)
        torch_whole = score_backend(fits, tokenizer, reference_backend, whole_text)
        result["long_texts"] = {
            "over_1024": len(long),
            "fit_2048": len(fits),
            "coreml_chunked_1024": metrics_of(chunked),
            "coreml_single_2048": metrics_of(whole),
            "torch_single_2048": metrics_of(torch_whole),
            "delta_coreml_vs_torch_single_2048": deltas(torch_whole, whole),
            "tag_agreement_single_2048": same_input.agreement(),
        }
    write_json(args.output, result)
    print(f"worst delta {worst}; agreement {compared.agreement()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
