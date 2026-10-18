#!/bin/sh
exec python3 -u -c '
import json, select, sys, time
started = time.time() - 5
print(json.dumps(dict(hello=dict(protocol="5.0"))))
def status(state, msg=None):
    return dict(since=started, msg=msg, state=state)
def agent(state, msg=None):
    return ["Live", ["Pi_agent", dict(id="session", status=status(state, msg))]]
def shell(phase=["Unknown"], report=None):
    return ["Live", ["Terminal", dict(phase=phase, report=report)]]
def running(command):
    return ["Running", dict(origin=["Command", dict(command=command, started_at=started)], fullscreen=False)]
def item(pane, window, title, lifecycle, children=None, started=None, run=None):
    return dict(kind="pane", id="%"+str(pane), pane="%"+str(pane), window="@"+str(window), title=title, lifecycle=lifecycle,
        program_status=dict(serial=0, records=[]), run=run, started=started, children=children or [])
def group(window, children):
    return dict(kind="window", id="@"+str(window), window="@"+str(window), name={0:"Workspace", 6:"Build", 7:"Review"}.get(window, "Tasks"), children=children)
while True:
    main = group(0, [item(0, 0, "orchestrator", agent(["Running", dict(progress=None)], "fixing the failing sidebar tests"), [
        group(9, [item(12, 9, "child first", shell()), item(13, 9, "child last", shell())]),
        group(10, [item(14, 10, "sibling first", shell()), item(15, 10, "sibling last", shell())]),
        item(2, 1, "tests", agent(["Waiting", dict(kind="permission", progress=None)], "Allow running make test?"), [
            item(3, 2, "docs", agent(["Idle", dict(outcome=dict(serial=1, result="success"))], "wrote docs/design.md"), [
                item(4, 3, "lint", ["Ended", dict(result="completed")], run="agent"),
                item(11, 8, "flaky", ["Ended", dict(result="died")], run="agent")], run="agent")], run="agent", started=started)]),
        item(1, 0, "zsh", shell())])
    work = [item(6, 5, "review the pull request", agent(["Idle", dict(outcome=dict(serial=1, result="failure"))], "reading files")),
        group(6, [item(7, 6, "cargo build --release", shell(["Idle", dict(last=None)], status(["Idle", dict(outcome=dict(serial=2, result="failure"))])), run="bash"),
                  item(8, 6, "ssh", ["Live", ["Ssh", dict(user="me", host="devbox", pane=["Remote_terminal", dict(interactive=True, status=dict(phase=running("tail -f /var/log/system.log"), report=None))])]])]),
        group(7, [item(9, 7, "refactor", agent(["Running", dict(progress=None)], "compacting")), item(10, 7, "zsh", shell())])]
    sessions = [dict(id="$0", name="main", current=True, nodes=[main, item(5, 4, "make test", shell(running("make test")), started=started, run="bash"), item(16, 11, "main-watch", shell(running("main-watch")), started=started, run="stream")]),
        dict(id="$1", name="work", current=False, nodes=work)]
    print(json.dumps(dict(v=2, client=dict(session="$0", window="@0", pane="%0"), server_instance=dict(started_at=int(started), pid=4242), error=None, sessions=sessions)))
    if select.select([sys.stdin], [], [], .5)[0]:
        line = sys.stdin.readline()
        if not line: break
        request = json.loads(line)
        if "id" not in request: continue
        reply = dict(id=request["id"])
        if "switch-window" in request or "switch-session" in request: reply["switched"] = None
        elif "jump" in request: reply["jumped"] = request["jump"]
        elif "release-side-focus" in request: reply["released"] = True
        else: reply["error"] = "fake server does not mutate topology"
        print(json.dumps(dict(reply=reply)))
'
