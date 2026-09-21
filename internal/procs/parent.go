package procs

import (
	"os"
	"path/filepath"
	"strconv"
)

// ReporterPID returns the pid to record as an agent's process for one
// status report: the immediate caller of kido, or - when viaShell is true
// - the first ancestor of it past any wrapping shell. Claude Code runs its
// hook through `sh -c`, so runHook's immediate parent is a short-lived sh
// (dash, on Linux, does not exec the last command of `sh -c "kido hook"`),
// not claude, and must be walked past. kido agent-status is spawned
// directly by an agent's extension with no shell wrapper, so agentStatus
// passes false and skips the ps walk entirely, on a process that is
// already startup-dominated and spawned once per status change.
func ReporterPID(viaShell bool) int {
	pid := os.Getppid()
	if !viaShell {
		return pid
	}
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
	rows := psFields("-o", "ppid=,comm=", "-p", strconv.Itoa(pid))
	return parseParent(rows)
}

// parseParent reads the (ppid, comm) pair psFields returns for a `ps -o
// ppid=,comm= -p <pid>` query: its one row, if any.
func parseParent(rows [][]string) (ppid int, comm string, ok bool) {
	if len(rows) == 0 || len(rows[0]) < 2 {
		return 0, "", false
	}
	ppid, err := strconv.Atoi(rows[0][0])
	if err != nil {
		return 0, "", false
	}
	return ppid, rows[0][1], true
}

func isShell(comm string) bool {
	switch filepath.Base(comm) {
	case "sh", "dash", "bash", "zsh", "ksh":
		return true
	}
	return false
}
