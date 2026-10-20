"""Build hard tokenizer cases and compare Swift byte offsets with HF offsets."""

from __future__ import annotations

import argparse
import json
import subprocess
import unicodedata
from pathlib import Path

from transformers import AutoTokenizer

CASES = {
    "box-drawing": "┌─────┬─────┐\n│ a   │ b   │\n└─────┴─────┘",
    "emoji-zwj": "family 👨‍👩‍👧‍👦 and flag 🇵🇱 and skin 👍🏽",
    "cjk": "日本語のテキストと中文混合",
    "combining": "e\u0301 cafe\u0301 n\u0303",
    "combining-option": "e\u0301 cafe\u0301\n1. option",
    "tabs": "a\tb\t\tc",
    "crlf": "first\r\nsecond\r\n",
    "bold-markers": "**alpha** and **beta** with `code`",
    "code": "func main() {\n    print(\"héllo\")\n}",
    "markers": "> 12: 1. **Red**\n  13: - blue",
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="jhu-clsp/ettin-encoder-32m")
    parser.add_argument("--tokenizer", type=Path, default=Path("data/models/ettin"))
    parser.add_argument("--binary", type=Path, default=Path("swift-offsets/.build/debug/offsets"))
    parser.add_argument("--cases", type=Path, default=Path("data/offset-cases.json"))
    args = parser.parse_args(argv)
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    cases = []
    for name, text in CASES.items():
        normalized = unicodedata.normalize("NFC", text)
        encoded = tokenizer(normalized, return_offsets_mapping=True, add_special_tokens=False)
        scalars = list(text)
        prefixes = [
            unicodedata.normalize("NFC", "".join(scalars[:index]))
            for index in range(len(scalars) + 1)
        ]

        def byte_offset(
            character_offset: int,
            normalized: str = normalized,
            prefixes: list[str] = prefixes,
            scalars: list[str] = scalars,
            text: str = text,
        ) -> int:
            prefix = normalized[:character_offset]
            for index, value in enumerate(prefixes):
                if value == prefix:
                    return len("".join(scalars[:index]).encode())
            return len(text.encode())

        offsets = [
            [byte_offset(start), byte_offset(end)]
            for start, end in encoded["offset_mapping"]
        ]
        cases.append(
            {"name": name, "text": text, "ids": encoded["input_ids"], "offsets": offsets}
        )
    args.cases.write_text(json.dumps({"cases": cases}) + "\n")
    result = subprocess.run(
        [str(args.binary), str(args.cases), str(args.tokenizer)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print(result.stderr)
        return result.returncode
    output = json.loads(result.stdout)
    Path("data/swift-offsets.json").write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
