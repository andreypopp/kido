package procs

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// HookParent returns the pid of the process that ran the current hook,
// skipping the shell Claude Code wraps hook commands in. On Linux /bin/sh
// (dash) does not exec the last command of `sh -c "kido hook"`, so the
// direct parent is a short-lived sh, not claude.
func HookParent() int {
	pid := os.Getppid()
	for i := 0; i < 3; i++ {
		ppid, comm, ok := parentOf(pid)
		if !ok || !isShell(comm) {
			return pid
		}
		pid = ppid
	}
	return pid
}

func parentOf(pid int) (ppid int, comm string, ok bool) {
	out, err := exec.Command("ps", "-o", "ppid=,comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, "", false
	}
	f := strings.Fields(string(out))
	if len(f) < 2 {
		return 0, "", false
	}
	ppid, err = strconv.Atoi(f[0])
	if err != nil {
		return 0, "", false
	}
	return ppid, f[1], true
}

func isShell(comm string) bool {
	switch filepath.Base(comm) {
	case "sh", "dash", "bash", "zsh", "ksh":
		return true
	}
	return false
}
