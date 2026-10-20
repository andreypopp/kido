"""Measure compiled Core ML load time and prediction latency per shape and unit."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

from eval import (
    COMPUTE_UNITS,
    SHAPES,
    load_checkpoint,
    padded,
    shape_for,
    synthetic_prompt,
    token_length,
    tokenize,
)
from render import read_jsonl
from runtime import PACKAGE, chosen_checkpoint
from validate import example


def select(tokenizer, path: Path, shape: int, bold: bool) -> tuple[str, int, int]:
    candidates = []
    for record in read_jsonl(path):
        prompt, _ = example(record, bold)
        length = token_length(tokenizer, prompt)
        if shape_for(length) == shape:
            candidates.append((length, prompt))
    if not candidates:
        return synthetic_prompt(tokenizer, 1600), 0, 1600
    candidates.sort(key=lambda item: item[0])
    length, prompt = candidates[len(candidates) // 2]
    return prompt, len(candidates), length


def latency(run, runs: int, warmup: int = 5) -> dict[str, float]:
    for _ in range(warmup):
        run()
    values = []
    for _ in range(runs):
        started = time.perf_counter()
        run()
        values.append((time.perf_counter() - started) * 1000)
    return {
        "p50_ms": float(np.percentile(values, 50)),
        "p95_ms": float(np.percentile(values, 95)),
        "min_ms": float(np.min(values)),
    }


def measure_load(load, predict) -> float:
    started = time.perf_counter()
    load()
    predict()
    return (time.perf_counter() - started) * 1000


def worker(args: argparse.Namespace) -> int:
    from eval import CoreML

    ids = np.load(args.ids)
    mask = np.load(args.mask)
    backend = CoreML(
        args.model,
        args.unit,
        compiled=args.mode == "compiled",
    )
    def predict():
        return backend.predict(args.shape, ids, mask)

    load_ms = measure_load(lambda: backend.load([args.shape]), predict)
    result = latency(predict, args.runs)
    print(json.dumps({"load_ms": load_ms, **result}, sort_keys=True))
    return 0


def run_worker(args, mode: str) -> dict[str, object]:
    command = [
        sys.executable,
        str(Path(__file__)),
        "--worker",
        "--mode",
        mode,
        "--model",
        str(args.model if mode == "package" else args.compiled),
        "--unit",
        args.unit,
        "--shape",
        str(args.shape),
        "--ids",
        str(args.ids),
        "--mask",
        str(args.mask),
        "--runs",
        str(args.runs),
    ]
    process = subprocess.run(command, capture_output=True, text=True, check=False)
    if process.returncode != 0:
        raise RuntimeError(process.stderr)
    return json.loads(process.stdout)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=PACKAGE)
    parser.add_argument("--tokenizer", type=Path)
    parser.add_argument("--eval", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--shapes", type=int, nargs="+", default=SHAPES)
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--output", type=Path, default=Path("data/bench.json"))
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--mode", choices=["package", "compiled"])
    parser.add_argument("--ids")
    parser.add_argument("--mask")
    parser.add_argument("--unit", choices=list(COMPUTE_UNITS))
    parser.add_argument("--shape", type=int)
    args = parser.parse_args(argv)
    if args.worker:
        return worker(args)
    import coremltools as ct

    if args.tokenizer is None:
        args.tokenizer = chosen_checkpoint()
    bold, _, tokenizer = load_checkpoint(args.tokenizer)
    directory = Path(tempfile.mkdtemp(prefix="paragraph-bench-", dir="/tmp"))
    args.compiled = ct.utils.compile_model(
        str(args.model), str(directory / "model.mlmodelc")
    )
    plans = {}
    for shape in args.shapes:
        prompt, records, tokens = select(tokenizer, args.eval, shape, bold)
        ids, mask, _ = tokenize(tokenizer, prompt, shape)
        arrays = padded(ids, mask, shape, tokenizer.pad_token_id)
        np.save(directory / f"{shape}-ids.npy", arrays[0])
        np.save(directory / f"{shape}-mask.npy", arrays[1])
        plans[shape] = (records, tokens)
    rows = []
    for unit in COMPUTE_UNITS:
        for shape in args.shapes:
            args.unit = unit
            args.shape = shape
            args.ids = str(directory / f"{shape}-ids.npy")
            args.mask = str(directory / f"{shape}-mask.npy")
            compiled = run_worker(args, "compiled")
            package = run_worker(args, "package")
            records, tokens = plans[shape]
            rows.append(
                {
                    "unit": unit,
                    "shape": shape,
                    "records": records,
                    "tokens": tokens,
                    "compile_load_ms": package["load_ms"],
                    "load_ms": compiled["load_ms"],
                    "p50_ms": compiled["p50_ms"],
                    "p95_ms": compiled["p95_ms"],
                    "min_ms": compiled["min_ms"],
                }
            )
    result = {
        "package": str(args.model),
        "compiled": args.compiled,
        "runs": args.runs,
        "shapes": args.shapes,
        "rows": rows,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
