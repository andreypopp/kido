package tmux

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
)

// TestPaneFormatEndsWithPaneTitle pins AGENTS.md's rule (a): pane_title may
// contain anything, including bytes that look like the separator, so it
// must stay the last field parsePanes ever reads. Moving anything after it
// would let a hostile title swallow that field's own data.
func TestPaneFormatEndsWithPaneTitle(t *testing.T) {
	if !strings.HasSuffix(paneFormat, "#{pane_title}") {
		t.Errorf("paneFormat does not end with #{pane_title}: %q", paneFormat)
	}
}

// TestPaneFormatNoCommandDuration pins AGENTS.md's rule (c): pane_command_duration
// ticks every second, and including it would defeat the snapshot
// change-detection that keeps the sidebar from redrawing once a second
// forever.
func TestPaneFormatNoCommandDuration(t *testing.T) {
	if strings.Contains(paneFormat, "pane_command_duration") {
		t.Error("paneFormat includes pane_command_duration, which would defeat snapshot change-detection")
	}
}

// TestPaneFormatFieldCountMatchesConstant pins AGENTS.md's rule (b): the
// field count in paneFormat and the paneFields constant parsePanes' SplitN
// and len(f) guard both use must move together. Without this test, adding
// a field to paneFormat but forgetting paneFields compiles clean and only
// misbehaves against a real tmux server.
func TestPaneFormatFieldCountMatchesConstant(t *testing.T) {
	n := strings.Count(paneFormat, sep) + 1
	if n != paneFields {
		t.Fatalf("paneFormat has %d fields, paneFields const says %d; update both", n, paneFields)
	}
}

// TestPaneFormatFixtureFromFormat generates its parse fixture from
// paneFormat itself, rather than a hand-written slice like TestParsePanes
// does, and asserts every field lands in the struct member parsePanes says
// it should. TestParsePanes' own fixture is hand-typed: if someone adds a
// field to paneFormat and forgets to update SplitN and
// the len(f) guard together, that fixture is one element short and every
// existing parse test stays green while real tmux output silently loses a
// field into pane_title. Driving the fixture from paneFormat's own field
// count is what catches that drift immediately instead.
func TestPaneFormatFixtureFromFormat(t *testing.T) {
	tokens := strings.Split(paneFormat, sep)
	if len(tokens) != paneFields {
		t.Fatalf("paneFormat has %d fields, paneFields const says %d; update both", len(tokens), paneFields)
	}

	// One distinguishable value per field: string fields get a field-named
	// string, numeric and boolean fields get a value derived from the
	// index so it round-trips through strconv and is still unique.
	values := make([]string, len(tokens))
	for i := range values {
		values[i] = fmt.Sprintf("str%d", i)
	}
	values[2] = strconv.Itoa(1000000 + 2)   // session_created
	values[3] = strconv.Itoa(1000000 + 3)   // window_index
	values[8] = "1"                         // pane_active (Active)
	values[9] = strconv.Itoa(1000000 + 9)   // pane_pid
	values[12] = "1"                        // alternate_on
	values[13] = "1"                        // pane_command_running
	values[14] = strconv.Itoa(1000000 + 14) // pane_command_start_time
	values[15] = strconv.Itoa(1000000 + 15) // pane_last_prompt_time
	values[16] = strconv.Itoa(16)           // pane_command_status
	values[17] = strconv.Itoa(1000000 + 17) // pane_command_end_time
	values[19] = "1"                        // pane_dead
	values[20] = strconv.Itoa(1000000 + 20) // pane_dead_time
	values[21] = "1"                        // session_attached

	line := strings.Join(values, sep)
	p := parsePanes([]string{line})
	if len(p) != 1 {
		t.Fatalf("got %d panes, want 1", len(p))
	}
	got := p[0]

	want := Pane{
		SessionName: values[0], SessionID: values[1], SessionCreated: 1000002,
		WindowIndex: 1000003, WindowID: values[4], WindowName: values[5], WindowLayout: values[6],
		PaneID: values[7], Active: true, PanePID: 1000009,
		CurrentCommand: values[10], CurrentPath: values[11], AlternateOn: true,
		CommandRunning: true, CommandStartTime: 1000014, LastPromptTime: 1000015,
		CommandStatus: 16, CommandStatusOK: true, CommandEndTime: 1000017,
		CommandLine: values[18],
		Dead:        true, DeadTime: 1000020, SessionAttached: true,
		Subagent: values[22], SubagentPane: values[23], Title: values[24],
	}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
}
