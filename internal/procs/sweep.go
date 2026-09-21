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

// Process is one row of the process table.
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

// parseProcesses turns psFields' rows (pid ppid comm args...) into process
// rows and the pid->ppid map Sweep's ancestor walk needs. A row with fewer
// than 4 fields - missing or malformed - is skipped.
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
// so whether the pane is worth a process sweep. pi is a bash shim around
// node and renames itself in-process, which ps (and so tmux) never sees,
// so "node" is what a pi pane usually reports; "pi" covers an install
// that runs under its own name. A pane matching this that turns out not
// to be pi costs one ps call a second, the same price an ssh pane whose
// destination cannot be resolved has always paid.
func MaybePi(command string) bool {
	return command == "node" || command == "pi"
}

// isPi reports whether p is a pi process: the bash shim and the node it
// execs both name pi's script in their arguments, and a pi installed so
// that it runs under its own name is matched by that name alone.
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

// markAncestors marks pid and everything above it, stopping at a pid with
// no known parent, at pid 1, or at an already marked one (which carries
// its own ancestors). The depth cap is belt and braces against a ps
// snapshot whose ppids form a cycle.
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

// sshValueOpts are ssh options that take a separate value, so the value is
// not mistaken for the destination.
const sshValueOpts = "BbcDEeFIiJLlmOoPpQRSWw"

// sshSession picks the destination out of ssh's arguments and works out
// whether the session is interactive. Everything after the destination is
// the remote command, so the destination's index answers both questions in
// one walk; the pty flags are picked up on the way there.
func sshSession(args []string) SSHSession {
	var forceTTY, noTTY, noCommand bool
	// done finishes the walk at the destination: dest is its index, so
	// anything past it is the remote command. -N wins over -t wins over
	// -T, and with none of them a pty is allocated only when there is no
	// remote command to run instead of a shell.
	done := func(dest int, host string) SSHSession {
		hasCommand := dest+1 < len(args)
		return SSHSession{
			Host:        host,
			Interactive: noCommand || forceTTY || (!noTTY && !hasCommand),
		}
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			if i+1 < len(args) {
				return done(i+1, args[i+1])
			}
			return SSHSession{}
		}
		if strings.HasPrefix(a, "-") && len(a) > 1 {
			// Flags bundle ("-tt", "-vN"), and an option taking a value
			// ends the bundle: "-p 2222" takes the next argument, while
			// "-p2222" and "-oProxyCommand=..." carry it themselves.
			// Either way the value must not be read as flag letters.
			flags := a[1:]
			if k := strings.IndexAny(flags, sshValueOpts); k >= 0 {
				if k == len(flags)-1 {
					i++ // the value is the next argument
				}
				flags = flags[:k]
			}
			forceTTY = forceTTY || strings.ContainsRune(flags, 't')
			noTTY = noTTY || strings.ContainsRune(flags, 'T')
			noCommand = noCommand || strings.ContainsRune(flags, 'N')
			continue
		}
		return done(i, strings.TrimPrefix(a, "ssh://"))
	}
	return SSHSession{}
}
