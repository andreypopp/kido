"""Format the tracked manifest and stage metadata as the phase 1 report."""

from __future__ import annotations

import json
from pathlib import Path

from render import read_json


def table(rows: list[list[object]], header: list[str]) -> list[str]:
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(str(value) for value in row) + " |" for row in rows]
    return lines


def main() -> int:
    manifest = json.loads(Path("manifest.json").read_text())
    render = manifest.get("render") or {}
    plan = manifest.get("session_plan") or {}
    synthetic = manifest.get("synthetic") or {}
    split = manifest.get("split") or {}
    evaluation = manifest.get("eval") or {}
    label_train = manifest.get("label_train") or {}
    label_eval = manifest.get("label_eval_real") or {}
    spend = manifest.get("spend") or {}
    sanity = manifest.get("sanity")

    lines = ["# Paragraph labelling, phase 1", ""]
    lines += [
        "This report gives counts, hashes, drops and spend. It contains no",
        "transcript text.",
        "",
    ]

    counts = render.get("counts", {})
    lines += ["## Rendered data", ""]
    lines += table(
        [
            ["examples", counts.get("examples")],
            ["distinct contexts", counts.get("contexts")],
            ["rendered contexts", counts.get("labelled_contexts")],
            [
                "examples per context",
                round(
                    float(counts.get("examples", 0))
                    / max(1, int(counts.get("contexts", 0))),
                    2,
                ),
            ],
            ["pi examples", counts.get("pi")],
            ["claude examples", counts.get("claude")],
            ["ask examples", counts.get("ask")],
            ["question-mark hover examples", counts.get("hover_question")],
            ["other hover examples", counts.get("hover_other")],
            ["sessions", counts.get("sessions")],
        ],
        ["measure", "value"],
    )
    hover_check = manifest.get("hover_check") or {}
    diagnostic = manifest.get("diagnostic") or {}
    redaction = render.get("config", {}).get("redaction", {})
    lines += [
        "",
        f"Redaction version: {redaction.get('version')}.",
        f"Rendered hash: `{counts.get('hash')}`.",
        "",
        "Hover independence check on the earlier per-hover labels: "
        f"{hover_check.get('families_with_different_labels')} of "
        f"{hover_check.get('families_with_multiple_labels')} families differed. "
        "The label prompt now sends no hover marker and labels one family once.",
        "",
    ]

    selected = plan.get("selected", {})
    planned = plan.get("counts", {})
    lines += ["## Eval selection", ""]
    lines += table(
        [
            ["selected families", len(selected.get("families", []))],
            ["selected sessions", len(selected.get("sessions", []))],
            ["question families", selected.get("question_families")],
            ["train families", planned.get("train_families")],
            ["eval variants", planned.get("eval_variants")],
            ["ask contexts", planned.get("ask")],
        ],
        ["measure", "value"],
    )
    lines += [""]

    lines += ["## Option convention", ""]
    split_norm = (split.get("counts") or {}).get("train_normalization") or {}
    eval_norm = (evaluation.get("counts") or {}).get("normalization") or {}
    lines += table(
        [
            [
                "flash",
                split_norm.get("families"),
                split_norm.get("families_changed"),
                split_norm.get("lines_changed"),
            ],
            [
                "v4-pro",
                eval_norm.get("families"),
                eval_norm.get("families_changed"),
                eval_norm.get("lines_changed"),
            ],
        ],
        ["labeller", "families", "families changed", "lines changed"],
    )
    lines += [
        "",
        "Rule: a list-marker line that holds an option is class option;",
        "an inline option stays on a question line.",
        "",
    ]

    agreement = evaluation.get("counts", {}).get("agreement", {})
    lines += ["## Labellers", ""]
    rows = []
    for name, meta in (("flash", label_train), ("v4-pro", label_eval)):
        attempted = meta.get("attempted")
        labelled = meta.get("labelled")
        dropped = meta.get("dropped")
        if name == "v4-pro" and agreement:
            attempted = agreement.get("attempted")
            labelled = agreement.get("agreed")
            dropped = int(agreement.get("disagreement", 0)) + int(
                agreement.get("invalid", 0)
            )
        rows.append(
            [
                name,
                meta.get("model", {}).get("version"),
                meta.get("samples"),
                meta.get("thinking"),
                meta.get("temperature"),
                attempted,
                labelled,
                dropped,
                meta.get("cache_hits"),
                round(float(meta.get("wall_seconds", 0)), 1),
            ]
        )
    lines += table(
        rows,
        [
            "labeller",
            "version",
            "samples",
            "thinking",
            "temperature",
            "attempted",
            "labelled",
            "dropped",
            "cache hits",
            "wall s",
        ],
    )
    lines += [
        "",
        "Thinking mode ignores temperature; a null temperature means it was not sent.",
        "",
    ]

    for name, meta in (("flash", label_train), ("v4-pro", label_eval)):
        classes = meta.get("drop_classes", {})
        attempted = max(1, int(meta.get("attempted", 0)))
        lines += [f"{name} drop classes:", ""]
        lines += table(
            [
                [key, value, round(int(value) / attempted, 4)]
                for key, value in sorted(classes.items())
            ],
            ["class", "errors", "errors per attempt"],
        )
        lines += [""]

    lines += ["## v4-pro agreement", ""]
    lines += table(
        [[key, value] for key, value in agreement.items()],
        ["measure", "value"],
    )
    lines += [""]

    lines += ["## Synthetic data", ""]
    synth = synthetic.get("counts", {})
    lines += table(
        [
            ["train", synth.get("train")],
            ["eval", synth.get("eval")],
            ["train positives", synth.get("train_positive")],
            ["eval positives", synth.get("eval_positive")],
            ["train option spans", synth.get("train_option_spans")],
            ["eval option spans", synth.get("eval_option_spans")],
            ["train option kinds", synth.get("train_option_kinds")],
            ["eval option kinds", synth.get("eval_option_kinds")],
            ["train duplicates dropped", synth.get("train_duplicates")],
            ["eval duplicates dropped", synth.get("eval_duplicates")],
        ],
        ["measure", "value"],
    )
    lines += ["", "Families:", ""]
    lines += table(
        [
            ["train", ", ".join(synthetic.get("config", {}).get("train_families", []))],
            ["eval", ", ".join(synthetic.get("config", {}).get("eval_families", []))],
        ],
        ["split", "families"],
    )
    lines += [""]

    lines += ["## Splits", ""]
    split_counts = split.get("counts", {})
    lines += table(
        [[key, value] for key, value in sorted(split_counts.items())],
        ["measure", "value"],
    )
    lines += ["", "Per split and part:", ""]
    rows = []
    for split_name in ("train", "eval"):
        for part, values in sorted((split.get(f"{split_name}_parts") or {}).items()):
            rows.append(
                [
                    split_name,
                    part,
                    values.get("examples"),
                    values.get("positive"),
                    values.get("negative"),
                    values.get("option_spans"),
                    values.get("option_kinds"),
                    values.get("families"),
                    values.get("sessions"),
                ]
            )
    lines += table(
        rows,
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
        + f"{dev.get('negative')} negative, {dev.get('sessions')} sessions, "
        + f"{dev.get('families')} families, {dev.get('option_spans')} option spans "
        + f"({dev.get('option_spans_real')} real), kinds {dev.get('option_kinds')}.",
        "",
    ]
    lines += ["Hashes:", ""]
    for name, value in sorted((split.get("hashes") or {}).items()):
        lines.append(f"- `{name}`: `{value}`")
    lines += [""]

    lines += ["## Spend", ""]
    rows = []
    for name, values in sorted((spend.get("by_model") or {}).items()):
        rows.append(
            [
                name,
                values.get("requests"),
                values.get("prompt_tokens"),
                values.get("completion_tokens"),
                values.get("cache_hit"),
                values.get("cache_miss"),
                values.get("reasoning_tokens"),
                values.get("cached_requests"),
                values.get("peak_requests"),
                round(float(values.get("cost", 0)), 4),
            ]
        )
    lines += table(
        rows,
        [
            "model",
            "requests",
            "prompt tokens",
            "completion tokens",
            "cache hit",
            "cache miss",
            "reasoning tokens",
            "cached requests",
            "peak requests",
            "cost usd",
        ],
    )
    lines += [
        "",
        f"Total DeepSeek spend: ${float(spend.get('total', 0)):.4f}.",
        "Cache hits use the cache-hit price; cached responses cost nothing.",
        "",
    ]

    for name in ("smoke", "eval-smoke"):
        meta = read_json(Path(f"data/label-{name}-meta.json")) or {}
        if not meta:
            continue
        lines += [
            f"{name}: {meta.get('pending')} contexts, "
            f"${float(meta.get('stage_spend', {}).get('cost', 0)):.4f}, "
            f"{meta.get('cache_hits', 0)} cache hits.",
            "",
        ]

    if diagnostic:
        lines += ["## Labeller diagnostic (train families)", ""]
        lines += table(
            [
                ["selected", diagnostic.get("selected")],
                ["compared", diagnostic.get("families")],
                ["missing", diagnostic.get("missing")],
                ["invalid", diagnostic.get("invalid")],
                ["line classes agree", diagnostic.get("class_agreement")],
                ["question unit agrees", diagnostic.get("unit_agreement")],
                ["option sets exact", diagnostic.get("options_exact")],
                ["v4-pro has more inline options", diagnostic.get("v4_more_inline")],
                ["v4-pro has more list options", diagnostic.get("v4_more_list")],
                ["flash has more inline options", diagnostic.get("flash_more_inline")],
                ["flash has more list options", diagnostic.get("flash_more_list")],
                ["other", diagnostic.get("other")],
            ],
            ["measure", "value"],
        )
        lines += [
            "",
            "v4-pro labels use one sample on each of 300 seeded train families.",
            "Flash never sees an eval context in this diagnostic.",
            "",
        ]

    if sanity:
        lines += ["## Sanity check (not a phase 2 result)", ""]
        lines += table(
            [
                ["train examples", sanity.get("train")],
                ["epochs", sanity.get("epochs")],
                ["train seconds", sanity.get("train_seconds")],
                ["question token F1", sanity.get("question_f1")],
                ["option exact F1", sanity.get("option_f1")],
                ["real-part option exact F1", sanity.get("real_option_f1")],
                ["unit accuracy", sanity.get("unit_accuracy")],
                ["question false-positive rate", sanity.get("false_positive_rate")],
            ],
            ["measure", "value"],
        )
        lines += [
            "",
            "One epoch, seed 0, no bold, full train and eval sets.",
            "This checks that the labels train; it is not a tuned result.",
            "",
        ]

    Path("data/phase1-report.md").write_text("\n".join(lines) + "\n")
    print(
        json.dumps(
            {
                "train": split_counts.get("train"),
                "dev": split_counts.get("dev"),
                "eval": split_counts.get("eval"),
                "train_option_spans": split_counts.get("train_option_spans"),
                "eval_option_spans": split_counts.get("eval_option_spans"),
                "spend": round(float(spend.get("total", 0)), 4),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
