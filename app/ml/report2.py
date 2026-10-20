"""Format the tracked manifest as the phase 2 training and eval report."""

from __future__ import annotations

import json
from pathlib import Path

from report import agreement_rows, part_rows, table


def mean(group: dict[str, object], part: str, name: str) -> str:
    value = group["parts"][part][name]
    if group["count"] == 1:
        return f"{value['mean']:.3f}"
    return f"{value['mean']:.3f} ± {value['sd']:.3f}"


def class_mean(group: dict[str, object], part: str, name: str, count: str) -> str:
    if not group["parts"][part][count]["mean"]:
        return "n/a"
    return mean(group, part, name)


def main() -> int:
    manifest = json.loads(Path("manifest.json").read_text())
    label = manifest.get("label_train") or {}
    flash = manifest.get("label_train_flash") or {}
    agreement = manifest.get("train_agreement") or {}
    split = manifest.get("split") or {}
    sweep = manifest.get("sweep") or {}
    seeds = manifest.get("train_seeds") or {}
    experiment = manifest.get("experiment") or {}
    summary = manifest.get("eval_summary") or {}
    errors = manifest.get("errors") or {}
    ask_overlap = manifest.get("ask_overlap") or {}
    spend = manifest.get("spend") or {}
    checkpoint = manifest.get("checkpoint") or {}
    decisions = seeds.get("decisions") or experiment.get("decisions") or {}
    runs = seeds.get("runs", [])
    groups = summary.get("groups") or {}
    lines = ["# Paragraph tagger, phase 2", ""]
    lines += [
        "This report gives counts, metrics, configuration and hashes. It contains",
        "no transcript text.",
        "",
        "Targets: question false-positive rate on the real eval part below 2%,",
        "and real-part option exact F1 as the main user-facing number.",
        "",
    ]

    lines += ["## Relabelled training data", ""]
    lines += table(
        [
            ["model", label.get("model", {}).get("version")],
            ["samples", label.get("samples")],
            ["attempted", label.get("attempted")],
            ["labelled", label.get("labelled")],
            ["dropped", label.get("dropped")],
            ["phase 2 labelling spend usd", round(float(spend.get("phase2", 0)), 4)],
            ["cumulative spend usd", round(float(spend.get("total", 0)), 4)],
        ],
        ["measure", "value"],
    )
    lines += ["", "Drop classes:", ""]
    lines += table(
        [[name, value] for name, value in sorted(label.get("drop_classes", {}).items())],
        ["class", "errors"],
    )
    lines += ["", "Flash and v4-pro agreement on all labelled train families:", ""]
    lines += table(
        agreement_rows(
            {
                "flash labels": flash.get("labelled"),
                "compared families": agreement.get("families"),
                "missing labels": agreement.get("missing"),
                "invalid labels": agreement.get("invalid"),
                "line classes agree": agreement.get("class_agreement"),
                "question unit agrees": agreement.get("unit_agreement"),
                "option sets exact": agreement.get("options_exact"),
                "v4-pro has more inline options": agreement.get("v4_more_inline"),
                "v4-pro has more list options": agreement.get("v4_more_list"),
                "flash has more inline options": agreement.get("flash_more_inline"),
                "flash has more list options": agreement.get("flash_more_list"),
            }
        ),
        ["measure", "value"],
    )
    lines += [
        "",
        "The flash labels are a recorded comparison only. Training uses the",
        "v4-pro labels.",
        "",
    ]

    lines += ["## Split counts", ""]
    lines += table(
        part_rows(split),
        [
            "split",
            "part",
            "examples",
            "positive",
            "negative",
            "option spans",
            "option kinds",
            "families",
            "sessions",
        ],
    )
    dev = split.get("dev", {})
    lines += [
        "",
        "Dev: "
        + f"{dev.get('examples')} examples, {dev.get('positive')} positive, "
        + f"{dev.get('option_spans')} option spans ({dev.get('option_spans_real')} real).",
        "",
    ]

    lines += ["## Development sweep", ""]
    rows = []
    for row in sweep.get("rows", []):
        real = row["real"]
        synthetic = row["synthetic"]
        rows.append(
            [
                row["epochs"],
                row["learning_rate"],
                round(real["option_f1"], 3),
                round(real["question_f1"], 3),
                round(real["question_fpr"], 4),
                round(real["unit_accuracy"], 3),
                round(synthetic["option_f1"], 3),
                round(synthetic["question_f1"], 3),
                round(synthetic["question_fpr"], 4),
            ]
        )
    lines += table(
        rows,
        [
            "epochs",
            "lr",
            "real opt F1",
            "real q F1",
            "real q FPR",
            "real unit",
            "synth opt F1",
            "synth q F1",
            "synth q FPR",
        ],
    )
    best = sweep.get("best") or {}
    config = seeds.get("config") or {}
    lines += [
        "",
        "Chosen on dev by real-part option exact F1, then real-part question F1,",
        "then real-part question false-positive rate: "
        f"{best.get('epochs')} epochs, learning rate {best.get('learning_rate')}.",
        "Training uses batch 16, 10% linear warmup, linear decay, max length 1024",
        "and bf16 on MPS. The sweep uses the dev split only.",
        "",
    ]

    lines += ["## Results", ""]
    for key in ("nobold", "bold"):
        group = groups.get(key)
        if not group:
            continue
        lines += [f"### {'Bold' if key == 'bold' else 'No bold'}", ""]
        rows = []
        for part in ("ask", "real", "synthetic", "union"):
            rows.append(
                [
                    part,
                    mean(group, part, "question_f1"),
                    mean(group, part, "option_precision"),
                    mean(group, part, "option_recall"),
                    mean(group, part, "option_f1"),
                    mean(group, part, "option_visible_precision"),
                    mean(group, part, "option_visible_recall"),
                    mean(group, part, "option_visible_f1"),
                    mean(group, part, "unit_accuracy"),
                    mean(group, part, "question_fpr"),
                ]
            )
        lines += table(
            rows,
            [
                "part",
                "question F1",
                "option P",
                "option R",
                "option F1",
                "app P",
                "app R",
                "app F1",
                "unit accuracy",
                "question FPR",
            ],
        )
        lines += ["", "Unit accuracy by example class:", ""]
        lines += table(
            [
                [
                    part,
                    class_mean(
                        group, part, "unit_accuracy_positive", "unit_examples_positive"
                    ),
                    class_mean(
                        group, part, "unit_accuracy_negative", "unit_examples_negative"
                    ),
                ]
                for part in ("ask", "real", "synthetic", "union")
            ],
            ["part", "positive", "negative"],
        )
        lines += [
            "",
            "Real-part option exact F1: "
            f"{mean(group, 'real', 'option_f1')}. "
            "Real-part app-visible option exact P/R/F1: "
            f"{mean(group, 'real', 'option_visible_precision')} / "
            f"{mean(group, 'real', 'option_visible_recall')} / "
            f"{mean(group, 'real', 'option_visible_f1')}.",
            "",
        ]

    lines += ["## Ask part", ""]
    lines += [
        f"{ask_overlap.get('examples')} examples. "
        f"{ask_overlap.get('shared_examples')} share "
        f"{ask_overlap.get('shared_sessions')} sessions with train, so the ask part",
        "is not session-held-out. This limits its use as an independent check.",
        "",
    ]
    ask_rows = []
    for run in runs:
        counts = (summary.get("ask_errors") or {}).get(str(run["name"]), {})
        ask_rows.append(
            [
                run["name"],
                counts.get("exact_range"),
                counts.get("boundary_errors"),
                counts.get("missed"),
                counts.get("spurious"),
                counts.get("unit_errors"),
            ]
        )
    lines += table(
        ask_rows,
        ["run", "exact", "boundary", "missed", "spurious", "unit errors"],
    )
    lines += [""]

    lines += ["## Bold A/B", ""]
    bold_runs = [run for run in runs if run["bold"]]
    plain_runs = [run for run in runs if not run["bold"]]
    bold_real = (groups.get("bold") or {}).get("parts", {}).get("real", {})
    plain_real = (groups.get("nobold") or {}).get("parts", {}).get("real", {})
    bold_option = bold_real.get("option_f1", {}).get("mean", 0.0)
    plain_option = plain_real.get("option_f1", {}).get("mean", 0.0)
    plain_sd = plain_real.get("option_f1", {}).get("sd", 0.0)
    bold_decision = decisions.get("bold") or {}
    stopped = bold_decision.get("stopped_after_seed")
    reason = bold_decision.get("reason", "")
    lines += [
        f"bold A/B: {len(bold_runs)} bold seed"
        f"{'s' if len(bold_runs) != 1 else ''} "
        f"({', '.join('s' + str(run['seed']) for run in bold_runs)}) vs "
        f"{len(plain_runs)} no-bold seeds; stopped after seed {stopped} by {reason}",
        f"(bold real-part option exact F1 {bold_option:.3f} vs no-bold "
        f"{plain_option:.3f} ± {plain_sd:.3f}); decision: no bold.",
        "",
    ]

    lines += ["## Ettin-150m", ""]
    decision_150 = decisions.get("150m") or {}
    option = plain_real.get("option_f1", {}).get("mean", 0.0)
    visible = plain_real.get("option_visible_f1", {}).get("mean", 0.0)
    fpr = plain_real.get("question_fpr", {}).get("mean", 1.0)
    lines += [
        "150m "
        + ("trained." if decision_150.get("trained") else "not trained: ")
        + str(decision_150.get("reason", "")),
        "",
        "The 32m model against the targets: real-part question FPR "
        f"{fpr:.4f} (target below 0.02), real-part option exact F1 "
        f"{option:.3f}, real-part app-visible option exact F1 {visible:.3f}.",
        "",
    ]

    lines += ["## Real-part error counts", ""]
    counts = errors.get("errors") or {}
    lines += table(
        [[name, value] for name, value in sorted(counts.items())],
        ["count", "value"],
    )
    lines += [""]

    lines += ["## Training", ""]
    lines += table(
        [
            ["base model", config.get("base_model")],
            ["epochs", config.get("epochs")],
            ["learning rate", config.get("learning_rate")],
            ["batch size", config.get("batch_size")],
            ["max length", config.get("max_length")],
            ["warmup fraction", config.get("warmup_fraction")],
            ["seeds", config.get("seeds")],
        ],
        ["measure", "value"],
    )
    lines += ["", "Per run:", ""]
    timing = []
    for run in runs:
        training = json.loads(
            (Path(str(run["output"])) / "training.json").read_text()
        )
        evaluation = json.loads(Path(str(run["eval"])).read_text())
        real = evaluation["parts"]["real"]
        timing.append(
            [
                run["name"],
                training["train_seconds"],
                training["real_tokens_per_second"],
                round(real["option"]["f1"], 3),
                round(real["token_f1"]["question"]["f1"], 3),
                round(real["question_false_positive_rate"], 4),
            ]
        )
    lines += table(
        timing,
        ["run", "train s", "real tokens/s", "real opt F1", "real q F1", "real q FPR"],
    )
    lines += [
        "",
        "Chosen checkpoint (no-bold seed 0):",
        f"`{checkpoint.get('path')}` hash `{checkpoint.get('hash')}`, "
        f"{checkpoint.get('bytes')} bytes.",
        "",
    ]
    Path("data/phase2-report.md").write_text("\n".join(lines) + "\n")
    print(
        json.dumps(
            {
                "relabelled": label.get("labelled"),
                "spend": round(float(spend.get("total", 0)), 4),
                "train": split.get("counts", {}).get("train"),
                "chosen": summary.get("chosen"),
                "real_option_f1": option,
                "real_question_fpr": fpr,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
