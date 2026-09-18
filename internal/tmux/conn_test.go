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
		if got := quote(c.in); got != c.want {
			t.Errorf("quote(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParsePanes(t *testing.T) {
	line := strings.Join([]string{"work", "1700000000", "2", "win", "layout",
		"%3", "1", "4242", "claude", "/tmp", "✳ Title"}, sep)
	p := parsePanes([]string{line, "junk"})
	if len(p) != 1 {
		t.Fatalf("got %d panes, want 1", len(p))
	}
	want := Pane{SessionName: "work", SessionCreated: 1700000000, WindowIndex: 2,
		WindowName: "win", WindowLayout: "layout", PaneID: "%3", Active: true,
		PanePID: 4242, CurrentCommand: "claude", CurrentPath: "/tmp", Title: "✳ Title"}
	if p[0] != want {
		t.Errorf("got %+v, want %+v", p[0], want)
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
