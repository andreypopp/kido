package ko_test

import (
	"errors"
	"testing"
	"time"

	"kido/internal/rusage"
)

// Three idle panes (a program blocked in read, one view each) must not make
// the coordinator wake: its CPU time grows less than 5 ms over 5 s. ps has a
// 10 ms resolution, so the figure comes from proc_pid_rusage.
func TestNoIdleWakeups(t *testing.T) {
	t.Parallel()
	s := start(t)
	pid := s.cmd.Process.Pid
	if _, err := rusage.Read(pid); errors.Is(err, errors.ErrUnsupported) {
		t.Skip("no per-process CPU time on this platform")
	}
	for range 3 {
		p := s.pane("printf READY; while read x; do :; done")
		s.ready(s.dialWS("/panes/"+p+"/view", nil, 101), "READY")
	}
	before, err := rusage.Read(pid)
	if err != nil {
		t.Fatal(err)
	}
	<-time.After(5 * time.Second)
	after, err := rusage.Read(pid)
	if err != nil {
		t.Fatal(err)
	}
	grown := after.CPU - before.CPU
	t.Logf("coordinator CPU grew %v and wakeups grew by %d over 5 s", grown, after.Wakeups-before.Wakeups)
	if grown >= 5*time.Millisecond {
		t.Fatalf("coordinator CPU grew %v over 5 s with idle panes", grown)
	}
}
