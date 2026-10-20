"""Measure compiled Core ML load time and prediction latency per shape and unit."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models import CompiledMLModel
from transformers import AutoTokenizer

from convert import encode_padded
from render import read_jsonl

UNITS = {
    "CPU_ONLY": ct.ComputeUnit.CPU_ONLY,
    "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
    "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE,
    "ALL": ct.ComputeUnit.ALL,
}


def synthetic_prompt(tokenizer, shape: int) -> str:
    sentence = "The build writes one line to the log. "
    text = ""
    while len(tokenizer(text, add_special_tokens=True)["input_ids"]) < 1600:
        text += sentence
    while len(tokenizer(text, add_special_tokens=True)["input_ids"]) > shape:
        text = text.rsplit(" ", 1)[0]
    return text


def records_for(tokenizer, path: Path, shapes: list[int]) -> dict[int, str]:
    result: dict[int, str] = {}
    for record in read_jsonl(path):
        prompt = str(record["prompt"])
        length = len(tokenizer(prompt, add_special_tokens=True)["input_ids"])
        shape = next((value for value in shapes if length <= value), shapes[-1])
        result.setdefault(shape, prompt)
    for shape in shapes:
        if shape not in result:
            result[shape] = synthetic_prompt(tokenizer, shape)
    return result


def worker(args: argparse.Namespace) -> int:
    tokenizer = AutoTokenizer.from_pretrained(args.tokenizer)
    prompts = records_for(tokenizer, args.eval, args.shapes)
    unit = UNITS[args.unit]
    result: dict[str, object] = {"unit": args.unit, "shapes": {}}
    for shape in args.shapes:
        if shape not in prompts:
            continue
        started = time.perf_counter()
        model = CompiledMLModel(
            args.compiled,
            compute_units=unit,
            function_name=f"shape_{shape}",
        )
        load_ms = (time.perf_counter() - started) * 1000
        ids, mask = encode_padded(tokenizer, prompts[shape], shape)
        inputs = {"input_ids": ids, "attention_mask": mask}
        for _ in range(5):
            model.predict(inputs)
        latencies = []
        for _ in range(args.runs):
            started = time.perf_counter()
            model.predict(inputs)
            latencies.append((time.perf_counter() - started) * 1000)
        result["shapes"][str(shape)] = {
            "load_ms": load_ms,
            "p50_ms": float(np.percentile(latencies, 50)),
            "p95_ms": float(np.percentile(latencies, 95)),
            "min_ms": float(np.min(latencies)),
        }
    print(json.dumps(result, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model", type=Path, default=Path("data/output/ParagraphTagger.mlpackage")
    )
    parser.add_argument(
        "--tokenizer", type=Path, default=Path("data/output/curve-100-nobold-s2")
    )
    parser.add_argument("--eval", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--shapes", type=int, nargs="+", default=[512, 1024, 2048])
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--compiled")
    parser.add_argument("--unit", choices=list(UNITS))
    args = parser.parse_args(argv)
    if args.worker:
        return worker(args)
    directory = tempfile.mkdtemp(prefix="paragraph-bench-", dir="/tmp")
    compiled = ct.utils.compile_model(str(args.model), str(Path(directory) / "model.mlmodelc"))
    result: dict[str, object] = {"runs": args.runs, "compiled": compiled, "compute_units": {}}
    for name in UNITS:
        process = subprocess.run(
            [
                sys.executable,
                str(Path(__file__)),
                "--worker",
                "--compiled",
                compiled,
                "--unit",
                name,
                "--tokenizer",
                str(args.tokenizer),
                "--eval",
                str(args.eval),
                "--runs",
                str(args.runs),
                "--shapes",
                *[str(shape) for shape in args.shapes],
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if process.returncode != 0:
            print(process.stderr)
            return process.returncode
        result["compute_units"][name] = json.loads(process.stdout)
    Path("data/bench.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
