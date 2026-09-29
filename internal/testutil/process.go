package testutil

import (
	"os/exec"
	"testing"
)

// DeadPID starts and waits for a trivial child process, returning its
// pid: guaranteed to belong to no process by the time the caller uses it.
func DeadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}
