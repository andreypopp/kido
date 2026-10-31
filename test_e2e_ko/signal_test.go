package ko_test

import (
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func signalable(pid int) bool {
	return pid > 1 && pid <= math.MaxInt32 && pid != os.Getpid() && pid != syscall.Getpgrp()
}

func descends(pid, root int) bool {
	for at, hops := pid, 0; hops < 64; hops++ {
		if at == root {
			return true
		}
		out, err := exec.Command("ps", "-o", "ppid=", "-p", strconv.Itoa(at)).Output()
		if err != nil {
			return false
		}
		if at, err = strconv.Atoi(strings.TrimSpace(string(out))); err != nil || at <= 1 {
			return false
		}
	}
	return false
}

func signalOwned(t testing.TB, root int, sig syscall.Signal, pids ...int) {
	t.Helper()
	for _, pid := range pids {
		if !signalable(pid) || !signalable(root) || !descends(pid, root) {
			t.Fatalf("refusing to signal pid %d under %d", pid, root)
		}
	}
	for _, pid := range pids {
		if err := syscall.Kill(pid, sig); err != nil {
			t.Fatal(err)
		}
	}
}

func gone(pid int) bool { return signalable(pid) && syscall.Kill(pid, 0) == syscall.ESRCH }
