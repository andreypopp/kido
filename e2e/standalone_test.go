package e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// Standalone mode is kido run as a one-shot picker rather than as a
// client's side status line: what `tmux display-popup -E -w 40 -h 80%
// "kido -client ..."` gets. It is chosen by $TMUX_SIDE_CLIENT being
// empty, which the fork only ever sets for the side-status-command job,
// so these tests run kido in an ordinary window of the inner server with
// that variable explicitly unset and the client named on the command
// line, the way the popup binding names it.
//
// The harness's outer pty is not involved: keys go straight to the
// picker's pane on the inner server and its screen is read back from
// there, so nothing here disturbs the sidebar the harness also runs.

// picker is one standalone kido, running in its own inner window.
type picker struct {
	h    *harness
	pane string
}

// startPicker runs kido standalone in a new window of session and waits
// until it has painted. The window keeps remain-on-exit on, so the pane
// survives kido's exit and its status can be read: a test must be able to
// tell tea.Quit from a crash or a signal.
func startPicker(h *harness, session string) *picker {
	h.t.Helper()
	h.keepDeadPanes()
	pane := h.newWindow(session, "picker", "env", "-u", "TMUX_SIDE_CLIENT",
		kidoBin, "-client", h.client)
	p := &picker{h: h, pane: pane}
	p.waitRow(session)
	return p
}

// keys sends keys to the picker's pane, one send-keys per key like the
// harness does for the sidebar.
func (p *picker) keys(keys ...string) {
	p.h.t.Helper()
	for _, k := range keys {
		p.h.in("send-keys", "-t", p.pane, k)
		time.Sleep(60 * time.Millisecond)
	}
}

// typeText sends text as literal runes, the way a user types a filter.
func (p *picker) typeText(s string) {
	p.h.t.Helper()
	p.h.in("send-keys", "-t", p.pane, "-l", s)
	time.Sleep(60 * time.Millisecond)
}

// capture is the picker pane's screen, escape sequences kept.
func (p *picker) capture() []string {
	out, err := p.h.tmux(p.h.inner, "capture-pane", "-p", "-e", "-t", p.pane)
	if err != nil {
		return nil
	}
	return strings.Split(out, "\n")
}

// rows is the picker's non-empty lines as plain text.
func (p *picker) rows() []string {
	var out []string
	for _, l := range p.capture() {
		if t := strings.TrimSpace(ansi.Strip(l)); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// selected is the text of the row the picker draws in reverse video.
func (p *picker) selected() string { return selectedRowOf(p.capture()) }

func (p *picker) waitRow(sub string) {
	p.h.t.Helper()
	p.h.waitFor(func() bool { return hasLine(p.rows(), sub) }, settle,
		func() string { return fmt.Sprintf("picker row %q (has %q)", sub, p.rows()) })
}

func (p *picker) waitSelected(sub string) {
	p.h.t.Helper()
	p.h.waitFor(func() bool { return strings.Contains(p.selected(), sub) }, settle,
		func() string { return fmt.Sprintf("picker selection on %q (is %q)", sub, p.selected()) })
}

// dead reports the pane's exit state: whether kido has exited, and with
// what status.
func (p *picker) dead() (bool, string) {
	out, err := p.h.tmux(p.h.inner, "display-message", "-p", "-t", p.pane,
		"#{pane_dead}\t#{pane_dead_status}")
	if err != nil {
		return false, ""
	}
	state, status, _ := strings.Cut(strings.TrimSpace(out), "\t")
	return state == "1", status
}

// waitExit waits for kido to exit and insists it exited cleanly: a
// tea.Quit, not a crash or a signal.
func (p *picker) waitExit() {
	p.h.t.Helper()
	p.h.waitFor(func() bool { dead, _ := p.dead(); return dead }, settle,
		func() string { return fmt.Sprintf("the picker to exit (shows %q)", p.rows()) })
	if _, status := p.dead(); status != "0" {
		p.h.t.Fatalf("picker exited with status %q, want a clean 0", status)
	}
}

func (p *picker) mustBeAlive() {
	p.h.t.Helper()
	if dead, status := p.dead(); dead {
		p.h.t.Fatalf("the picker exited (status %q) when it should still be up", status)
	}
}

// TestStandaloneQuitsOnQ checks that q ends the program - what closes the
// popup kido is running in.
func TestStandaloneQuitsOnQ(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	p := startPicker(h, "alpha")
	p.keys("q")
	p.waitExit()
}

// TestStandaloneQuitsOnCtrlC checks C-c, the other way out.
func TestStandaloneQuitsOnCtrlC(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	p := startPicker(h, "alpha")
	p.keys("C-c")
	p.waitExit()
}

// TestStandaloneEscClearsFilterFirst checks that Esc keeps its meaning:
// it leaves the search when one is on, and only quits when there is
// nothing left to leave - the same order the sidebar uses before it hands
// the keyboard back.
func TestStandaloneEscClearsFilterFirst(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	p := startPicker(h, "alpha")
	p.waitRow("beta")

	p.keys("/")
	p.typeText("beta")
	p.h.waitFor(func() bool {
		rows := p.rows()
		return hasLine(rows, "/beta") && !hasLine(rows, "alpha")
	}, settle, func() string { return fmt.Sprintf("the filter beta (shows %q)", p.rows()) })

	p.keys("Escape") // leaves the search, does not quit
	p.h.waitFor(func() bool {
		rows := p.rows()
		return hasLine(rows, "alpha") && !hasLine(rows, "/beta")
	}, settle, func() string { return fmt.Sprintf("the filter cleared (shows %q)", p.rows()) })
	p.mustBeAlive()

	p.keys("Escape") // nothing left to clear: quit
	p.waitExit()
}

// TestStandaloneEnterJumpsAndQuits checks the one-shot pick: Enter moves
// the client to the selected pane and then ends the program, so the popup
// closes as soon as something is picked.
func TestStandaloneEnterJumpsAndQuits(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	p := startPicker(h, "alpha")
	p.waitRow("beta")

	p.keys("G") // beta's pane, the last row
	p.waitSelected(shell)
	p.keys("Enter")

	h.waitSession("beta")
	p.waitExit()
}

// TestSidebarIgnoresQ guards the other half of the split: in the side
// column q is still nothing, so the sidebar cannot be quit out from under
// the client that is showing it.
//
// A still-rendering column proves nothing on its own: the fork restarts a
// side job that exits (status.c), so a sidebar quit by q would be replaced
// by a fresh one within the second this waits. What a restart cannot fake
// is the state the old one held - the selection is moved off the active
// pane first, and a new kido would put it back.
func TestSidebarIgnoresQ(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.waitRows(4)
	focusSidebar(h)

	h.sendKeys("G") // beta's pane: not where a fresh sidebar would start
	h.waitSelectedLine(4)

	h.sendKeys("q")
	time.Sleep(time.Second)
	if got := h.selectedIndex(); got != 4 {
		t.Fatalf("selection moved to line %d after q: the sidebar was quit and restarted", got)
	}
	if !h.clientFocused() {
		t.Fatal("q released the sidebar's keyboard focus")
	}
	if !h.sidebarVisible() {
		t.Fatal("q closed the sidebar")
	}
}
