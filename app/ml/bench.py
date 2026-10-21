"""Latency of each Core ML function and of the CLI: `uv run bench`."""

import argparse
import json
import statistics
import subprocess
import sys
import time

import coremltools as ct  # noqa: E402,I001
import numpy as np

from coreml import COMPUTE, COREML
from jsonl import DATA, read_json, write_json

RUNS = 50
WARMUP = 5
FIXTURE = "fixtures/two-questions.txt"


def percentiles(samples: list[float]) -> dict[str, float]:
    ordered = sorted(samples)
    return {
        "p50": round(statistics.median(ordered) * 1000, 2),
        "p95": round(ordered[int(0.95 * (len(ordered) - 1))] * 1000, 2),
    }


def function_latency(task: str, shape: int, compute: str) -> dict[str, float]:
    model = ct.models.CompiledMLModel(
        str(COREML / f"{task}.mlmodelc"),
        compute_units=COMPUTE[compute],
        function_name=f"shape_{shape}",
    )
    inputs = {
        "input_ids": np.random.randint(0, 1000, (1, shape)).astype(np.int32),
        "attention_mask": np.ones((1, shape), dtype=np.int32),
    }
    for _ in range(WARMUP):
        model.predict(inputs)
    samples = []
    for _ in range(RUNS):
        start = time.perf_counter()
        model.predict(inputs)
        samples.append(time.perf_counter() - start)
    return percentiles(samples)


def cli_wall(backend: str) -> float:
    start = time.perf_counter()
    subprocess.run(
        ["uv", "run", "extract", FIXTURE, "--backend", backend],
        check=True,
        capture_output=True,
    )
    return round(time.perf_counter() - start, 2)


def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)
    shapes = read_json(COREML / "settings.json")["shapes"]
    result = {
        "functions_ms": {
            f"{task}-{shape}-{compute}": function_latency(task, shape, compute)
            for task, sizes in shapes.items()
            for shape in sizes
            for compute in ("cpu", "gpu")
        },
        "cli_wall_s": {
            backend: min(cli_wall(backend) for _ in range(3)) for backend in ("torch", "coreml")
        },
    }
    write_json(DATA / "reports" / "bench.json", result)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
