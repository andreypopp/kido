import json
from pathlib import Path
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
    job = wait_for("real monitor job", lambda: next((m.get("details") for m in demo.messages()
        if m.get("role") == "toolResult" and m.get("toolName") == "async_bash"
        and m.get("details", {}).get("log")), None), 90)
    output = Path(job["log"])
    wait_for("agent responds to first line", lambda: "CI is running for commit a22dfd." in demo.screen(demo.agent), 80)
    demo.mark("first reaction")
    assert output.read_text().strip() == "commit a22dfd pushed to main, starting CI"
    time.sleep(2)
    signal.touch()
    demo.mark("failure released")
    wait_for("actual failure output", lambda: "CI failed, check logs" in output.read_text(), 30)
    wait_for("agent responds to failure", lambda: "CI failed; check the logs." in demo.screen(demo.agent), 60)
    launches = [item["arguments"] for message in demo.messages() for item in message.get("content", [])
                if isinstance(item, dict) and item.get("type") == "toolCall" and item["name"] == "async_bash"]
    assert len(launches) == 1 and launches[0].get("stream") is True, launches
    assert launches[0]["command"] == "./ci-monitor.sh", launches
    demo.mark("done")
    time.sleep(2)
    demo.mark("verified")
    assert not any(m.get("customType") == "ko-notice" and job["job"] in json.dumps(m) for m in demo.messages()), "Monitor ended during the take"
    evidence = HERE / "output/async"
    evidence.mkdir(exist_ok=True)
    (evidence / "evidence.json").write_text(json.dumps({"job": job, "launches": launches, "status": demo.status(),
        "output": output.read_text(), "screen": demo.screen(demo.agent), "timeline": demo.timeline}, indent=2))
