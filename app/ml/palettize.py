"""Palettise each Core ML function to 8 bits, merge them and measure the cost."""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.optimize.coreml import (
    OpPalettizerConfig,
    OptimizationConfig,
    palettize_weights,
)

from convert import aggregate, compare, multifunction, package_hash, package_size
from eval import (
    COMPUTE_UNITS,
    DEFAULT_COMPUTE_UNITS,
    SHAPES,
    CoreML,
    Torch,
    evaluate,
    load_checkpoint,
    shape_for,
)
from parity import KEYS, values
from runtime import FUNCTIONS, PACKAGE, chosen_checkpoint


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=PACKAGE.with_name("ParagraphTagger-8bit.mlpackage"),
    )
    parser.add_argument("--eval", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--metadata", type=Path, default=Path("data/palettize.json"))
    args = parser.parse_args(argv)
    checkpoint = args.model or chosen_checkpoint()
    bold, max_length, tokenizer = load_checkpoint(checkpoint)
    temporary = Path(tempfile.mkdtemp(prefix="paragraph-palette-", dir="/tmp"))
    palettized = []
    for shape in SHAPES:
        source = FUNCTIONS / f"shape_{shape}.mlpackage"
        if not source.exists():
            raise SystemExit(f"missing {source}; run make convert")
        model = ct.models.MLModel(str(source))
        reduced = palettize_weights(
            model, OptimizationConfig(global_config=OpPalettizerConfig(nbits=8, mode="kmeans"))
        )
        path = temporary / f"shape_{shape}-8bit.mlpackage"
        reduced.save(str(path))
        palettized.append((shape, path))
    multifunction(palettized, args.output)
    torch_eval = json.loads((checkpoint / "eval.json").read_text())
    reference = Torch(checkpoint)
    reference.load()
    core = CoreML(args.output, DEFAULT_COMPUTE_UNITS, tokenizer.pad_token_id)
    observed: dict[str, list[dict[str, float]]] = {}

    def combined(ids, mask):
        expected = reference.logits(ids, mask)
        candidate = core.logits(ids, mask)
        shape = shape_for(len(ids))
        observed.setdefault(str(shape), []).append(
            compare(expected, candidate, np.array(mask))
        )
        return candidate

    evaluation = evaluate(args.eval, combined, bold, max_length, tokenizer)
    agreement = {name: aggregate(values) for name, values in observed.items()}
    before = values(torch_eval, "real")
    after = values(evaluation, "real")
    delta = {name: after[name] - before[name] for name in KEYS}
    result = {
        "package": {
            "path": str(args.output),
            "hash": package_hash(args.output),
            "bytes": package_size(args.output),
            "fp16_bytes": package_size(PACKAGE),
            "functions": [shape for shape, _ in palettized],
            "palettize": {"nbits": 8, "mode": "kmeans"},
        },
        "agreement": agreement,
        "real": {
            "torch": {name: before[name] for name in KEYS},
            "palettized": {name: after[name] for name in KEYS},
            "delta": delta,
        },
        "within_parity": max(abs(value) for value in delta.values()) <= 0.005,
        "default_compute_units": COMPUTE_UNITS[DEFAULT_COMPUTE_UNITS],
        "default_package": "fp16",
    }
    shutil.rmtree(temporary)
    args.metadata.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
