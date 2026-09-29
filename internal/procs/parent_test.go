package procs

import (
	"testing"
)

func TestParseParent(t *testing.T) {
	for _, c := range []struct {
		name     string
		rows     [][]string
		wantPpid int
		wantComm string
		wantOk   bool
	}{
		{"well formed", [][]string{{"71584", "zsh"}}, 71584, "zsh", true},
		{"no rows (bad pid, or the process is gone)", nil, 0, "", false},
		{"too few fields", [][]string{{"71584"}}, 0, "", false},
		{"non-numeric ppid", [][]string{{"abc", "zsh"}}, 0, "", false},
	} {
		ppid, comm, ok := parseParent(c.rows)
		if ppid != c.wantPpid || comm != c.wantComm || ok != c.wantOk {
			t.Errorf("%s: parseParent(%v) = %d, %q, %v; want %d, %q, %v",
				c.name, c.rows, ppid, comm, ok, c.wantPpid, c.wantComm, c.wantOk)
		}
	}
}

func TestIsShell(t *testing.T) {
	for _, c := range []struct {
		comm string
		want bool
	}{
		{"sh", true},
		{"/bin/sh", true},
		{"dash", true},
		{"bash", true},
		{"zsh", true},
		{"ksh", true},
		{"claude", false},
		{"node", false},
		{"", false},
	} {
		if got := isShell(c.comm); got != c.want {
			t.Errorf("isShell(%q) = %v, want %v", c.comm, got, c.want)
		}
	}
}
