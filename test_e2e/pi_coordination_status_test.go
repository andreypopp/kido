package e2e

import (
	"strings"
	"testing"
)

func TestPiCoordinationSurvivesRootReplacement(t *testing.T) {
	for _, status := range []string{"state=clear", "state=idle:app=builder"} {
		t.Run(status, func(t *testing.T) {
			t.Parallel()
			h := start(t, "alpha")
			parent := h.firstPane("alpha")
			h.programStatus(parent, "state=idle:app=pi")
			h.agentStatus("coord-parent", parent, "pi", "--name", "Parent", "--inbox", startInbox(t, "ok\n").Path)
			child := h.piPane("alpha", "Child")
			in := startInbox(t, "ok\n")
			h.agentStatus("coord-child", child, "pi", "--name", "Child", "--inbox", in.Path, "--parent-session", "coord-parent")
			h.agentRunMeta("coord-child", child, "Child", "coord-parent")
			h.waitRow("Child")
			feed := h.startFeed("alpha")
			h.programStatus(child, status)
			h.programStatus(parent, status)
			feed.waitLast(func(s feedSnapshot) bool {
				for _, session := range s.Sessions {
					for _, row := range feedItems(session.Nodes) {
						if row.Pane != nil && *row.Pane == child {
							return row.Kind == "shell"
						}
					}
				}
				return false
			}, "replaced root is a terminal despite live pi identity")
			rows := h.listedRuns(parent)
			wantStatus := "idle"
			if status == "state=clear" {
				wantStatus = "unknown"
			}
			if len(rows) != 1 || rows[0].ID != "coord-child" || rows[0].Status != wantStatus {
				t.Fatalf("live child lost after %s: %+v", status, rows)
			}
			out, rc := h.kidoAs(parent, "", nil, "get-agent", "--context")
			if rc != 0 {
				t.Fatalf("identity graph lost after %s: %d %s", status, rc, out)
			}
			agents := parseAgents(t, out)
			if len(agents) != 2 || !agents[0].Self || agents[1].ID != "coord-child" || !agents[1].CanMessage || !agents[1].CanReply {
				t.Fatalf("coordination permissions lost after %s: %+v", status, agents)
			}
			out, rc = h.kidoAs(parent, "", nil, "snapshot")
			if rc != 0 || !strings.Contains(out, "pi --session coord-parent") || !strings.Contains(out, "pi --session coord-child") {
				t.Fatalf("session resume lost after %s: %d %s", status, rc, out)
			}
			h.expectKido(parent, "message", nil, "delivered to Child by inbox", "tool", "message_agent", "Child")
			h.expectKido(parent, "question", nil, "delivered to Child by inbox", "tool", "ask_agent", "--id", "coord-ask", "Child")
			h.expectKido(parent, "correction", nil, "delivered to Child by inbox", "tool", "steer_subagent", "Child")
			h.expectKido(parent, "", nil, "interrupted Child", "tool", "interrupt_subagent", "Child")
			stopped := make(chan bool, 1)
			go func() {
				defer close(stopped)
				h.waitFor(func() bool {
					for _, msg := range in.Received() {
						if strings.Contains(msg, `"kind":"stop"`) {
							return true
						}
					}
					return false
				}, settle, msgf("stop reaches healthy child"))
				h.agentStatus("coord-child", child, "pi", "--remove")
				stopped <- true
			}()
			out, rc = h.kidoAs(parent, "", nil, "tool", "stop_run", "Child")
			if !<-stopped || rc != 0 || strings.Contains(out, "killed") || !h.paneExists(child) {
				t.Fatalf("healthy child stop after %s: %d %s; pane alive=%v", status, rc, out, h.paneExists(child))
			}
		})
	}
}
