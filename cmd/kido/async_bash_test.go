package main

import (
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
	t.Setenv("KIDO_AGENT_PARENT_SESSION", "nobody-alive-reports-this")

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
