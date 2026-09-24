package main

import (
	"os"
	"strings"
	"testing"
	"unicode/utf8"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// withParentInbox is the fixture every notify_parent report test needs: a
// live parent with a v1 inbox, and this process pointed at it the way a
// spawned child is. It returns the inbox so a test can read what arrived.
func withParentInbox(t *testing.T) *testutil.Inbox {
	t.Helper()
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{{PaneID: "%1", SessionID: "$1"}, {PaneID: "%9", SessionID: "$1"}})
	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("parent", state.Session{
		Pane: "%9", PID: os.Getpid(), Status: state.Idle, Instance: "parent-inst",
		Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "parent-inst")
	return in
}

// sentNotice is the single notice on in, as the parent reads it.
func sentNotice(t *testing.T, in *testutil.Inbox) string {
	t.Helper()
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("parent inbox got %d payloads, want exactly one notice", len(msgs))
	}
	env, ok := msg.Parse([]byte(msgs[0]))
	if !ok {
		t.Fatalf("payload %q did not parse as a v1 envelope", msgs[0])
	}
	if env.Kind != msg.KindNotice {
		t.Fatalf("envelope kind = %q, want %q", env.Kind, msg.KindNotice)
	}
	return env.Text
}

// TestNotifyParentUnderTheCapIsUntouched is the negative control the
// split is unsafe without: the whole feature is about a report too long
// to send, and an ordinary one must arrive exactly as it was written,
// with nothing appended and no file left behind. A split that fired on
// every report would satisfy every assertion the long case makes.
func TestNotifyParentUnderTheCapIsUntouched(t *testing.T) {
	in := withParentInbox(t)
	runID := subrun.NewID()
	if err := subrun.Create(runID, "task"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KIDO_AGENT_RUN_ID", runID)

	report := "the merge is done; two conflicts, both in README.md"
	if code := notifyParentCmd(nil, strings.NewReader(report)); code != 0 {
		t.Fatalf("notify_parent = %d, want 0", code)
	}
	if got := sentNotice(t, in); got != report {
		t.Errorf("notice = %q, want the report byte for byte", got)
	}
	if subrun.HasReport(runID) {
		t.Errorf("a report within the cap left %s behind; nothing was lost, so there is nothing to point at", subrun.ReportPath(runID))
	}
}

// TestNotifyParentOverTheCapKeepsTheWholeReport is the bug: four reports
// were cut mid-sentence and the rest of them was simply gone. What is
// asserted is all three halves of the fix - the file has every byte, the
// parent is told where it is, and what the parent got is still a notice
// within the cap rather than the whole thing under a new name.
func TestNotifyParentOverTheCapKeepsTheWholeReport(t *testing.T) {
	in := withParentInbox(t)
	runID := subrun.NewID()
	if err := subrun.Create(runID, "task"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KIDO_AGENT_RUN_ID", runID)

	// A report whose end is the part that would be lost, so "the file has
	// all of it" is a claim about the tail rather than about a length.
	report := strings.Repeat("findings and more findings. ", 200) + "CONCLUSION: ship it"
	if len(report) <= maxReportBytes {
		t.Fatalf("fixture report is %d bytes, which is not over the %d byte cap", len(report), maxReportBytes)
	}
	if code := notifyParentCmd(nil, strings.NewReader(report)); code != 0 {
		t.Fatalf("notify_parent = %d, want 0", code)
	}

	kept, err := os.ReadFile(subrun.ReportPath(runID))
	if err != nil {
		t.Fatalf("reading the kept report: %v", err)
	}
	if string(kept) != report {
		t.Errorf("kept report is %d bytes, want all %d of them", len(kept), len(report))
	}

	notice := sentNotice(t, in)
	if len(notice) > maxReportBytes {
		t.Errorf("notice is %d bytes, over the %d byte cap it exists to stay inside", len(notice), maxReportBytes)
	}
	wantLast := "full report: " + subrun.ReportPath(runID)
	if !strings.HasSuffix(notice, wantLast) {
		t.Errorf("notice ends %q, want it to end naming the file: %q", notice[max(0, len(notice)-80):], wantLast)
	}
	if !strings.HasPrefix(notice, report[:100]) {
		t.Errorf("notice starts %q, want the head of the report itself", notice[:100])
	}
}

// TestNotifyParentHeadIsCutOnARuneBoundary: the cut is at a byte offset
// and the send path refuses a message that is not valid UTF-8 outright,
// so a report whose cap falls inside a multi-byte character would cost
// the run the one notice it gets - tailOfFile's rule (ending_notice.go)
// in the other direction, and for the same reason.
func TestNotifyParentHeadIsCutOnARuneBoundary(t *testing.T) {
	in := withParentInbox(t)
	runID := subrun.NewID()
	if err := subrun.Create(runID, "task"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KIDO_AGENT_RUN_ID", runID)

	// Three-byte runes throughout, so wherever the cap lands it lands
	// inside one unless the cut is moved back off it.
	report := strings.Repeat("日", 3000)
	if code := notifyParentCmd(nil, strings.NewReader(report)); code != 0 {
		t.Fatalf("notify_parent = %d, want 0: a report of multi-byte runes must still be sendable", code)
	}
	notice := sentNotice(t, in)
	if !utf8.ValidString(notice) {
		t.Errorf("notice is not valid UTF-8; the send path refuses one outright")
	}
	if strings.ContainsRune(notice, '\uFFFD') {
		t.Errorf("notice carries a replacement character, so the cut split a rune rather than moving off it")
	}
	if kept, err := os.ReadFile(subrun.ReportPath(runID)); err != nil || string(kept) != report {
		t.Errorf("kept report = %d bytes, %v, want all %d", len(kept), err, len(report))
	}
}

// TestNotifyParentWithNoRunDirectoryTruncates: a sender kido never
// spawned - a pi started by hand inside an agent's pane, carrying that
// agent's parent edge but no run of its own - has nowhere to keep a
// report, and keeps the behaviour it always had. The notice must still
// arrive: the failure mode worth avoiding is a long report that reaches
// nobody.
func TestNotifyParentWithNoRunDirectoryTruncates(t *testing.T) {
	in := withParentInbox(t)
	t.Setenv("KIDO_AGENT_RUN_ID", "")

	report := strings.Repeat("x", 4500)
	if code := notifyParentCmd(nil, strings.NewReader(report)); code != 0 {
		t.Fatalf("notify_parent = %d, want 0", code)
	}
	notice := sentNotice(t, in)
	if len(notice) != maxReportBytes {
		t.Errorf("notice is %d bytes, want it truncated to %d", len(notice), maxReportBytes)
	}
	if strings.Contains(notice, "full report:") {
		t.Errorf("notice names a file there is nowhere to write: %q", notice[len(notice)-60:])
	}
}
