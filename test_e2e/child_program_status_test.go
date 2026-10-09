package e2e

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestChildProgramStatus(t *testing.T) {
	for _, app := range []string{"claude-code", "compiler"} {
		t.Run(app, func(t *testing.T) {
			t.Parallel()
			h := start(t, "alpha")
			pane := h.newWindow("alpha", "native", nodeBin, "--")
			h.waitPaneCommand(pane, "node")
			tail := h.newWindow("alpha", "tail", "cat", "--")
			h.in("select-window", "-t", tail)
			emit := func(body string) {
				t.Helper()
				h.in("send-keys", "-t", pane, "-l", "osc "+body)
				h.in("send-keys", "-t", pane, "Enter")
			}
			enc := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
			emit("state=working:app=" + app + ":title=" + enc("Parent"))
			emit("state=working:id=a:title=" + enc("Investigate"))
			emit("state=blocked:id=a/b:msg=" + enc("approve"))
			emit("state=done:id=a-other:title=" + enc("Finished"))
			rows := func() string {
				var out []string
				for _, line := range h.capture() {
					out = append(out, strings.TrimSpace(ansi.Strip(ansi.Truncate(line, sideWidth-1, ""))))
				}
				return strings.Join(out, "\n")
			}
			waitRows := func(doneGlyph string) {
				t.Helper()
				h.waitFor(func() bool {
					rows := rows()
					return strings.Contains(rows, "├◼Investigate\n") &&
						strings.Contains(rows, "│ └◆a/b approve\n") &&
						strings.Contains(rows, "└"+indField(doneGlyph)+"Finished\n") &&
						strings.Index(rows, "Investigate") < strings.Index(rows, "a/b approve") &&
						strings.Index(rows, "a/b approve") < strings.Index(rows, "Finished")
				}, settle, msgf("nested program rows: %v", h.rows()))
			}
			waitRows("✓")
			f := h.startFeed("alpha")
			f.waitLast(func(s feedSnapshot) bool {
				items := feedItems(s.Sessions[0].Nodes)
				if len(items) != 3 {
					return false
				}
				for _, r := range items {
					if r.ID == pane {
						return len(r.Children) == 0 && len(r.ProgramStatus.Records) == 4 &&
							r.Indicator != nil && r.Indicator.Kind == "waiting"
					}
				}
				return false
			}, "RPC keeps child records inside their pane item")
			focusSidebar(h)
			h.sendKeys("g")
			h.sendKeys("g")
			h.waitSelectedLine(2)
			h.sendKeys("Down")
			h.waitSelectedLine(3)
			h.sendKeys("Down")
			h.waitSelected("cat")
			h.click(5, h.rowIndex("Investigate"))
			h.sendKeys("Up")
			h.waitSelectedLine(3)
			h.sendKeys("Up")
			h.waitSelectedLine(2)
			// The cursor reset proves the sidebar observed focus loss before we re-focus.
			h.prefix("k")
			h.waitFocused(false)
			h.waitSelected("cat")
			h.waitFor(func() bool {
				return h.in("display-message", "-p", "-c", h.client, "#{pane_id}") == tail
			}, settle, msgf("child click leaves the selected pane unchanged"))
			focusSidebar(h)
			h.sendKeys("Up")
			h.waitSelectedLine(3)
			h.sendKeys("Enter")
			h.waitFocused(false)
			h.waitFor(func() bool {
				return h.in("display-message", "-p", "-c", h.client, "#{pane_id}") == pane
			}, settle, msgf("Enter jumps to parent pane"))
			waitRows("")
			emit("state=clear:id=a/b")
			emit("state=clear:id=a")
			emit("state=clear:id=a-other")
			h.waitFor(func() bool {
				rows := rows()
				return !strings.Contains(rows, "Investigate") &&
					!strings.Contains(rows, "a/b approve") && !strings.Contains(rows, "Finished")
			}, settle, msgf("cleared child rows disappear"))
		})
	}
}
