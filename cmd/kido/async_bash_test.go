package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"kido/internal/subrun"
)

// startAsyncRun writes a run holding argv and returns its id, the way
// `kido async_bash` would before the window exists.
func startAsyncRun(t *testing.T, argv ...string) string {
	t.Helper()
	id := subrun.NewID()
	if err := subrun.Create(id, strings.Join(argv, " ")); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteCommand(id, argv); err != nil {
		t.Fatal(err)
	}
	return id
}

// TestAsyncRunReportsBeforeItExits is why the wrapper exists rather than
// a reading of #{pane_dead_status}: everything a parent needs is on disk
// by the time this call returns, so a window that loses the
// remain-on-exit race (tmux sets it in a second call, and `true` beats it
// every time) costs only the corpse on screen. The command here exits
// instantly for exactly that reason.
func TestAsyncRunReportsBeforeItExits(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := startAsyncRun(t, "sh", "-c", "printf out; printf err >&2; exit 3")

	// Captured only to keep the command's own output off the test log:
	// the wrapper tees to its pane, which here is the test's stdout.
	var code int
	captureStdout(t, func() { code = asyncRunCmd([]string{"--run-id", id, "--name", "build"}) })
	if code != 3 {
		t.Errorf("asyncRunCmd = %d, want the command's own exit status 3", code)
	}

	o, ok, err := subrun.ReadOutcome(id)
	if err != nil || !ok {
		t.Fatalf("ReadOutcome = %+v, %v, %v, want an outcome recorded before the wrapper returned", o, ok, err)
	}
	if o.Result != subrun.Failed {
		t.Errorf("outcome = %q, want %q", o.Result, subrun.Failed)
	}
	if o.Text != "exit status 3" {
		t.Errorf("outcome text = %q, want it to carry the exit status", o.Text)
	}

	b, err := os.ReadFile(subrun.OutputPath(id))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"out", "err"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("output file = %q, want both streams teed into it (%q)", b, want)
		}
	}
}

// TestAsyncRunSuccessRecordsCompleted is the negative control for the
// test above: a command that says nothing and exits 0 must record
// completed, not failed, and must still record something.
func TestAsyncRunSuccessRecordsCompleted(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := startAsyncRun(t, "true")

	if code := asyncRunCmd([]string{"--run-id", id, "--name", "ok"}); code != 0 {
		t.Errorf("asyncRunCmd = %d, want 0", code)
	}
	o, ok, _ := subrun.ReadOutcome(id)
	if !ok || o.Result != subrun.Completed || o.Text != "exit status 0" {
		t.Errorf("outcome = %+v (recorded %v), want completed with exit status 0", o, ok)
	}
}

// TestAsyncRunLeavesAnOutcomeItDidNotWin pins the wrapper's half of the
// exactly-once rule: the outcome write is the arbiter of who observed the
// ending first, so a wrapper finding one already recorded - by a sweep,
// or by `kido stop_subagent` - keeps the story that is there and sends
// nothing of its own, leaving the notice to whoever won.
//
// The assertion that carries it is silence, and silence needs the second
// half of this test to mean anything: the same wrapper, the same absent
// parent, a race it wins, and the send path complaining out loud. Without
// that half every assertion here passes against a wrapper that never
// notifies at all.
func TestAsyncRunLeavesAnOutcomeItDidNotWin(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	// A parent nothing can resolve: the send is attempted and fails
	// loudly, which is exactly the tell this test reads.
	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "nobody-alive-reports-this")

	lost := startAsyncRun(t, "true")
	if err := subrun.RecordOutcome(lost, subrun.Outcome{Result: subrun.Stopped, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	var code int
	quiet := captureStderr(t, func() {
		code = asyncRunCmd([]string{"--run-id", lost, "--name", "raced"})
	})
	if code != 0 {
		t.Errorf("asyncRunCmd = %d, want 0: losing the outcome race is not the wrapper's failure", code)
	}
	if o, _, _ := subrun.ReadOutcome(lost); o.Result != subrun.Stopped {
		t.Errorf("outcome = %q, want the already-recorded %q to stand", o.Result, subrun.Stopped)
	}
	if quiet != "" {
		t.Errorf("wrapper that lost the outcome race said %q, want it to leave the notice to whoever won", quiet)
	}

	won := startAsyncRun(t, "true")
	loud := captureStderr(t, func() { asyncRunCmd([]string{"--run-id", won, "--name", "won"}) })
	if loud == "" {
		t.Error("wrapper that won the outcome race said nothing, so the silence above pins nothing; it should have tried to notify")
	}
}

// TestAsyncRunSignalledRecordsAndReports is the signal path of
// docs/design-subagents.md's "An async bash run": a wrapper being killed
// is exactly the ending nobody else is watching for, so it records one
// itself rather than leaving the run looking like it is still going.
func TestAsyncRunSignalledRecordsAndReports(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := startAsyncRun(t, "sleep", "30")

	done := make(chan int, 1)
	go func() { done <- asyncRunCmd([]string{"--run-id", id, "--name", "killed"}) }()
	// The wrapper arms its handler before Start, so wait for the run to
	// actually be under way rather than racing the signal against it.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(subrun.OutputPath(id)); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("wrapper never started the command")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}

	select {
	case code := <-done:
		if code != 1 {
			t.Errorf("asyncRunCmd after SIGTERM = %d, want 1", code)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("wrapper did not return after SIGTERM")
	}
	o, ok, _ := subrun.ReadOutcome(id)
	if !ok || o.Result != subrun.Failed {
		t.Errorf("outcome = %+v (recorded %v), want a failed outcome recorded by the signal handler", o, ok)
	}
	if !strings.Contains(o.Text, "terminated") {
		t.Errorf("outcome text = %q, want it to say what killed the run", o.Text)
	}
}

// TestAsyncNoticeNamesTheRun is the finding a bash run cannot work
// without: it writes no state record, so the receiving extension labels
// the sender from what it can find and falls through to the pane id -
// "notification from %47". The name has to be in the text itself, and so
// do the status and the output.
func TestAsyncNoticeNamesTheRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := startAsyncRun(t, "true")
	if err := os.WriteFile(subrun.OutputPath(id), []byte("boom\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	text := asyncNoticeText(id, "build", subrun.Failed, "exit status 3")
	for _, want := range []string{`"build"`, "failed", "exit status 3", id, "boom"} {
		if !strings.Contains(text, want) {
			t.Errorf("notice = %q, want it to carry %q", text, want)
		}
	}

	// With no name to carry, the run id is what is left; a notice saying
	// only "async run" would name nothing at all.
	if text := asyncNoticeText(id, "", subrun.Completed, "exit status 0"); !strings.Contains(text, id) {
		t.Errorf("unnamed run's notice = %q, want it to fall back to the run id", text)
	}
}

// TestAsyncNoticeTailKeepsTheEnd pins the direction of the cut. What a
// failure has to say, it says last: a notice built from the head of a
// thousand-line build log carries a thousand lines of progress and not
// the error.
func TestAsyncNoticeTailKeepsTheEnd(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/output"
	var b strings.Builder
	for i := 0; i < 1000; i++ {
		fmt.Fprintf(&b, "line %04d\n", i) // 10 bytes each: 10000 in all
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	tail, omitted, err := tailOfFile(path, maxNoticeTailBytes)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail) != maxNoticeTailBytes {
		t.Errorf("tail is %d bytes, want the %d byte cap", len(tail), maxNoticeTailBytes)
	}
	if want := int64(b.Len() - maxNoticeTailBytes); omitted != want {
		t.Errorf("omitted = %d, want %d", omitted, want)
	}
	if !strings.HasSuffix(tail, "line 0999\n") {
		t.Errorf("tail ends %q, want the last line of the file", tail[len(tail)-20:])
	}
	if strings.Contains(tail, "line 0000\n") {
		t.Errorf("tail = %q..., want the head of the file dropped", tail[:20])
	}

	// Under the cap nothing is omitted, and the whole file is carried.
	short := dir + "/short"
	if err := os.WriteFile(short, []byte("all of it\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if tail, omitted, err := tailOfFile(short, maxNoticeTailBytes); err != nil || omitted != 0 || tail != "all of it\n" {
		t.Errorf("tailOfFile(short) = %q, %d, %v, want the whole file and nothing omitted", tail, omitted, err)
	}
}

// TestAsyncNoticeTailIsValidUTF8 is not cosmetic: the send path refuses a
// message that is not valid UTF-8 outright, so a log cut mid-character -
// an ordinary consequence of cutting at a byte offset - would cost the
// run its only notice.
func TestAsyncNoticeTailIsValidUTF8(t *testing.T) {
	path := t.TempDir() + "/output"
	// Ten three-byte runes: a cut at 4 bytes lands inside the second.
	if err := os.WriteFile(path, []byte(strings.Repeat("☃", 10)), 0o644); err != nil {
		t.Fatal(err)
	}
	tail, omitted, err := tailOfFile(path, 4)
	if err != nil {
		t.Fatal(err)
	}
	if !utf8Valid(tail) {
		t.Errorf("tail = %q, want valid UTF-8", tail)
	}
	if omitted != 27 {
		t.Errorf("omitted = %d, want 27: the two bytes of the partial rune count as dropped too", omitted)
	}
	if tail != "☃" {
		t.Errorf("tail = %q, want the one whole rune that fits", tail)
	}
}

func utf8Valid(s string) bool { return strings.ToValidUTF8(s, "\uFFFD") == s }

// TestCommandArgv pins the one-word rule. A model writes a command line
// ("make -j8 && ./run"), which has to reach a shell; an argv given as
// separate words must not be mangled into one by a join.
func TestCommandArgv(t *testing.T) {
	cases := []struct {
		in   []string
		want []string
	}{
		{nil, nil},
		{[]string{"make -j8 && ./run"}, []string{"bash", "-c", "make -j8 && ./run"}},
		{[]string{"sh", "-c", "exit 3"}, []string{"sh", "-c", "exit 3"}},
	}
	for _, c := range cases {
		got := commandArgv(c.in)
		if strings.Join(got, "\x1f") != strings.Join(c.want, "\x1f") {
			t.Errorf("commandArgv(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestDerivedName covers the window name for a command nobody named,
// including the shapes a name must not take: a path, an empty command,
// and anything tmux's own parser could not carry.
func TestDerivedName(t *testing.T) {
	cases := []struct{ in, want string }{
		{"make -j8", "make"},
		{"/usr/bin/env python", "env"},
		{"", "bash"},
		{"'", "bash"},
		{"./x$y", "xy"},
	}
	for _, c := range cases {
		if got := derivedName([]string{c.in}); got != c.want {
			t.Errorf("derivedName(%q) = %q, want %q", c.in, got, c.want)
		}
		if got := derivedName([]string{c.in}); strings.ContainsAny(got, tmuxConfUnsafe) {
			t.Errorf("derivedName(%q) = %q, which tmux's own parsing cannot carry", c.in, got)
		}
	}
}
