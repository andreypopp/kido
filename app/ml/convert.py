"""Convert the selected taggers to Core ML: `uv run convert`.

Each task is one multifunction fp16 package with a fixed-shape function for each length, plus
its compiled model. The output directory is self-contained: the tokenizer files and settings.json
hold what a reader needs, with the digests of the checkpoint, the packages and the source code.
"""

import argparse
import hashlib
import logging
import shutil
import sys
import types
import warnings
from pathlib import Path

import numpy as np
import torch

from jsonl import DATA, file_digest, sha256, write_json
from model import CHECKPOINT, TASKS, load, load_tokenizer
from tagging import CLOSING, MAX_TOKENS, OPENING, OPTION_TRAILING
from units import DECISION

logging.getLogger("coremltools").setLevel(logging.ERROR)

import coremltools as ct  # noqa: E402

COREML = DATA / "coreml"
SHAPES = {"question": (64, 128, 256, 512), "option": (32, 64, 128, 512)}
MASKED = -10000.0


def padded_attention(self, hidden_states, attention_mask=None, **_):
    """Attention with fixed shapes: the rotary angles and the sliding window are constants of the
    length, and the padding mask is an input. The tracer cannot follow the shape arithmetic of
    the original."""
    qkv = self.Wqkv(hidden_states).view(1, self.length, 3, -1, self.head_dim)
    query, key, value = (x.transpose(1, 2) for x in qkv.unbind(dim=-3))
    half = self.head_dim // 2

    def rotate(x):
        return x * self.cos + torch.cat((-x[..., half:], x[..., :half]), dim=-1) * self.sin

    scores = torch.matmul(rotate(query), rotate(key).transpose(2, 3)) * (self.head_dim**-0.5)
    scores = scores + (1.0 - attention_mask.to(scores.dtype))[:, None, None, :] * MASKED
    if self.sliding_window is not None:
        scores = scores + self.window
    weights = torch.softmax(scores, dim=-1)
    output = torch.matmul(weights, value).transpose(1, 2).reshape(1, self.length, -1)
    return self.Wo(output), None


class Padded(torch.nn.Module):
    """A token classifier of one fixed length whose padding mask is an input."""

    def __init__(self, tagger, length: int) -> None:
        super().__init__()
        self.tagger = tagger
        encoder = tagger.model
        probe = torch.zeros(1, length, 1)
        positions = torch.arange(length).unsqueeze(0)
        with torch.no_grad():
            angles = {
                kind: encoder.rotary_emb(probe, positions, kind)
                for kind in set(encoder.config.layer_types)
            }
        near = (positions.T - positions).abs() < tagger.config.sliding_window + 1
        window = torch.where(near, 0.0, MASKED)
        for layer in encoder.layers:
            cos, sin = angles[layer.attention_type]
            attn = layer.attn
            attn.length, attn.cos, attn.sin, attn.window = (
                length,
                cos[:, None],
                sin[:, None],
                window,
            )
            attn.forward = types.MethodType(padded_attention, attn)

    def forward(self, input_ids, attention_mask):
        encoder = self.tagger.model
        hidden = encoder.embeddings(input_ids=input_ids)
        for layer in encoder.layers:
            hidden = layer(hidden, attention_mask=attention_mask)
        return self.tagger.classifier(self.tagger.head(encoder.final_norm(hidden)))


def directory_digest(path: Path) -> str:
    digest = hashlib.sha256()
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(item.relative_to(path).as_posix().encode())
        digest.update(item.read_bytes())
    return digest.hexdigest()[:16]


def source_digest() -> str:
    sources = sorted(Path(__file__).parent.glob("*.py"))
    return sha256("".join(f"{p.name}:{sha256(p.read_text())}\n" for p in sources))


def convert_task(tagger, task: str, output: Path, scratch: Path) -> None:
    descriptor = ct.utils.MultiFunctionDescriptor()
    with warnings.catch_warnings():
        # external: torch.jit.trace is the only tracer that coremltools 9 converts, and its
        # converter passes warn about values that they handle
        warnings.simplefilter("ignore")
        for shape in SHAPES[task]:
            wrapper = Padded(tagger, shape).eval()
            ids = torch.randint(0, 1000, (1, shape), dtype=torch.long)
            mask = torch.ones((1, shape), dtype=torch.long)
            mask[0, -1] = 0
            traced = torch.jit.trace(wrapper, (ids, mask), strict=False)
            package = scratch / f"{task}-{shape}.mlpackage"
            ct.convert(
                traced,
                inputs=[
                    ct.TensorType(name=name, shape=[1, shape], dtype=np.int32)
                    for name in ("input_ids", "attention_mask")
                ],
                outputs=[ct.TensorType(name="logits")],
                convert_to="mlprogram",
                compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.macOS15,
            ).save(str(package))
            descriptor.add_function(str(package), "main", f"shape_{shape}")
        descriptor.default_function_name = f"shape_{SHAPES[task][0]}"
        target = output / f"{task}.mlpackage"
        ct.utils.save_multifunction(descriptor, str(target))
        ct.utils.compile_model(str(target), str(output / f"{task}.mlmodelc"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=CHECKPOINT)
    parser.add_argument("--output", type=Path, default=COREML)
    args = parser.parse_args(argv)
    if args.output.exists():
        print(f"convert: {args.output} exists", file=sys.stderr)
        return 1
    scratch = args.output.with_name(args.output.name + "-scratch")
    scratch.mkdir(parents=True)
    args.output.mkdir(parents=True)
    for task, tagger in load(args.model).items():
        convert_task(tagger, task, args.output, scratch)
    shutil.rmtree(scratch)
    tokenizer = load_tokenizer(args.model)
    tokenizer.save_pretrained(args.output)
    write_json(
        args.output / "settings.json",
        {
            "shapes": {task: list(shapes) for task, shapes in SHAPES.items()},
            "pad_token_id": tokenizer.pad_token_id,
            "tags": {"O": 0, "BEGIN": 1, "INSIDE": 2},
            "max_tokens": MAX_TOKENS,
            "trim": {"closing": CLOSING, "opening": OPENING, "option_trailing": OPTION_TRAILING},
            "decision": {"pattern": DECISION.pattern, "flags": "i"},
            "precision": "float16",
            "coremltools": ct.__version__,
            "torch": torch.__version__,
            "digests": {
                "source": source_digest(),
                "checkpoint": {
                    task: file_digest(args.model / task / "model.safetensors") for task in TASKS
                },
                "packages": {
                    task: directory_digest(args.output / f"{task}.mlpackage") for task in TASKS
                },
            },
        },
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
