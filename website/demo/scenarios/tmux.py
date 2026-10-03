import time
from record import wait_for

TITLE = "Hello"
TOOLS = "read"
INSTRUCTIONS = "Reply to hello with exactly 'Hello!'. Do not call tools."
DURATION = 60
CAMERA = [("typing start", 0, (1.3, 0, 0)),
          ("running", .8, (1.45, 0, 0)),
          ("done", 1, (1, 0, 0))]
MOBILE_CAMERA = [("typing start", 0, (1.3, .45, 0)),
                 ("running", .8, (1.45, 0, 0)),
                 ("done", 1, (1, 0, 0))]
CUTS = [("running", 2, "done", -1, 8)]


def perform(demo):
    time.sleep(2)

    def split(pane, direction):
        new = demo.tmux("split-window", direction, "-t", pane, "-c", str(demo.project),
                        "-P", "-F", "#{pane_id}").strip()
        wait_for("new integrated shell", lambda: "$" in demo.screen(new), 5)
        demo.focus(new)
        time.sleep(1.2)
        return new

    second = split(demo.agent, "-h")
    split(second, "-v")
    demo.mark("first window split")
    first = demo.tmux("new-window", "-t", "greeter", "-n", "playground", "-c", str(demo.project),
                      "-P", "-F", "#{pane_id}").strip()
    wait_for("new window", lambda: "$" in demo.screen(first), 5)
    demo.focus(first)
    time.sleep(1.2)
    second = split(first, "-h")
    third = split(second, "-v")
    demo.mark("second window split")
    demo.focus(first)
    demo.type("sleep 3; false")
    demo.mark("shell running")
    demo.agent = second
    demo.open_pi()
    demo.prompt("hello")
    demo.focus(third)
    wait_for("failed shell exit", lambda: demo.tmux("display-message", "-p", "-t", first,
             "#{pane_command_status}").strip() == "1", 10)
    demo.mark("shell failed")
    wait_for("pi greeting", lambda: "Hello!" in demo.screen(second)
             and any(r["status"] == "idle" for r in demo.status()), 45)
    demo.mark("done")
    time.sleep(2)
    demo.mark("verified")
