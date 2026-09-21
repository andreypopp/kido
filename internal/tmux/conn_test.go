package tmux

import (
	"strings"
	"testing"
)

// stream is a control-mode session: the attach block, a list-panes block
// whose data lines start with "%" (pane ids), a notification between
// blocks, a failed command, and the final %exit.
const stream = "%begin 100 1 0\n" +
	"%end 100 1 0\n" +
	"%session-changed $1 work\n" +
	"%begin 100 2 1\n" +
	"%0\tzsh\n" +
	"%1\tclaude\n" +
	"%end 100 2 0\n" + // the flags differ from the %begin
	"%window-add @7\n" +
	"%output %3 junk\n" +
	"%begin 100 3 1\n" +
	"parse error: unknown command: bogus\n" +
	"%error 100 3 1\n" +
	"%exit\n"

func TestParse(t *testing.T) {
	var blocks []block
	var notes []string
	parse(strings.NewReader(stream),
		func(b block) { blocks = append(blocks, b) },
		func(name string) { notes = append(notes, name) })

	if len(blocks) != 3 {
		t.Fatalf("blocks: got %d, want 3: %+v", len(blocks), blocks)
	}
	if len(blocks[0].lines) != 0 || blocks[0].err != nil {
		t.Errorf("attach block: got %+v, want empty", blocks[0])
	}
	if want := []string{"%0\tzsh", "%1\tclaude"}; !equal(blocks[1].lines, want) {
		t.Errorf("data block: got %q, want %q", blocks[1].lines, want)
	}
	if blocks[1].err != nil {
		t.Errorf("data block: unexpected error %v", blocks[1].err)
	}
	if blocks[2].err == nil || !strings.Contains(blocks[2].err.Error(), "unknown command") {
		t.Errorf("error block: got %v, want the parse error", blocks[2].err)
	}

	want := []string{"%session-changed", "%window-add", "%output", "%exit"}
	if !equal(notes, want) {
		t.Errorf("notifications: got %q, want %q", notes, want)
	}
	for _, n := range notes {
		if n == "%output" && notifications[n] {
			t.Error("output notifications must not trigger a refresh")
		}
	}
}

// A truncated stream must not hand out the half-read block.
func TestParseUnterminatedBlock(t *testing.T) {
	var blocks []block
	parse(strings.NewReader("%begin 1 1 0\nrow\n"),
		func(b block) { blocks = append(blocks, b) }, func(string) {})
	if len(blocks) != 0 {
		t.Errorf("got %+v, want no block", blocks)
	}
}

// Command output that looks like a guard line belongs to the block.
func TestParseGuardLookalike(t *testing.T) {
	var blocks []block
	parse(strings.NewReader("%begin 5 9 0\n%end 5 8 0\nrow\n%end 5 9 1\n"),
		func(b block) { blocks = append(blocks, b) }, func(string) {})
	if len(blocks) != 1 {
		t.Fatalf("blocks: got %d, want 1", len(blocks))
	}
	if want := []string{"%end 5 8 0", "row"}; !equal(blocks[0].lines, want) {
		t.Errorf("got %q, want %q", blocks[0].lines, want)
	}
}

func TestQuote(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"#{pane_id}", "'#{pane_id}'"},
		{"/dev/ttys012", "'/dev/ttys012'"},
		{"it's", `'it'\''s'`},
	} {
		if got := Quote(c.in); got != c.want {
			t.Errorf("Quote(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParsePanes(t *testing.T) {
	line := strings.Join([]string{"work", "1700000000", "2", "@7", "win", "layout",
		"%3", "1", "4242", "claude", "/tmp", "0", "1", "1700000100", "1700000050",
		"2", "1700000090", "✳ Title"}, sep)
	p := parsePanes([]string{line, "junk"})
	if len(p) != 1 {
		t.Fatalf("got %d panes, want 1", len(p))
	}
	want := Pane{SessionName: "work", SessionCreated: 1700000000, WindowIndex: 2,
		WindowID: "@7", WindowName: "win", WindowLayout: "layout", PaneID: "%3", Active: true,
		PanePID: 4242, CurrentCommand: "claude", CurrentPath: "/tmp",
		CommandRunning: true, CommandStartTime: 1700000100, LastPromptTime: 1700000050,
		CommandStatus: 2, CommandStatusOK: true, CommandEndTime: 1700000090,
		Title: "✳ Title"}
	if p[0] != want {
		t.Errorf("got %+v, want %+v", p[0], want)
	}
}

// TestParsePanesEmptyCommandStatus pins the one field tmux prints empty
// rather than zero: a pane whose shell has never reported a command's exit
// status must not read as one that exited 0.
func TestParsePanesEmptyCommandStatus(t *testing.T) {
	line := strings.Join([]string{"work", "1700000000", "2", "@7", "win", "layout",
		"%3", "0", "4242", "zsh", "/tmp", "1", "0", "", "1700000050",
		"", "", "zsh"}, sep)
	p := parsePanes([]string{line})
	if len(p) != 1 {
		t.Fatalf("got %d panes, want 1", len(p))
	}
	if !p[0].AlternateOn {
		t.Error("alternate_on was not parsed")
	}
	if p[0].CommandStatusOK || p[0].CommandStatus != 0 || p[0].CommandEndTime != 0 {
		t.Errorf("got status (%d, %v) end %d, want no status and no end time",
			p[0].CommandStatus, p[0].CommandStatusOK, p[0].CommandEndTime)
	}
}

func TestParseClientState(t *testing.T) {
	lines := []string{
		"/dev/ttys001" + sep + "other" + sep + "attached,UTF-8",
		"/dev/ttys012" + sep + "work" + sep + "attached,side-status-focus,UTF-8",
	}
	if sess, focused := parseClientState(lines, "/dev/ttys012"); sess != "work" || !focused {
		t.Errorf("got (%q, %v), want (work, true)", sess, focused)
	}
	if sess, focused := parseClientState(lines, "/dev/ttys001"); sess != "other" || focused {
		t.Errorf("got (%q, %v), want (other, false)", sess, focused)
	}
	if sess, _ := parseClientState(lines, "/dev/ttys999"); sess != "" {
		t.Errorf("unknown client: got %q, want empty", sess)
	}
}

// TestOrderSessions checks that sessions come out oldest first (ties by
// name), each with its own windows in ListPanes' order, so the grouping the
// sidebar renders and the one switch-session and switch-window walk cannot
// drift apart.
func TestOrderSessions(t *testing.T) {
	panes := []Pane{
		{SessionName: "b", SessionCreated: 200, WindowID: "@3", PaneID: "%1"},
		{SessionName: "b", SessionCreated: 200, WindowID: "@4", PaneID: "%2"},
		{SessionName: "a", SessionCreated: 100, WindowID: "@1", PaneID: "%3"},
		{SessionName: "a", SessionCreated: 100, WindowID: "@1", PaneID: "%4"}, // second pane, same window
		{SessionName: "a", SessionCreated: 100, WindowID: "@2", PaneID: "%5"},
	}
	sessions := OrderSessions(panes)
	var names []string
	var got [][2]string // session, window id, flattened the way SwitchWindow does
	for _, s := range sessions {
		names = append(names, s.Name)
		for _, w := range s.Windows {
			got = append(got, [2]string{w[0].SessionName, w[0].WindowID})
		}
	}
	if want := []string{"a", "b"}; !equal(names, want) {
		t.Errorf("sessions: got %v, want %v", names, want)
	}
	want := [][2]string{{"a", "@1"}, {"a", "@2"}, {"b", "@3"}, {"b", "@4"}}
	if len(got) != len(want) {
		t.Fatalf("windows: got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("window %d: got %v, want %v", i, got[i], want[i])
		}
	}
	if len(sessions[0].Windows[0]) != 2 {
		t.Errorf("session a window @1: got %d panes, want 2", len(sessions[0].Windows[0]))
	}
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
