"""Compare the Core ML eval metrics against the PyTorch metrics of one checkpoint."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from runtime import chosen_checkpoint

PARTS = ("ask", "real", "synthetic", "union")
KEYS = {
    "question_f1": ("token_f1", "question", "f1"),
    "option_f1": ("option", "f1"),
    "option_visible_f1": ("option_visible", "f1"),
}


def values(evaluation: dict[str, object], part: str) -> dict[str, float]:
    source = evaluation if part == "union" else evaluation["parts"][part]
    result: dict[str, float] = {"examples": source["examples"]}
    for name, path in KEYS.items():
        value = source
        for key in path:
            value = value[key]
        result[name] = value
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--torch", type=Path)
    parser.add_argument("--coreml", type=Path, default=Path("data/eval-coreml.json"))
    parser.add_argument("--output", type=Path, default=Path("data/parity.json"))
    args = parser.parse_args(argv)
    args.torch = args.torch or chosen_checkpoint() / "eval.json"
    torch_eval = json.loads(args.torch.read_text())
    coreml_eval = json.loads(args.coreml.read_text())
    parts: dict[str, object] = {}
    for part in PARTS:
        before = values(torch_eval, part)
        after = values(coreml_eval, part)
        parts[part] = {
            "examples": before["examples"],
            "torch": {name: before[name] for name in KEYS},
            "coreml": {name: after[name] for name in KEYS},
            "delta": {name: after[name] - before[name] for name in KEYS},
        }
    worst = max(abs(parts[part]["delta"][name]) for part in PARTS for name in KEYS)
    result = {
        "torch": str(args.torch),
        "coreml": str(args.coreml),
        "parts": parts,
    }
    result["worst_delta"] = worst
    result["pass"] = worst <= 0.005
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({part: parts[part]["delta"] for part in PARTS}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
