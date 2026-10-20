"""Format the tracked manifest as the phase 3 conversion and benchmark report."""

from __future__ import annotations

import json
from pathlib import Path

from report import table


def placement_rows(placement: dict[str, object]) -> list[list[object]]:
    rows = []
    for unit, functions in placement.items():
        for function, devices in functions.items():
            rows.append(
                [
                    unit,
                    function,
                    ", ".join(f"{name}={value}" for name, value in sorted(devices.items())),
                    sum(devices.values()),
                ]
            )
    return rows


def logits_row(name: str, values: dict[str, object]) -> list[object]:
    return [
        name,
        values.get("records"),
        values.get("tokens"),
        round(values.get("argmax_agreement", 0), 6),
        f"{values.get('kl', 0):.3e}",
        f"{values.get('kl_example_mean', 0):.3e}",
        round(values.get("max_abs_diff", 0), 4),
    ]


def main() -> int:
    manifest = json.loads(Path("manifest.json").read_text())
    phase = manifest.get("phase3") or {}
    convert = phase.get("convert") or {}
    tokens = phase.get("token-counts") or {}
    parity = phase.get("parity") or {}
    bench = phase.get("bench") or {}
    palette = phase.get("palettize") or {}
    checkpoint = convert.get("checkpoint") or {}
    package = convert.get("package") or {}
    logits = convert.get("logits") or {}
    lines = ["# Paragraph tagger, phase 3", ""]
    lines += [
        "This report gives counts, hashes, metrics and op placement. It contains",
        "no transcript text.",
        "",
    ]

    lines += ["## Checkpoint and package", ""]
    lines += table(
        [
            ["checkpoint", checkpoint.get("path")],
            ["checkpoint hash", checkpoint.get("hash")],
            ["checkpoint bytes", checkpoint.get("bytes")],
            ["package", package.get("path")],
            ["package hash", package.get("hash")],
            ["package bytes", package.get("bytes")],
            ["package MB", round(package.get("bytes", 0) / 1e6, 1)],
            ["default function", package.get("default_function")],
            ["default compute units", package.get("compute_units")],
            ["compute precision", package.get("compute_precision")],
            ["coremltools", package.get("coremltools")],
            ["torch", package.get("torch")],
            ["deployment target", package.get("deployment_target")],
            ["functions", ", ".join(item["name"] for item in package.get("functions", []))],
        ],
        ["measure", "value"],
    )
    lines += [""]

    lines += ["## Op placement", ""]
    lines += table(
        placement_rows(convert.get("placement") or {}),
        ["compute units", "function", "devices", "ops"],
    )
    lines += [
        "",
        "`const` is a constant operation with no compute device.",
        "",
    ]

    lines += ["## Token distribution", ""]
    rows = []
    for name, values in (tokens.get("splits") or {}).items():
        buckets = values.get("buckets", {})
        rows.append(
            [
                name,
                values.get("examples"),
                buckets.get("512"),
                buckets.get("1024"),
                buckets.get("2048"),
                values.get("truncated"),
                values.get("min"),
                values.get("median"),
                values.get("max"),
            ]
        )
    lines += table(
        rows,
        ["split", "examples", "512", "1024", "2048", "over max length", "min", "median", "max"],
    )
    lines += [""]

    lines += ["## Logits against PyTorch", ""]
    rows = [
        logits_row(name, values)
        for name, values in (logits.get("functions") or {}).items()
    ]
    rows.append(logits_row("overall", logits.get("overall") or {}))
    lines += table(
        rows,
        ["function", "records", "tokens", "argmax agreement", "KL", "KL mean", "max abs diff"],
    )
    lines += ["", "Synthetic 2,048 inputs:", ""]
    lines += table(
        [
            [
                name,
                values.get("tokens"),
                round(values.get("argmax_agreement", 0), 6),
                f"{values.get('kl', 0):.3e}",
            ]
            for name, values in (logits.get("synthetic") or {}).items()
        ],
        ["tokens", "valid", "argmax agreement", "KL"],
    )
    lines += [
        "",
        "The fp16 threshold (argmax agreement at least 0.999) is "
        + (
            "met, so no fp32 measurement was necessary."
            if logits.get("fp16_meets_threshold")
            else "missed."
        ),
        "",
    ]

    lines += ["## Metric parity", ""]
    rows = []
    for name, values in (parity.get("parts") or {}).items():
        rows.append(
            [
                name,
                values["examples"],
                round(values["torch"]["question_f1"], 4),
                round(values["coreml"]["question_f1"], 4),
                f"{values['delta']['question_f1']:+.4f}",
                round(values["torch"]["option_f1"], 4),
                round(values["coreml"]["option_f1"], 4),
                f"{values['delta']['option_f1']:+.4f}",
                round(values["torch"]["option_visible_f1"], 4),
                round(values["coreml"]["option_visible_f1"], 4),
                f"{values['delta']['option_visible_f1']:+.4f}",
            ]
        )
    lines += table(
        rows,
        [
            "part",
            "examples",
            "q F1 torch",
            "q F1 coreml",
            "delta",
            "opt F1 torch",
            "opt F1 coreml",
            "delta",
            "app F1 torch",
            "app F1 coreml",
            "delta",
        ],
    )
    lines += [
        "",
        f"Worst absolute difference {parity.get('worst_delta', 0):.4f}; "
        f"target 0.005: {'pass' if parity.get('pass') else 'fail'}.",
        "",
    ]

    lines += ["## Benchmarks", ""]
    rows = []
    for row in bench.get("rows", []):
        rows.append(
            [
                row["unit"],
                row["shape"],
                row["records"],
                row["tokens"],
                round(row["compile_load_ms"], 1),
                round(row["load_ms"], 1),
                round(row["p50_ms"], 2),
                round(row["p95_ms"], 2),
            ]
        )
    lines += table(
        rows,
        [
            "compute units",
            "shape",
            "eval records",
            "tokens",
            "compile+load ms",
            "load ms",
            "p50 ms",
            "p95 ms",
        ],
    )
    lines += [
        "",
        "Each row runs in a fresh process. A shape with no eval record uses a",
        "synthetic prompt of 1,600 tokens; the records column is 0.",
        "",
    ]

    lines += ["## Palettisation", ""]
    bytes_fp16 = palette.get("package", {}).get("fp16_bytes")
    bytes_8bit = palette.get("package", {}).get("bytes")
    real = palette.get("real") or {}
    lines += table(
        [
            ["8-bit bytes", bytes_8bit],
            ["8-bit MB", round((bytes_8bit or 0) / 1e6, 1) if bytes_8bit else None],
            ["fp16 bytes", bytes_fp16],
            ["fp16 MB", round((bytes_fp16 or 0) / 1e6, 1) if bytes_fp16 else None],
            [
                "functions",
                ", ".join(
                    str(item)
                    for item in palette.get("package", {}).get("functions", [])
                ),
            ],
            [
                "real option exact F1",
                round(real.get("palettized", {}).get("option_f1", 0), 4),
            ],
            [
                "real app-visible option F1",
                round(real.get("palettized", {}).get("option_visible_f1", 0), 4),
            ],
            ["delta option F1", round(real.get("delta", {}).get("option_f1", 0), 4)],
            [
                "delta app-visible option F1",
                round(real.get("delta", {}).get("option_visible_f1", 0), 4),
            ],
            ["within parity", palette.get("within_parity")],
            ["default package", palette.get("default_package")],
        ],
        ["measure", "value"],
    )
    lines += [
        "",
        "8-bit palettisation is within the parity target, but it is not the",
        "default: the fp16 package already fits and no size pressure exists.",
        "",
    ]
    Path("data/phase3-report.md").write_text("\n".join(lines) + "\n")
    print(
        json.dumps(
            {
                "package_bytes": package.get("bytes"),
                "package_hash": package.get("hash"),
                "argmax_agreement": (logits.get("overall") or {}).get("argmax_agreement"),
                "parity_worst": parity.get("worst_delta"),
                "palettized_bytes": bytes_8bit,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
