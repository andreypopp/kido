package e2e

import (
	"fmt"
	"math"
	"os"
	"os/exec"
	"syscall"
)

func signalable(pid int) bool {
	return pid > 1 && pid <= math.MaxInt32 && pid != os.Getpid() && pid != syscall.Getpgrp()
}

func signalPID(pid int, sig syscall.Signal) error {
	if !signalable(pid) {
		return fmt.Errorf("refusing to signal pid %d", pid)
	}
	return syscall.Kill(pid, sig)
}

func signalGroup(leader *exec.Cmd, sig syscall.Signal) error {
	pid := leader.Process.Pid
	if !signalable(pid) {
		return fmt.Errorf("refusing to signal group %d", pid)
	}
	return syscall.Kill(-pid, sig)
}

func gone(pid int) bool { return signalable(pid) && syscall.Kill(pid, 0) == syscall.ESRCH }
