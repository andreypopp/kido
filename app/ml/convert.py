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

from eval import (
    COMPUTE_UNITS,
    DEFAULT_COMPUTE_UNITS,
    SHAPES,
    CoreML,
    compute_unit,
    padded,
    shape_for,
    synthetic_prompt,
    tokenize,
)
from render import file_hash, read_jsonl
from runtime import FUNCTIONS, PACKAGE, chosen_checkpoint
from validate import example

UNITS = (
    ("CPU_AND_GPU", "gpu"),
    ("ALL", "all"),
    ("CPU_AND_NE", "ane"),
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


def build(model_path: Path, precision, functions_dir: Path):
    tokenizer = AutoTokenizer.from_pretrained(model_path)
    reference = AutoModelForTokenClassification.from_pretrained(
        model_path, attn_implementation="eager"
    ).eval()
    wrapped_model = AutoModelForTokenClassification.from_pretrained(
        model_path, attn_implementation="eager"
    ).eval()
    wrapper = PaddedTagger(wrapped_model).eval()
    if functions_dir.exists():
        shutil.rmtree(functions_dir)
    functions_dir.mkdir(parents=True)
    functions = []
    for shape in SHAPES:
        input_ids = torch.randint(0, 1000, (1, shape), dtype=torch.long)
        attention_mask = torch.ones((1, shape), dtype=torch.long)
        attention_mask[0, -1] = 0
        traced = torch.jit.trace(wrapper, (input_ids, attention_mask), strict=False)
        package = functions_dir / f"shape_{shape}.mlpackage"
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
            compute_precision=precision,
            minimum_deployment_target=ct.target.macOS15,
        )
        mlmodel.save(str(package))
        functions.append((shape, package))
    return tokenizer, reference, wrapper, functions


def multifunction(functions, output: Path) -> None:
    descriptor = ct.utils.MultiFunctionDescriptor()
    for shape, package in functions:
        descriptor.add_function(
            model_path=str(package),
            src_function_name="main",
            target_function_name=f"shape_{shape}",
        )
    descriptor.default_function_name = "shape_1024"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        shutil.rmtree(output)
    ct.utils.save_multifunction(descriptor, str(output))


def logits_torch(model, ids: np.ndarray, mask: np.ndarray) -> np.ndarray:
    with torch.no_grad():
        output = model(
            input_ids=torch.tensor(ids, dtype=torch.long),
            attention_mask=torch.tensor(mask, dtype=torch.long),
        )
    logits = output.logits if hasattr(output, "logits") else output
    return logits.numpy()[0]


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
        "tokens": int(valid.sum()),
    }


def buckets(
    tokenizer, path: Path, bold: bool
) -> tuple[dict[int, list[tuple[np.ndarray, np.ndarray]]], dict[int, int]]:
    groups: dict[int, list[tuple[np.ndarray, np.ndarray]]] = {shape: [] for shape in SHAPES}
    for record in read_jsonl(path):
        prompt, _ = example(record, bold)
        ids, mask, _ = tokenize(tokenizer, prompt, None)
        shape = shape_for(len(ids))
        groups[shape].append(
            padded(ids[:shape], mask[:shape], shape, tokenizer.pad_token_id)
        )
    real = {shape: len(items) for shape, items in groups.items()}
    for target in (1600, 2000):
        prompt = synthetic_prompt(tokenizer, target)
        ids, mask, _ = tokenize(tokenizer, prompt, SHAPES[-1])
        groups[SHAPES[-1]].append(
            padded(ids, mask, SHAPES[-1], tokenizer.pad_token_id)
        )
    return groups, real


def aggregate(values: list[dict[str, float]]) -> dict[str, float]:
    if not values:
        return {}
    tokens = sum(value["tokens"] for value in values)
    return {
        "records": len(values),
        "tokens": tokens,
        "argmax_agreement": sum(
            value["argmax_agreement"] * value["tokens"] for value in values
        )
        / tokens,
        "kl": sum(value["kl"] * value["tokens"] for value in values) / tokens,
        "kl_example_mean": float(np.mean([value["kl"] for value in values])),
        "max_abs_diff": max(value["max_abs_diff"] for value in values),
    }


def check_logits(reference, wrapper, package: Path, groups, tokenizer, real):
    core = CoreML(package, DEFAULT_COMPUTE_UNITS, tokenizer.pad_token_id)
    wrapper_result: dict[str, object] = {}
    logits_result: dict[str, object] = {}
    synthetic: dict[str, dict[str, float]] = {}
    per_function = []
    for shape, examples in groups.items():
        wrapper_values = []
        values = []
        for ids, mask in examples:
            expected = logits_torch(reference, ids, mask)
            wrapper_values.append(compare(expected, logits_torch(wrapper, ids, mask), mask))
            values.append(compare(expected, core.predict(shape, ids, mask), mask))
        if wrapper_values:
            wrapper_result[str(shape)] = aggregate(wrapper_values)
        if values:
            logits_result[str(shape)] = {
                **aggregate(values),
                "real_records": real[shape],
            }
            per_function.extend(values)
        if shape == SHAPES[-1] and real[shape] == 0:
            for target, value in zip((1600, 2000), values, strict=True):
                synthetic[str(target)] = {
                    key: value[key]
                    for key in ("argmax_agreement", "kl", "max_abs_diff", "tokens")
                }
    logits = {
        "compute_units": COMPUTE_UNITS[DEFAULT_COMPUTE_UNITS],
        "functions": logits_result,
        "overall": aggregate(per_function),
        "synthetic": synthetic,
        "fp16_meets_threshold": all(
            value["argmax_agreement"] >= 0.999 for value in logits_result.values()
        ),
    }
    return wrapper_result, logits


def device_name(usage) -> str:
    if usage is None:
        return "const"
    return (
        type(usage.preferred_compute_device)
        .__name__.replace("ML", "")
        .replace("ComputeDevice", "")
    )


def op_placement(path: Path, units) -> dict[str, dict[str, dict[str, int]]]:
    directory = tempfile.mkdtemp(prefix="paragraph-compiled-", dir="/tmp")
    compiled = ct.utils.compile_model(str(path), str(Path(directory) / "model.mlmodelc"))
    result: dict[str, dict[str, dict[str, int]]] = {}
    for name, unit_name in units:
        plan = MLComputePlan.load_from_path(compiled, compute_units=compute_unit(unit_name))
        counts: dict[str, dict[str, int]] = {}
        for function_name, function in plan.model_structure.program.functions.items():
            per_device: dict[str, int] = {}
            for operation in function.block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
                device = device_name(usage)
                per_device[device] = per_device.get(device, 0) + 1
            counts[function_name] = per_device
        result[name] = counts
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--output", type=Path, default=PACKAGE)
    parser.add_argument("--eval", type=Path, default=Path("data/eval.jsonl"))
    parser.add_argument("--metadata", type=Path, default=Path("data/convert.json"))
    args = parser.parse_args(argv)
    checkpoint = args.model or chosen_checkpoint()
    training = json.loads((checkpoint / "training.json").read_text())
    bold = bool(training["bold"])
    tokenizer, reference, wrapper, functions = build(
        checkpoint, ct.precision.FLOAT16, FUNCTIONS
    )
    multifunction(functions, args.output)
    result: dict[str, object] = {
        "checkpoint": {
            "path": str(checkpoint),
            "hash": file_hash(checkpoint / "model.safetensors"),
            "bytes": (checkpoint / "model.safetensors").stat().st_size,
        },
        "package": {
            "path": str(args.output),
            "hash": package_hash(args.output),
            "bytes": package_size(args.output),
            "functions": [
                {"name": f"shape_{shape}", "shape": shape} for shape in SHAPES
            ],
            "default_function": "shape_1024",
            "compute_units": COMPUTE_UNITS[DEFAULT_COMPUTE_UNITS],
            "compute_precision": "FLOAT16",
            "coremltools": ct.__version__,
            "torch": torch.__version__,
            "deployment_target": "macOS15",
        },
        "training": {
            "max_length": training["max_length"],
            "bold": training["bold"],
            "seed": training["seed"],
        },
        "placement": {},
    }
    for shape, package in functions:
        for unit, counts in op_placement(package, UNITS).items():
            result["placement"].setdefault(unit, {})[f"shape_{shape}"] = counts["main"]
    groups, real = buckets(tokenizer, args.eval, bold)
    result["wrapper_vs_hf"], result["logits"] = check_logits(
        reference, wrapper, args.output, groups, tokenizer, real
    )
    args.metadata.parent.mkdir(parents=True, exist_ok=True)
    args.metadata.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
