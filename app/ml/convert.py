"""Convert a checkpoint to Core ML: `convert.py --model data/model --output data/coreml`.

Each task gets one multifunction package with a fixed-shape function for each length, in fp16,
plus its compiled model. The output directory is self-contained: it also holds the tokenizer,
settings.json (shapes, pad id, tag ids, limits and the question threshold of the checkpoint) and
manifest.json (hashes of the checkpoint and the packages, sizes, the op placement for each compute
unit). --long adds the 2,048-token question function that only the measurement uses.
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import shutil
import types
import warnings
from pathlib import Path

import numpy as np
import torch

from chunks import LENGTH, LONG, OPTION_LENGTH, OPTION_SHAPES, OVERLAP, B, I, O
from coreml_runtime import UNITS
from jsonl import file_digest, write_json
from model import SETTINGS, WEIGHTS, Tagger, load_models, load_threshold, load_tokenizer
from paths import COREML, MODEL
from provenance import code_state

# coremltools warns on import that it has not been tested with the installed torch
logging.getLogger("coremltools").setLevel(logging.ERROR)

import coremltools as ct  # noqa: E402
from coremltools.models.compute_plan import MLComputePlan  # noqa: E402

MASKED = -10000.0


def padded_attention(self, hidden_states, position_embeddings=None, attention_mask=None, **_):
    # imported here: importing transformers' modernbert before model.py logs a torch note
    from transformers.models.modernbert.modeling_modernbert import apply_rotary_pos_emb

    shape = hidden_states.shape[:-1]
    qkv = self.Wqkv(hidden_states).view(*shape, 3, -1, self.head_dim)
    query, key, value = (x.transpose(1, 2) for x in qkv.unbind(dim=-3))
    cos, sin = position_embeddings
    query, key = apply_rotary_pos_emb(query, key, cos, sin, unsqueeze_dim=1)
    scores = torch.matmul(query, key.transpose(2, 3)) * (self.head_dim**-0.5)
    scores = scores + (1.0 - attention_mask.to(hidden_states.dtype))[:, None, None, :] * MASKED
    if self.attention_type == "sliding_attention":
        positions = torch.arange(hidden_states.shape[1], device=hidden_states.device)
        near = (positions[:, None] - positions[None, :]).abs() < self.sliding_window
        scores = scores + torch.where(near, 0.0, MASKED).to(hidden_states.dtype)
    weights = torch.softmax(scores, dim=-1, dtype=torch.float32).to(query.dtype)
    output = torch.matmul(weights, value).transpose(1, 2).contiguous().reshape(*shape, -1)
    return self.out_drop(self.Wo(output)), None


class Padded(torch.nn.Module):
    """One head of a tagger with an explicit padding mask and no data-dependent control flow."""

    def __init__(self, tagger: Tagger, task: str) -> None:
        super().__init__()
        self.encoder, self.head = tagger.encoder, tagger.heads[task]
        for layer in self.encoder.layers:
            layer.attn.attention_type = layer.attention_type
            layer.attn.forward = types.MethodType(padded_attention, layer.attn)

    def forward(self, input_ids, attention_mask):
        encoder = self.encoder
        hidden = encoder.embeddings(input_ids)
        positions = torch.arange(hidden.shape[1], device=hidden.device).unsqueeze(0)
        embeddings = {
            kind: encoder.rotary_emb(hidden, positions, kind)
            for kind in set(encoder.config.layer_types)
        }
        for layer in encoder.layers:
            hidden = layer(
                hidden,
                attention_mask=attention_mask,
                position_embeddings=embeddings[layer.attention_type],
            )
        return self.head(encoder.final_norm(hidden))


def package_hash(path: Path) -> str:
    digest = hashlib.sha256()
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(item.relative_to(path).as_posix().encode())
        digest.update(item.read_bytes())
    return digest.hexdigest()[:16]


def size(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def placement(compiled: Path) -> dict[str, dict[str, int]]:
    """Operations on each device, by MLComputePlan, for each compute unit."""
    result: dict[str, dict[str, int]] = {}
    for name in UNITS:
        plan = MLComputePlan.load_from_path(
            str(compiled), compute_units=getattr(ct.ComputeUnit, UNITS[name])
        )
        counts: dict[str, int] = {}
        for structure in plan.model_structure.program.functions.values():
            for operation in structure.block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
                device = "const" if usage is None else type(usage.preferred_compute_device).__name__
                counts[device] = counts.get(device, 0) + 1
        result[name] = counts
    return result


def convert_task(
    tagger: Tagger, task: str, shapes: tuple[int, ...], output: Path, scratch: Path
) -> dict:
    """Convert one task; return the op placement of each function."""
    wrapper = Padded(tagger, task).eval()
    descriptor = ct.utils.MultiFunctionDescriptor()
    placed = {}
    with warnings.catch_warnings():
        # external: torch.jit.trace is the only tracer that coremltools 9 converts, and its
        # converter passes warn about values that they handle
        warnings.simplefilter("ignore")
        for shape in shapes:
            ids = torch.randint(0, 1000, (1, shape), dtype=torch.long)
            mask = torch.ones((1, shape), dtype=torch.long)
            mask[0, -1] = 0
            traced = torch.jit.trace(wrapper, (ids, mask), strict=False)
            spec = [
                ct.TensorType(name=n, shape=[1, shape], dtype=np.int32)
                for n in ("input_ids", "attention_mask")
            ]
            package = scratch / f"{task}-{shape}.mlpackage"
            ct.convert(
                traced,
                inputs=spec,
                outputs=[ct.TensorType(name="logits")],
                convert_to="mlprogram",
                compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.macOS15,
            ).save(str(package))
            descriptor.add_function(str(package), "main", f"shape_{shape}")
            compiled = ct.utils.compile_model(
                str(package), str(scratch / f"{task}-{shape}.mlmodelc")
            )
            placed[f"shape_{shape}"] = placement(Path(compiled))
        descriptor.default_function_name = f"shape_{shapes[0]}"
        target = output / f"{task}.mlpackage"
        ct.utils.save_multifunction(descriptor, str(target))
        ct.utils.compile_model(str(target), str(output / f"{task}.mlmodelc"))
    return placed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=MODEL)
    parser.add_argument("--output", type=Path, default=COREML)
    parser.add_argument("--long", action="store_true", help="add the 2,048-token function")
    args = parser.parse_args(argv)
    if args.output.exists():
        parser.error(f"{args.output} exists")
    shapes = {
        "question": (LENGTH, LONG) if args.long else (LENGTH,),
        "option": OPTION_SHAPES,
    }
    scratch = args.output.with_name(args.output.name + "-scratch")
    scratch.mkdir(parents=True)
    args.output.mkdir(parents=True)
    models = load_models(args.model)
    placed = {
        task: convert_task(tagger, task, shapes[task], args.output, scratch)
        for task, tagger in models.items()
    }
    shutil.rmtree(scratch)
    tokenizer = load_tokenizer(args.model)
    tokenizer.save_pretrained(args.output)
    threshold = load_threshold(args.model)
    write_json(
        args.output / SETTINGS,
        {
            "shapes": {task: list(s) for task, s in shapes.items()},
            "pad_token_id": tokenizer.pad_token_id,
            "tags": {"O": O, "B": B, "I": I},
            "limits": {"question": LENGTH, "option": OPTION_LENGTH, "overlap": OVERLAP},
        }
        | ({"question_threshold": threshold} if threshold is not None else {}),
    )
    write_json(
        args.output / "manifest.json",
        {
            "code": code_state(),
            "coremltools": ct.__version__,
            "torch": torch.__version__,
            "precision": "FLOAT16",
            "checkpoint": {
                "path": str(args.model),
                "weights": {
                    str(p.relative_to(args.model)): file_digest(p)
                    for p in sorted(args.model.rglob(WEIGHTS))
                },
                "settings": file_digest(args.model / SETTINGS)
                if (args.model / SETTINGS).exists()
                else None,
                "tokenizer": file_digest(args.output / "tokenizer.json"),
            },
            "packages": {
                task: {
                    "shapes": list(shapes[task]),
                    "package_bytes": size(args.output / f"{task}.mlpackage"),
                    "compiled_bytes": size(args.output / f"{task}.mlmodelc"),
                    "package_hash": package_hash(args.output / f"{task}.mlpackage"),
                    "placement": placed[task],
                }
                for task in models
            },
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
