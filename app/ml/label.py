"""Label redacted contexts with DeepSeek. The key comes from the environment only."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from openai import OpenAI

from redact import redact
from render import ask_label, prompt_lines, read_jsonl, write_jsonl
from validate import label_errors

SYSTEM = """You label terminal text for a paragraph question detector.
Read the numbered lines. A question unit is a question paragraph and its answer options.
Return JSON only, with this exact shape:
{"lines": ["other", "question", ...], "options": [{"line": 4, "text": "exact option"}]}

Rules:
- "lines" has one class for every numbered line: "question", "option" or "other".
- A list option line has class "option". Its marker ("1.", "-", "a)") is not part of the option.
- An inline option ("use alpha or beta?") is in a "question" line and in "options".
- Every option appears in "options" with its exact text as it appears on its line, without the
  list marker. Copy the text exactly. Do not invent text.
- A question without options has only "question" lines and an empty "options" list.
- Plain prose, code, logs, tables and numbered steps are "other".
- The question and all its option lines form one contiguous unit. Blank lines may separate them.
"""


def request_body(model: str, prompt: str) -> dict[str, object]:
    count = len(prompt_lines(prompt))
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM + f"\nReturn exactly {count} line classes."},
            {"role": "user", "content": prompt},
        ],
        "response_format": {"type": "json_object"},
        "max_tokens": 2048,
        "temperature": 0,
        "thinking": {"type": "disabled"},
    }


def parse_response(content: str) -> object:
    content = content.strip()
    if content.startswith("```"):
        content = content.split("\n", 1)[1] if "\n" in content else content
        content = content.rsplit("```", 1)[0]
    return json.loads(content)


def label_one(
    client: OpenAI, model: str, prompt: str, user: str
) -> tuple[dict[str, object] | None, list[str]]:
    redacted = redact(prompt, user=user)
    if redacted != prompt:
        return None, ["input is not redacted"]
    body = request_body(model, prompt)
    messages = list(body["messages"])
    request = {
        "messages": messages,
        "response_format": body["response_format"],
        "max_tokens": body["max_tokens"],
        "temperature": body["temperature"],
    }
    rejection = ""
    raw = ""
    for _ in range(2):
        payload = dict(request)
        payload["messages"] = messages
        if rejection:
            payload["messages"] = messages + [
                {"role": "assistant", "content": raw},
                {"role": "user", "content": f"Your label was rejected: {rejection}. Correct it."},
            ]
        response = client.chat.completions.create(
            model=model, extra_body={"thinking": {"type": "disabled"}}, **payload
        )
        raw = response.choices[0].message.content or ""
        try:
            label = parse_response(raw)
        except json.JSONDecodeError as error:
            rejection = f"not JSON: {error}"
            continue
        errors = label_errors(prompt, label)
        if not errors:
            return label, []
        rejection = "; ".join(errors[:5])
    return None, [rejection]


def dry_run(records: list[dict[str, object]], output: Path, model: str) -> dict[str, int]:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(request_body(model, str(record["prompt"]))) + "\n")
    return {"requests": len(records)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("data/contexts.jsonl"))
    parser.add_argument("--output", type=Path, default=Path("data/labels.jsonl"))
    parser.add_argument("--model", default="deepseek-flash")
    parser.add_argument("--samples", type=int, default=1)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args(argv)

    key = os.environ.get("DEEPSEEK_API_KEY", "")
    user = getpass.getuser()
    records = read_jsonl(args.input)
    asks = [record for record in records if record.get("source") == "ask"]
    by_id = {str(record["id"]): record for record in records}
    existing = {}
    if args.resume:
        for item in read_jsonl(args.output):
            identifier = str(item["id"])
            record = by_id.get(identifier)
            if record is not None and not label_errors(
                str(record["prompt"]), item["label"]
            ):
                existing[identifier] = item["label"]
    api_records = [
        record
        for record in records
        if record.get("source") != "ask" and str(record["id"]) not in existing
    ]
    if args.limit is not None:
        api_records = api_records[: args.limit]
    if not key and not args.dry_run and api_records:
        print("label: DEEPSEEK_API_KEY is not set", file=sys.stderr)
        return 1
    if args.dry_run:
        counts = dry_run(api_records, Path("data/dry-run-requests.jsonl"), args.model)
        print(json.dumps(counts, sort_keys=True))
        return 0

    client = OpenAI(api_key=key, base_url="https://api.deepseek.com", max_retries=0, timeout=180)

    def work(record: dict[str, object]) -> tuple[str, dict[str, object] | None, list[str]]:
        prompt = str(record["prompt"])
        if args.samples > 1:
            results: list[dict[str, object]] = []
            errors: list[str] = []
            for _ in range(args.samples):
                label, problem = label_one(client, args.model, prompt, user)
                if label is None:
                    errors.extend(problem)
                else:
                    results.append(label)
            if len(results) != args.samples or any(result != results[0] for result in results):
                return str(record["id"]), None, errors or ["samples disagree"]
            return str(record["id"]), results[0], []
        return str(record["id"]), *label_one(client, args.model, prompt, user)

    labels: list[dict[str, object]] = [
        {"id": identifier, "label": label} for identifier, label in existing.items()
    ]
    dropped: list[dict[str, object]] = []
    for record in asks:
        gold = ask_label(record)
        errors = label_errors(str(record["prompt"]), gold) if gold is not None else ["ask gold"]
        if gold is None or errors:
            dropped.append({"id": str(record["id"]), "errors": errors})
        else:
            labels.append({"id": str(record["id"]), "label": gold})
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for identifier, label, errors in pool.map(work, api_records):
            if label is None:
                dropped.append({"id": identifier, "errors": errors})
            else:
                labels.append({"id": identifier, "label": label})
    merged = {str(item["id"]): item["label"] for item in labels}
    labels = [{"id": identifier, "label": label} for identifier, label in merged.items()]
    labels.sort(key=lambda item: str(item["id"]))
    write_jsonl(args.output, labels)
    meta = {
        "model": args.model,
        "samples": args.samples,
        "contexts": len(records),
        "labelled": len(labels),
        "ask_gold": len(asks),
        "dropped": len(dropped),
        "drop_reasons": dropped[:50],
    }
    Path("data/label-meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    summary = {key: value for key, value in meta.items() if key != "drop_reasons"}
    print(json.dumps(summary, sort_keys=True))
    return 0 if labels else 1


if __name__ == "__main__":
    sys.exit(main())
