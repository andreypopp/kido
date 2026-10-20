"""Convert the Ettin tagger to a fixed-shape Core ML multifunction model."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
import types
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from coremltools.models.compute_plan import MLComputePlan
from transformers import AutoModelForTokenClassification, AutoTokenizer
from transformers.models.modernbert.modeling_modernbert import apply_rotary_pos_emb

from render import read_jsonl

SHAPES = [512, 1024, 2048]
UNITS = (
    ("CPU_AND_GPU", ct.ComputeUnit.CPU_AND_GPU),
    ("CPU_AND_NE", ct.ComputeUnit.CPU_AND_NE),
    ("ALL", ct.ComputeUnit.ALL),
)


def padded_attention(self, hidden_states, position_embeddings=None, attention_mask=None, **_):
    shape = hidden_states.shape[:-1]
    qkv = self.Wqkv(hidden_states).view(*shape, 3, -1, self.head_dim)
    query, key, value = qkv.unbind(dim=-3)
    query = query.transpose(1, 2)
    key = key.transpose(1, 2)
    value = value.transpose(1, 2)
    cos, sin = position_embeddings
    query, key = apply_rotary_pos_emb(query, key, cos, sin, unsqueeze_dim=1)
    scores = torch.matmul(query, key.transpose(2, 3)) * (self.head_dim**-0.5)
    padding = (1.0 - attention_mask.to(hidden_states.dtype))[:, None, None, :] * -10000.0
    scores = scores + padding
    if self.attention_type == "sliding_attention":
        length = hidden_states.shape[1]
        indexes = torch.arange(length, device=hidden_states.device)
        distance = (indexes[:, None] - indexes[None, :]).abs()
        zero = torch.zeros((), dtype=hidden_states.dtype, device=hidden_states.device)
        off = torch.full((), -10000.0, dtype=hidden_states.dtype, device=hidden_states.device)
        scores = scores + torch.where(distance <= 64, zero, off)
    weights = torch.softmax(scores, dim=-1, dtype=torch.float32).to(query.dtype)
    output = torch.matmul(weights, value).transpose(1, 2).contiguous().reshape(*shape, -1)
    return self.out_drop(self.Wo(output)), None


class PaddedTagger(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
        for layer in model.model.layers:
            layer.attn.attention_type = layer.attention_type
            layer.attn.forward = types.MethodType(padded_attention, layer.attn)

    def forward(self, input_ids, attention_mask):
        model = self.model
        hidden = model.model.embeddings(input_ids)
        length = hidden.shape[1]
        positions = torch.arange(length, device=hidden.device).unsqueeze(0)
        embeddings = {
            layer_type: model.model.rotary_emb(hidden, positions, layer_type)
            for layer_type in set(model.config.layer_types)
        }
        for layer in model.model.layers:
            hidden = layer(
                hidden,
                attention_mask=attention_mask,
                position_embeddings=embeddings[layer.attention_type],
            )
        hidden = model.model.final_norm(hidden)
        hidden = model.head(hidden)
        hidden = model.drop(hidden)
        return model.classifier(hidden)


def package_size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def package_hash(path: Path) -> str:
    digest = hashlib.sha256()
    for item in sorted(path.rglob("*")):
        if item.is_file():
            digest.update(item.relative_to(path).as_posix().encode())
            digest.update(item.read_bytes())
    return digest.hexdigest()


def encode_padded(tokenizer, prompt: str, shape: int) -> tuple[np.ndarray, np.ndarray]:
    encoded = tokenizer(
        prompt,
        max_length=shape,
        truncation=True,
        add_special_tokens=True,
    )
    ids = encoded["input_ids"]
    mask = encoded["attention_mask"]
    pad = shape - len(ids)
    return (
        np.array([ids + [tokenizer.pad_token_id] * pad], dtype=np.int32),
        np.array([mask + [0] * pad], dtype=np.int32),
    )


def convert(args: argparse.Namespace):
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    reference = AutoModelForTokenClassification.from_pretrained(
        args.model, attn_implementation="eager"
    ).eval()
    wrapped_model = AutoModelForTokenClassification.from_pretrained(
        args.model, attn_implementation="eager"
    ).eval()
    wrapper = PaddedTagger(wrapped_model).eval()
    temporary = Path(tempfile.mkdtemp(prefix="paragraph-tagger-", dir="/tmp"))
    functions = []
    for shape in args.shapes:
        input_ids = torch.randint(0, 1000, (1, shape), dtype=torch.long)
        attention_mask = torch.ones((1, shape), dtype=torch.long)
        attention_mask[0, -1] = 0
        traced = torch.jit.trace(wrapper, (input_ids, attention_mask), strict=False)
        package = temporary / f"shape_{shape}.mlpackage"
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(
                    name="input_ids",
                    shape=[1, shape],
                    dtype=ct.converters.mil.mil.types.int32,
                ),
                ct.TensorType(
                    name="attention_mask",
                    shape=[1, shape],
                    dtype=ct.converters.mil.mil.types.int32,
                ),
            ],
            outputs=[ct.TensorType(name="logits")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS15,
        )
        mlmodel.save(str(package))
        functions.append((shape, package))
    descriptor = ct.utils.MultiFunctionDescriptor()
    for shape, package in functions:
        descriptor.add_function(
            model_path=str(package),
            src_function_name="main",
            target_function_name=f"shape_{shape}",
        )
    descriptor.default_function_name = "shape_1024"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        shutil.rmtree(args.output)
    ct.utils.save_multifunction(descriptor, str(args.output))
    return tokenizer, reference, wrapper, functions, temporary


def logits_torch(model, ids: np.ndarray, mask: np.ndarray) -> np.ndarray:
    with torch.no_grad():
        output = model(
            input_ids=torch.tensor(ids, dtype=torch.long),
            attention_mask=torch.tensor(mask, dtype=torch.long),
        )
    logits = output.logits if hasattr(output, "logits") else output
    return logits.numpy()[0]


def logits_coreml(model, ids: np.ndarray, mask: np.ndarray) -> np.ndarray:
    prediction = model.predict(
        {"input_ids": ids.astype(np.int32), "attention_mask": mask.astype(np.int32)}
    )
    return np.asarray(prediction["logits"])[0]


def compare(reference: np.ndarray, candidate: np.ndarray, mask: np.ndarray) -> dict[str, float]:
    valid = mask.reshape(-1).astype(bool)
    first = torch.from_numpy(reference[valid].astype(np.float32))
    second = torch.from_numpy(candidate[valid].astype(np.float32))
    log_first = torch.log_softmax(first, dim=-1)
    log_second = torch.log_softmax(second, dim=-1)
    kl = torch.nn.functional.kl_div(log_second, log_first.exp(), reduction="batchmean")
    return {
        "kl": float(kl.item()),
        "max_abs_diff": float(np.abs(reference[valid] - candidate[valid]).max()),
        "argmax_agreement": float(
            (reference[valid].argmax(axis=-1) == candidate[valid].argmax(axis=-1)).mean()
        ),
    }


def buckets(tokenizer, path: Path, shapes: list[int]):
    groups: dict[int, list[tuple[np.ndarray, np.ndarray]]] = {shape: [] for shape in shapes}
    for record in read_jsonl(path):
        length = len(tokenizer(str(record["prompt"]), add_special_tokens=True)["input_ids"])
        shape = next((value for value in shapes if length <= value), shapes[-1])
        groups[shape].append(encode_padded(tokenizer, str(record["prompt"]), shape))
    return groups


def op_placement(path: Path, units) -> dict[str, dict[str, dict[str, int]]]:
    directory = tempfile.mkdtemp(prefix="paragraph-compiled-", dir="/tmp")
    compiled = ct.utils.compile_model(str(path), str(Path(directory) / "model.mlmodelc"))
    result: dict[str, dict[str, dict[str, int]]] = {}
    for name, unit in units:
        plan = MLComputePlan.load_from_path(compiled, compute_units=unit)
        counts: dict[str, dict[str, int]] = {}
        for function_name, function in plan.model_structure.program.functions.items():
            per_device: dict[str, int] = {}
            for operation in function.block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
                if usage is None:
                    device_name = "unknown"
                else:
                    device_name = (
                        type(usage.preferred_compute_device)
                        .__name__.replace("ML", "")
                        .replace("ComputeDevice", "")
                    )
                per_device[device_name] = per_device.get(device_name, 0) + 1
            counts[function_name] = per_device
        result[name] = counts
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=Path("data/output/curve-100-nobold-s2"))
    parser.add_argument(
        "--output", type=Path, default=Path("data/output/ParagraphTagger.mlpackage")
    )
    parser.add_argument("--eval", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--shapes", type=int, nargs="+", default=SHAPES)
    parser.add_argument("--palettize", action="store_true")
    args = parser.parse_args(argv)
    tokenizer, reference, wrapper, functions, temporary = convert(args)
    groups = buckets(tokenizer, args.eval, args.shapes)
    result: dict[str, object] = {
        "path": str(args.output),
        "hash": package_hash(args.output),
        "fp16_bytes": package_size(args.output),
        "shapes": args.shapes,
        "compute_units": {},
        "wrapper_vs_hf": {},
    }
    for shape in args.shapes:
        values = []
        for ids, mask in groups[shape]:
            values.append(
                compare(
                    logits_torch(reference, ids, mask),
                    logits_torch(wrapper, ids, mask),
                    mask,
                )
            )
        result["wrapper_vs_hf"][str(shape)] = {
            key: float(np.mean([value[key] for value in values])) for key in values[0]
        } if values else None
    for name, unit in UNITS:
        per_shape = {}
        for shape in args.shapes:
            if not groups[shape]:
                per_shape[str(shape)] = None
                continue
            model = ct.models.MLModel(
                str(args.output), compute_units=unit, function_name=f"shape_{shape}"
            )
            values = [
                compare(logits_torch(reference, ids, mask), logits_coreml(model, ids, mask), mask)
                for ids, mask in groups[shape]
            ]
            per_shape[str(shape)] = {
                "records": len(values),
                **{
                    key: float(np.mean([value[key] for value in values]))
                    for key in values[0]
                },
            }
        result["compute_units"][name] = per_shape
    result["ops"] = {
        str(shape): op_placement(package, UNITS) for shape, package in functions
    }
    if args.palettize:
        try:
            from coremltools.optimize.coreml import (
                OpPalettizerConfig,
                OptimizationConfig,
                palettize_weights,
            )

            config = OptimizationConfig(
                global_config=OpPalettizerConfig(nbits=8, mode="kmeans")
            )
            model = ct.models.MLModel(str(args.output))
            palettized = palettize_weights(model, config)
            palette_path = args.output.with_name("ParagraphTagger-8bit.mlpackage")
            palettized.save(str(palette_path))
            result["palettized_bytes"] = package_size(palette_path)
        except Exception as error:  # noqa: BLE001 - the report needs the reason
            shape, package = functions[0]
            try:
                from coremltools.optimize.coreml import (
                    OpPalettizerConfig,
                    OptimizationConfig,
                    palettize_weights,
                )

                model = ct.models.MLModel(str(package))
                palettized = palettize_weights(
                    model,
                    OptimizationConfig(
                        global_config=OpPalettizerConfig(nbits=8, mode="kmeans")
                    ),
                )
                palette_path = args.output.with_name("ParagraphTagger-8bit.mlpackage")
                palettized.save(str(palette_path))
                result["palettized_bytes"] = package_size(palette_path)
                result["palettized_scope"] = f"shape_{shape}"
            except Exception as inner:  # noqa: BLE001 - the report needs the reason
                result["palettized_bytes"] = 0
                result["palettize_error"] = f"{error}; {inner}"
    shutil.rmtree(temporary)
    Path("data/convert.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
