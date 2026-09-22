package e2e

import (
	"os/exec"
	"strconv"
	"testing"
	"time"
)

// TestLeakCheckIgnoresUnrelatedServer is the regression test for the
// incident this fix addresses: a control-mode client attached to some
// other tmux server, started while this test runs, must not be counted
// as belonging to this test's own inner server. The old check scanned
// the whole machine's process table and could not tell the two apart.
func TestLeakCheckIgnoresUnrelatedServer(t *testing.T) {
	requireTmux(t)
	h := start(t, "leak-a")

	scratch := "kido-leak-scratch-" + strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := exec.Command(tmuxBin, "-L", scratch, "-f", "/dev/null",
		"new-session", "-d", "-s", "s").Run(); err != nil {
		t.Fatalf("start scratch server: %v", err)
	}
	t.Cleanup(func() { exec.Command(tmuxBin, "-L", scratch, "kill-server").Run() })

	client := exec.Command(tmuxBin, "-L", scratch, "-C", "attach-session", "-t", "s")
	stdin, err := client.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stdin.Close(); client.Process.Kill(); client.Wait() })

	scratchPID := strconv.Itoa(client.Process.Pid)
	deadline := time.Now().Add(2 * time.Second)
	for len(controlClientPIDs(scratch)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("scratch control client never attached")
		}
		time.Sleep(50 * time.Millisecond)
	}

	// This is the check the harness cleanup runs against h.inner. It must
	// see only kido's own client, never the scratch server's, even though
	// the scratch client appeared during this very test.
	pids := controlClientPIDs(h.inner)
	if len(pids) != 1 {
		t.Fatalf("expected exactly one control client on h.inner, got %v", pids)
	}
	if pids[0] == scratchPID {
		t.Fatalf("h.inner's control clients wrongly include the unrelated scratch server's client %s", scratchPID)
	}
}

// TestLeakCheckCatchesAccumulation proves the check has not been weakened
// into one that can never fail: a second control-mode client attached to
// this test's own server - what a redial that forgot to reap the old
// client would look like - is still visible to controlClientPIDs, which
// is exactly the condition the harness cleanup treats as a leak.
func TestLeakCheckCatchesAccumulation(t *testing.T) {
	requireTmux(t)
	h := start(t, "leak-b")

	client := exec.Command(tmuxBin, "-L", h.inner, "-C", "attach-session")
	stdin, err := client.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stdin.Close(); client.Process.Kill(); client.Wait() })

	deadline := time.Now().Add(2 * time.Second)
	var pids []string
	for {
		pids = controlClientPIDs(h.inner)
		if len(pids) >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("second control client never attached to h.inner, got %v", pids)
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(pids) < 2 {
		t.Fatalf("expected the harness's own accumulation check to see >1 client, got %v", pids)
	}
}

// TestProcessGoneDetectsLingering is the direct test of the trap in the
// task: a process that is still running must read as not gone, and one
// that has actually exited must read as gone - so a control client that
// somehow outlived its server (the case being hunted) would still be
// caught even though it has already dropped off the server's own client
// list by then.
func TestProcessGoneDetectsLingering(t *testing.T) {
	cmd := exec.Command("sleep", "5")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	pid := strconv.Itoa(cmd.Process.Pid)

	if processGone(pid, 200*time.Millisecond) {
		t.Fatal("a still-running process was reported gone")
	}

	cmd.Process.Kill()
	cmd.Wait()
	if !processGone(pid, time.Second) {
		t.Fatal("a killed process was reported still running")
	}
}
