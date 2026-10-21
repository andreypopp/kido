import json
from pathlib import Path

import pytest

from segments import segments

CASES = json.loads((Path(__file__).parent.parent / "fixtures" / "segments.json").read_text())[
    "cases"
]


@pytest.mark.parametrize("case", CASES, ids=[case["name"] for case in CASES])
def test_shared_cases(case: dict[str, object]) -> None:
    text = str(case["text"])
    got = [
        {"start": s.start, "end": s.end, "kind": s.kind, "text": text[s.start : s.end]}
        for s in segments(text)
    ]
    assert got == case["segments"]
