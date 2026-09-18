// Package procs looks up process details tmux does not report.
package procs

import (
	"bufio"
	"bytes"
	"os/exec"
	"strconv"
	"strings"
)

// SSHHosts returns, for each of the given pane shell pids that has an ssh
// child, the destination ssh was started for ("user@host" or "host").
func SSHHosts(panePIDs []int) map[int]string {
	out := map[int]string{}
	if len(panePIDs) == 0 {
		return out
	}
	want := map[int]bool{}
	for _, pid := range panePIDs {
		want[pid] = true
	}
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
		ppid, err := strconv.Atoi(f[0])
		if err != nil || !want[ppid] {
			continue
		}
		if f[1] != "ssh" && !strings.HasSuffix(f[1], "/ssh") {
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
