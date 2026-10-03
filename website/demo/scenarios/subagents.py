import json
import time
from record import HERE, wait_for

TITLE = "Parallel math"
TOOLS = "spawn_subagent"
INSTRUCTIONS = """Spawn exactly two keepAlive=true agents, model openai-codex/gpt-6.1-sol:low. Spawn B FIRST, tools message_agent,notify_parent. B's task: 'Wait for A to send two random numbers and their sum. Then compute twice that sum and tell your parent using notify_parent, including the full numeric expression. Do not notify before A's message; end your turn while waiting. Never spawn agents or poll.' Spawn A SECOND, tools bash,message_agent,notify_parent. A's task: 'Run python3 sum.py exactly once to get two random integers and their sum. Tell B the numbers and sum using message_agent, then notify_parent with what you sent. Do not spawn agents.' Use these relative filenames; never put absolute paths in tasks. End your turn to wait for their actual reports. After B reports the doubled result, print exactly one sentence: 'Result: (a + b) × 2 = result.' with the actual numeric values from A and B, not placeholders. Do not invent numbers or compute the result before receiving B's report."""
DURATION = 180
CAMERA = [("typing start", 0, (1.35, .20, 1 - 1 / 1.35)),
          ("running", 0, (1, 0, 0)),
          ("child", 0, (1.45, 0, 0)),
          ("children", 0, (1, 0, 0))]
CUTS = [("running", 1, "child", -1, 2),
        ("child", 1, "children", -1, 2),
        ("children", 1, "done", -1, 6)]


def perform(demo):
    (demo.project / "sum.py").write_text('''import json
from pathlib import Path
import random

a, b = random.randint(0, 10), random.randint(0, 10)
Path("numbers.json").write_text(json.dumps({"a": a, "b": b}))
print(f"{a} + {b} = {a + b}")
''')
    demo.open_pi()
    demo.prompt("spawn 2 subagents A and B, A should compute a sum of two random 0-10 numbers and tell B, B should compute result of A*2 and tell you the result")
    wait_for("first real child", lambda: len(demo.runs()) >= 1, 90)
    demo.mark("child")
    wait_for("both real children", lambda: len(demo.runs()) == 2, 90)
    demo.mark("children")
    wait_for("A messages B", lambda: "message_agent" in demo.calls(), 120)
    wait_for("both child reports", lambda: demo.calls().count("notify_parent") >= 2, 90)
    numbers = json.loads((demo.project / "numbers.json").read_text())
    a, b = numbers["a"], numbers["b"]
    expected = f"Result: ({a} + {b}) × 2 = {(a + b) * 2}."
    wait_for("actual final arithmetic", lambda: expected in demo.screen(demo.agent).replace("\n", " ")
             and any(r["status"] == "idle" and not r.get("parent") for r in demo.status()), 60)
    assert {m["name"] for m, _ in demo.runs()} == {"A", "B"}
    demo.mark("done")
    time.sleep(2)
    demo.mark("verified")
    evidence = HERE / "output/subagents"
    evidence.mkdir(exist_ok=True)
    (evidence / "evidence.json").write_text(json.dumps({"numbers": numbers, "result": (a + b) * 2,
        "runs": demo.runs(), "calls": demo.calls(), "status": demo.status(), "screen": demo.screen(demo.agent)}, indent=2))
