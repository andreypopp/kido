// Package procs looks up process details tmux does not report.
package procs

import (
	"bufio"
	"bytes"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// Scan is one read of the process table: everything kido works out from
// the processes behind a pane, so a pane costs one ps call and not one per
// question.
type Scan struct {
	// SSH is the destination ("user@host" or "host") of every ssh process,
	// keyed both by its own pid (a pane started directly with ssh as its
	// command) and by its parent pid (the usual case: a pane's shell ran
	// ssh).
	SSH map[int]string
	// Pi holds every pid that has a pi process below it, so a pane's pid
	// says whether pi runs in that pane however deep the shim goes. tmux
	// cannot answer this: pi is a bash shim around node, and the node
	// renaming itself in-process is invisible to ps, so
	// #{pane_current_command} is just "node".
	Pi map[int]bool
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
	s := Scan{SSH: map[int]string{}, Pi: map[int]bool{}}
	out, err := exec.Command("ps", "-axo", "pid=,ppid=,comm=,args=").Output()
	if err != nil {
		return s
	}
	var all []process
	parent := map[int]int{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
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
	for _, p := range all {
		if filepath.Base(p.comm) == "ssh" {
			if host := sshHost(p.args[1:]); host != "" {
				s.SSH[p.pid] = host
				s.SSH[p.ppid] = host
			}
		}
		if isPi(p) {
			markAncestors(s.Pi, parent, p.pid)
		}
	}
	return s
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

// sshHost picks the destination out of ssh's arguments.
func sshHost(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			if i+1 < len(args) {
				return args[i+1]
			}
			return ""
		}
		if strings.HasPrefix(a, "-") && len(a) > 1 {
			// "-p 2222" takes the next argument; "-p2222" carries it.
			if len(a) == 2 && strings.ContainsRune(sshValueOpts, rune(a[1])) {
				i++
			}
			continue
		}
		return strings.TrimPrefix(a, "ssh://")
	}
	return ""
}
