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

// SSHHosts returns the destination ("user@host" or "host") of every ssh
// process, keyed by its parent pid (a pane's shell). One ps call.
func SSHHosts() map[int]string {
	out := map[int]string{}
	ps, err := exec.Command("ps", "-axo", "ppid=,comm=,args=").Output()
	if err != nil {
		return out
	}
	sc := bufio.NewScanner(bytes.NewReader(ps))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 3 {
			continue
		}
		if filepath.Base(f[1]) != "ssh" {
			continue
		}
		ppid, err := strconv.Atoi(f[0])
		if err != nil {
			continue
		}
		if host := sshHost(f[3:]); host != "" {
			out[ppid] = host
		}
	}
	return out
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
