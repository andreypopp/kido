package tmux

import (
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// TestPaneFormatEndsWithPaneTitle pins that pane_title, which may contain
// anything including bytes that look like the separator, stays last.
func TestPaneFormatEndsWithPaneTitle(t *testing.T) {
	if !strings.HasSuffix(paneFormat, "#{pane_title}") {
		t.Errorf("paneFormat does not end with #{pane_title}: %q", paneFormat)
	}
}

// TestPaneFormatNoCommandDuration pins that pane_command_duration, which
// ticks every second, stays out of paneFormat.
func TestPaneFormatNoCommandDuration(t *testing.T) {
	if strings.Contains(paneFormat, "pane_command_duration") {
		t.Error("paneFormat includes pane_command_duration, which would defeat snapshot change-detection")
	}
}

// TestPaneFormatFieldCountMatchesConstant pins that paneFormat's field
// count and paneFields move together.
func TestPaneFormatFieldCountMatchesConstant(t *testing.T) {
	n := strings.Count(paneFormat, sep) + 1
	if n != paneFields {
		t.Fatalf("paneFormat has %d fields, paneFields const says %d; update both", n, paneFields)
	}
}

// TestPaneFormatFixtureFromFormat generates its fixture from paneFormat's
// own field count, unlike TestParsePanes' hand-typed one, so a field
// added to paneFormat but not to SplitN/len(f) is caught here.
func TestPaneFormatFixtureFromFormat(t *testing.T) {
	tokens := strings.Split(paneFormat, sep)
	if len(tokens) != paneFields {
		t.Fatalf("paneFormat has %d fields, paneFields const says %d; update both", len(tokens), paneFields)
	}

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
		LastExit:    &Exit{Code: 16, At: 1000017},
		CommandLine: values[18],
		DeadAt:      1000020, SessionAttached: true,
		Run: values[22], Title: values[23],
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v, want %+v", got, want)
	}
}
