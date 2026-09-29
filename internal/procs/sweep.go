// Package procs looks up process details tmux does not report.
package procs

import (
	"path/filepath"
	"strconv"
	"strings"
)

// Scan is one read of the process table: everything kido works out from
// the processes behind a pane, so a pane costs one ps call and not one per
// question.
type Scan struct {
	// SSH is what is known about every ssh process, keyed both by its own
	// pid (a pane started directly with ssh as its command) and by its
	// parent pid (the usual case: a pane's shell ran ssh).
	SSH map[int]SSHSession
	// Pi holds every pid that has a pi process below it, so a pane's pid
	// says whether pi runs in that pane however deep the shim goes. tmux
	// cannot answer this: pi is a bash shim around node, and the node
	// renaming itself in-process is invisible to ps, so
	// #{pane_current_command} is just "node".
	Pi map[int]bool
}

// SSHSession is one ssh process as its arguments describe it.
type SSHSession struct {
	// Host is the destination, "user@host" or "host".
	Host string
	// Interactive is true when ssh allocates a pty and hands the terminal
	// to a remote shell, so nothing is "running" in the sense a job is:
	// no remote command, or -t forcing a pty anyway, or -N. A remote
	// command with no -t is a job like any other.
	Interactive bool
}

// piSuffix is the path pi's own script lives at, inside the Homebrew (or
// npm) install: the shim and the node process both carry it in argv.
const piSuffix = "/libexec/bin/pi"

// sshValueOpts are the ssh option letters that take a value, so the
// parser can tell `-o BatchMode=yes` (two arguments) from `-tt` (one) and
// find where the destination starts. From ssh(1); a letter kido does not
// know about can only cost it the priming a caller may build on top of
// SSHArgs, never the connection, since an unparsed argument leaves no
// destination and an invocation with no destination is passed through
// untouched.
const sshValueOpts = "BbcDEeFIiJLlmOoPpQRSWw"

// SSHArgs is an ssh command line split at its destination: everything
// before it, in order (Opts) and as option letters with values excluded
// (Letters), the destination itself (Dest, with any "ssh://" left in
// place), and the remote command, if one was given (Command).
type SSHArgs struct {
	Opts    []string
	Letters string
	Dest    string
	Command []string
}

func ParseSSH(args []string) SSHArgs {
	var in SSHArgs
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if in.Dest != "" {
			in.Command = append(in.Command, arg)
			continue
		}
		if arg == "--" {
			if i+1 < len(args) {
				in.Dest = args[i+1]
				in.Command = append(in.Command, args[i+2:]...)
			}
			return in
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			in.Dest = arg
			continue
		}
		in.Opts = append(in.Opts, arg)
		for j := 1; j < len(arg); j++ {
			in.Letters += string(arg[j])
			if strings.IndexByte(sshValueOpts, arg[j]) >= 0 {
				// The value is the rest of this argument, or the next one.
				if j == len(arg)-1 && i+1 < len(args) {
					i++
					in.Opts = append(in.Opts, args[i])
				}
				break
			}
		}
	}
	return in
}

// sshSession: -N wins over -t wins over -T; with none of them ssh
// allocates a pty only when there is no remote command to run instead.
func sshSession(args []string) SSHSession {
	in := ParseSSH(args)
	if in.Dest == "" {
		return SSHSession{}
	}
	return SSHSession{
		Host: strings.TrimPrefix(in.Dest, "ssh://"),
		Interactive: strings.ContainsRune(in.Letters, 'N') ||
			strings.ContainsRune(in.Letters, 't') ||
			(!strings.ContainsRune(in.Letters, 'T') && len(in.Command) == 0),
	}
}

// process is one row of the process table.
type process struct {
	pid, ppid int
	comm      string
	args      []string
}

// Sweep reads the process table once and answers every question kido has
// about the processes behind panes.
func Sweep() Scan {
	s := Scan{SSH: map[int]SSHSession{}, Pi: map[int]bool{}}
	all, parent := parseProcesses(psFields("-axo", "pid=,ppid=,comm=,args="))
	for _, p := range all {
		if filepath.Base(p.comm) == "ssh" {
			if sess := sshSession(p.args[1:]); sess.Host != "" {
				s.SSH[p.pid] = sess
				s.SSH[p.ppid] = sess
			}
		}
		if isPi(p) {
			markAncestors(s.Pi, parent, p.pid)
		}
	}
	return s
}

// parseProcesses turns psFields' rows (pid ppid comm args...) into
// process rows and the pid->ppid map Sweep's ancestor walk needs. A row
// with fewer than 4 fields is skipped.
func parseProcesses(rows [][]string) (all []process, parent map[int]int) {
	parent = map[int]int{}
	for _, f := range rows {
		if len(f) < 4 {
			continue
		}
		pid, err := strconv.Atoi(f[0])
		if err != nil {
			continue
		}
		ppid, err := strconv.Atoi(f[1])
		if err != nil {
			continue
		}
		p := process{pid: pid, ppid: ppid, comm: f[2], args: f[3:]}
		all = append(all, p)
		parent[pid] = ppid
	}
	return all, parent
}

// MaybePi reports whether a pane's foreground command could be pi, and
// so whether the pane is worth a process sweep. pi is a bash shim
// around node and renames itself in-process, invisible to ps, so "node"
// is what a pi pane usually reports; "pi" covers an install running
// under its own name.
func MaybePi(command string) bool {
	return command == "node" || command == "pi"
}

func isPi(p process) bool {
	if len(p.args) > 0 && filepath.Base(p.args[0]) == "pi" {
		return true
	}
	for _, a := range p.args {
		if strings.HasSuffix(a, piSuffix) {
			return true
		}
	}
	return false
}

// markAncestors marks pid and everything above it, stopping at a pid
// with no known parent, at pid 1, or at an already marked one. The
// depth cap guards against a ps snapshot whose ppids form a cycle.
func markAncestors(set map[int]bool, parent map[int]int, pid int) {
	for range 64 {
		if pid <= 1 || set[pid] {
			return
		}
		set[pid] = true
		ppid, ok := parent[pid]
		if !ok {
			return
		}
		pid = ppid
	}
}
