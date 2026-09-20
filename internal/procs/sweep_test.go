package procs

import "testing"

func TestSSHHost(t *testing.T) {
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"myhost"}, "myhost"},
		{[]string{"-p", "2222", "user@box"}, "user@box"},
		{[]string{"-p2222", "box"}, "box"},
		{[]string{"-J", "jump", "-i", "key", "-o", "X=y", "dest"}, "dest"},
		{[]string{"-v", "-A", "root@1.2.3.4", "uptime"}, "root@1.2.3.4"},
		{[]string{"ssh://me@h:22"}, "me@h:22"},
		{[]string{"-L", "8080:x:80", "--", "h"}, "h"},
	} {
		if got := sshHost(c.args); got != c.want {
			t.Errorf("%v: got %q want %q", c.args, got, c.want)
		}
	}
}

func TestIsPi(t *testing.T) {
	for _, c := range []struct {
		name string
		args []string
		want bool
	}{
		{"the node behind the shim", []string{"node", "/opt/homebrew/Cellar/pi/1.2/libexec/bin/pi"}, true},
		{"the bash shim", []string{"bash", "/opt/homebrew/Cellar/pi/1.2/libexec/bin/pi", "--help"}, true},
		{"running as itself", []string{"/opt/homebrew/bin/pi"}, true},
		{"a plain node", []string{"node", "server.js"}, false},
		{"a path that only mentions pi", []string{"node", "/src/pizza/bin/index.js"}, false},
		{"no arguments", nil, false},
	} {
		if got := isPi(process{args: c.args}); got != c.want {
			t.Errorf("%s: isPi(%v) = %v, want %v", c.name, c.args, got, c.want)
		}
	}
}

func TestMarkAncestors(t *testing.T) {
	// 1 <- 500 (the pane's shell) <- 600 (the pi shim) <- 700 (node).
	parent := map[int]int{700: 600, 600: 500, 500: 1}
	set := map[int]bool{}
	markAncestors(set, parent, 700)
	for _, pid := range []int{700, 600, 500} {
		if !set[pid] {
			t.Errorf("pid %d not marked", pid)
		}
	}
	if set[1] {
		t.Error("pid 1 marked: every pane would look like pi")
	}
	// A ppid cycle must not hang the sweep.
	markAncestors(map[int]bool{}, map[int]int{2: 3, 3: 2}, 2)
}
