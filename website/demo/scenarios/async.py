import json
import os
import shutil
import time
from record import HERE, wait_for

TITLE = "CI monitor"
TOOLS = "async_bash"
INSTRUCTIONS = """Launch exactly one async_bash job named ci-monitor with command './ci-monitor.sh' and stream=true. Do not launch more jobs, inspect files, poll, retry, or discuss internal environment/pacing. End your turn to await actual streamed notices. ONLY after receiving the actual line 'commit a22dfd pushed to main, starting CI', react with exactly 'CI is running for commit a22dfd.' End your turn to await further notices. After the actual failure line arrives, respond exactly 'CI failed; check the logs.' The monitor keeps running after reporting the failure: leave it running, do not stop it, and do not wait for completion. Do not claim you received output before its actual notice."""
DURATION = 180
CAMERA = [("typing start", 0, (1.35, .20, 1 - 1 / 1.35)),
          ("running", 0, (1, 0, 0))]
CUTS = [("running", 1, "first reaction", -1, 4),
        ("first reaction", 1, "done", -1, 5)]


def perform(demo):
    script = demo.project / "ci-monitor.sh"
    shutil.copyfile(HERE / "scenarios/ci-monitor.sh", script)
    script.chmod(0o700)
    signal = demo.root / ".ci-release"
    demo.open_pi()
    demo.prompt("start monitoring CI with ./ci-monitor.sh")
    wait_for("real monitor run", lambda: len(demo.runs()) == 1, 90)
    wait_for("agent responds to first line", lambda: "CI is running for commit a22dfd." in demo.screen(demo.agent), 80)
    demo.mark("first reaction")
    meta = demo.runs()[0][0]
    output = demo.root / "state/runs" / meta["id"] / "output"
    assert output.read_text().strip() == "commit a22dfd pushed to main, starting CI"
    time.sleep(2)
    signal.touch()
    demo.mark("failure released")
    wait_for("actual failure output", lambda: "CI failed, check logs" in output.read_text(), 30)
    wait_for("agent responds to failure", lambda: "CI failed; check the logs." in demo.screen(demo.agent), 60)
    assert demo.runs()[0][1] is None, "Monitor exited before the end of the take"
    os.kill(meta["pid"], 0)
    launches = []
    for path in (demo.root / "state/sessions").rglob("*.jsonl"):
        for line in path.read_text().splitlines():
            for item in json.loads(line).get("message", {}).get("content", []):
                if isinstance(item, dict) and item.get("type") == "toolCall" and item["name"] == "async_bash":
                    launches.append(item["arguments"])
    assert len(launches) == 1 and launches[0].get("stream") is True, launches
    assert launches[0]["command"] == "./ci-monitor.sh", launches
    demo.mark("done")
    time.sleep(2)
    demo.mark("verified")
    evidence = HERE / "output/async"
    evidence.mkdir(exist_ok=True)
    assert demo.runs()[0][1] is None, "Monitor exited during the final hold"
    (evidence / "evidence.json").write_text(json.dumps({"runs": demo.runs(), "launches": launches, "status": demo.status(),
        "output": output.read_text(), "screen": demo.screen(demo.agent), "timeline": demo.timeline}, indent=2))
