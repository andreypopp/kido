import json
import time
from record import HERE, wait_for

TITLE = "Parallel math"
TOOLS = "spawn_agent"
INSTRUCTIONS = """Spawn exactly two agents, model openai-codex/gpt-6.1-sol:low. Spawn B FIRST, tools message_agent. B's task: 'Wait for A to send two random numbers and their sum. End your first turn with a message that says you are waiting; this is your first report. When A's message arrives later, compute twice that sum and send the result to your parent with message_agent(to="Parallel math", message=<the full numeric expression>). Never spawn agents or poll.' Spawn A SECOND, tools bash,message_agent. A's task: 'Run python3 sum.py exactly once to get two random integers and their sum. Tell B the numbers and sum using message_agent, then end your turn with a self-contained report of what you sent. Your last message goes to your parent as your report. Do not spawn agents.' Use these relative filenames; never put absolute paths in tasks. End your turn to wait for their actual results. After A's report and B's message with the doubled result arrive, print exactly one sentence: 'Result: (a + b) × 2 = result.' with the actual numeric values from A and B, not placeholders. Do not invent numbers or compute the result before receiving B's message."""
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
    def results_arrived():
        a_report, b_message = False, False
        for path in (demo.root / "state/sessions").rglob("*.jsonl"):
            for line in path.read_text().splitlines():
                try:
                    message = json.loads(line).get("message", {})
                except json.JSONDecodeError:
                    continue
                if message.get("customType") == "kido-notice" and message.get("details", {}).get("from") == "A":
                    a_report = True
                for item in message.get("content", []):
                    if (isinstance(item, dict) and item.get("type") == "toolCall"
                            and item.get("name") == "message_agent"
                            and item.get("arguments", {}).get("to") == TITLE):
                        b_message = True
        return a_report and b_message

    wait_for("A's report and B's result message", results_arrived, 90)
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
