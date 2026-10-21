"""Load time and latency of each Core ML function on each compute unit, each in a fresh process,
and the wall time of the whole CLI: `bench.py --coreml data/coreml --runs 30`.

Each function is measured in two processes in a row. The first call of the second one reads the
operating system's cache of the compiled model, so it shows the usual start; the first one
shows the start after a change.
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

from coreml_runtime import CoreMLBackend
from extract import positive, timed
from jsonl import file_digest, write_json
from model import COMPUTE_UNITS
from paths import COREML, MODEL, REPORTS

FIXTURE = Path("fixtures/choice-and-list.txt")


def worker(args: argparse.Namespace) -> None:
    backend = CoreMLBackend(args.coreml, args.unit)
    ids = np.random.default_rng(0).integers(1000, 30000, args.shape).tolist()
    print(json.dumps(timed(lambda: backend.logits(args.task, ids), args.runs)))


def wall(command: list[str]) -> float:
    started = time.perf_counter()
    subprocess.run(command, capture_output=True, check=True)
    return round((time.perf_counter() - started) * 1000)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coreml", type=Path, default=COREML)
    parser.add_argument("--model", type=Path, default=MODEL, help="for the torch CLI wall time")
    parser.add_argument("--runs", type=positive, default=30)
    parser.add_argument("--output", type=Path, default=REPORTS / "bench.json")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--task")
    parser.add_argument("--shape", type=int)
    parser.add_argument("--unit")
    args = parser.parse_args(argv)
    if args.worker:
        worker(args)
        return 0
    shapes = json.loads((args.coreml / "settings.json").read_text())["shapes"]
    rows = []
    for unit in COMPUTE_UNITS:
        for task, task_shapes in shapes.items():
            for shape in task_shapes:
                command = [
                    sys.executable, __file__, "--worker", "--coreml", str(args.coreml),
                    "--runs", str(args.runs), "--task", task, "--shape", str(shape),
                    "--unit", unit,
                ]  # fmt: skip
                first, second = (
                    json.loads(
                        subprocess.run(command, capture_output=True, text=True, check=True).stdout
                    )
                    for _ in range(2)
                )
                rows.append(
                    {"unit": unit, "task": task, "shape": shape}
                    | second
                    | {"first_ms_after_change": first["first_ms"]}
                )
                print(rows[-1], flush=True)
    extract = [sys.executable, str(Path(__file__).with_name("extract.py")), str(FIXTURE)]
    cli = {
        "coreml_gpu": wall([*extract, "--backend", "coreml", "--coreml", str(args.coreml)]),
        "torch": wall([*extract, "--model", str(args.model)]),
    }
    write_json(
        args.output,
        {
            "manifest": file_digest(args.coreml / "manifest.json"),
            "platform": platform.platform(),
            "chip": subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True
            ).stdout.strip(),
            "runs": args.runs,
            "rows": rows,
            "cli_wall_ms": cli,
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
