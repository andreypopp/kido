#!/bin/sh
exec python3 -u -c '
import json, select, sys, time
started = time.time() - 5
query = ""
def item(kind, pane, window, title, status=None, children=None, attention=False, started=None, tail=""):
    return dict(kind=kind, id="%"+str(pane), pane="%"+str(pane), window="@"+str(window), indicator=status,
        title=[dict(text=title, role="proc" if kind in ["run", "ssh", "shell"] else "plain")], tail=[dict(text=tail, role="dim")] if tail else [],
        started=started, attention=attention, children=children or [])
def group(window, children):
    return dict(kind="window", id="@"+str(window), window="@"+str(window), name={0:"Workspace", 6:"Build", 7:"Review"}.get(window, "Tasks"), children=children)
while True:
    main = group(0, [item("agent", 0, 0, "orchestrator", dict(kind="running"), [
        item("agent", 2, 1, "tests", dict(kind="waiting"), [
            item("agent", 3, 2, "docs", dict(kind="done"), [
                item("agent", 4, 3, "lint", dict(kind="gone", outcome="completed"), tail="completed"),
                item("agent", 11, 8, "flaky", dict(kind="gone", outcome="died"), tail="died")], attention=True, tail="wrote docs/design.md")], attention=True, tail="Allow running make test?")], tail="fixing the failing sidebar tests"),
        item("shell", 1, 0, "zsh")])
    work = [item("agent", 6, 5, "review the pull request", dict(kind="stalled"), tail="reading files"),
        group(6, [item("run", 7, 6, "cargo build --release", dict(kind="failed")), item("ssh", 8, 6, "ssh devbox: tail -f /var/log/system.log")]),
        group(7, [item("agent", 9, 7, "refactor", dict(kind="compacting"), tail="compacting"), item("shell", 10, 7, "zsh", dict(kind="unknown"))])]
    sessions = [dict(id="$0", name="main", current=True, nodes=[main, item("run", 5, 4, "make test", dict(kind="running"), started=started)]),
        dict(id="$1", name="work", current=False, nodes=work)]
    print(json.dumps(dict(v=2, client=dict(session="$0", window="@0", pane="%0"), filter=query,
        error="could not read the agent state" if "!" in query else None,
        sessions=[s for s in sessions if query.replace("!", "") in s["name"]])))
    if select.select([sys.stdin], [], [], .5)[0]:
        line = sys.stdin.readline()
        if not line: break
        if line.rstrip("\n") == "filter": query = ""
        elif line.startswith("filter "): query = line[7:].rstrip("\n")
'
