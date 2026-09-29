package procs

import (
	"slices"
	"testing"
)

// macOSFixture is real `ps -axo pid=,ppid=,comm=,args=` output captured
// on macOS: comm is truncated to 16 characters.
const macOSFixture = `49417 71584 /bin/zsh         /bin/zsh -c source /Users/andrepopp/.claude/shell-snapshots/snapshot-zsh-1789943097813-ct8v62.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL 2>/dev/null || true
49420 49417 /bin/zsh         /bin/zsh -c source /Users/andrepopp/.claude/shell-snapshots/snapshot-zsh-1789943097813-ct8v62.sh 2>/dev/null || true
24619 64101 zsh              zsh
24710 24619 claude           claude
24003  1296 zsh              zsh --login
24089 24003 ssh              ssh ahrefs/devbox-uk -t zsh -i -c 's '
71584 64129 claude           claude --continue
`

// linuxFixture is a hand-written, synthetic stand-in for `ps
// -axo pid=,ppid=,comm=,args=` output on Linux, where comm is the bare
// executable name and pi's bash shim execs node in place, so the outer
// pid shows "node" while args names pi's script.
const linuxFixture = `  600   500 bash     bash /opt/homebrew/Cellar/pi/1.2/libexec/bin/pi
  700   600 node     node /opt/homebrew/Cellar/pi/1.2/libexec/bin/pi
  500     1 zsh      zsh
`

func TestParseProcesses(t *testing.T) {
	t.Run("real macOS output, args with embedded spaces", func(t *testing.T) {
		all, parent := parseProcesses(splitPSFields([]byte(macOSFixture)))
		if len(all) != 7 {
			t.Fatalf("got %d rows, want 7", len(all))
		}
		if all[0].pid != 49417 || all[0].ppid != 71584 {
			t.Errorf("row 0 = %+v, want pid 49417 ppid 71584", all[0])
		}
		if parent[49417] != 71584 || parent[24710] != 24619 {
			t.Errorf("parent map = %v, missing expected entries", parent)
		}
		if len(all[0].args) < 5 {
			t.Errorf("args = %v, want the zsh -c payload split into several fields", all[0].args)
		}
		if all[0].args[0] != "/bin/zsh" || all[0].args[1] != "-c" {
			t.Errorf("args[0:2] = %v, want [/bin/zsh -c]", all[0].args[0:2])
		}
	})

	t.Run("synthetic Linux output, pi behind a bash shim", func(t *testing.T) {
		all, parent := parseProcesses(splitPSFields([]byte(linuxFixture)))
		if len(all) != 3 {
			t.Fatalf("got %d rows, want 3", len(all))
		}
		pi := map[int]bool{}
		for _, p := range all {
			if isPi(p) {
				markAncestors(pi, parent, p.pid)
			}
		}
		for _, pid := range []int{600, 700, 500} {
			if !pi[pid] {
				t.Errorf("pid %d not marked as behind pi", pid)
			}
		}
	})

	t.Run("a command whose comm field itself has a leading path with spaces", func(t *testing.T) {
		all, _ := parseProcesses(splitPSFields([]byte("  10    1 My App    /Applications/My App.app/Contents/MacOS/My App --flag\n")))
		if len(all) != 1 {
			t.Fatalf("got %d rows, want 1", len(all))
		}
		if all[0].comm != "My" {
			t.Errorf("comm = %q, want the field after ppid (\"My\"), showing the misalignment", all[0].comm)
		}
	})

	t.Run("missing or malformed rows are skipped", func(t *testing.T) {
		in := "PID PPID COMM ARGS\n" + // a stray header-shaped line: non-numeric pid
			"  1 launchd\n" + // too few fields
			"abc def comm args\n" + // non-numeric pid and ppid
			"  99   1 sh sh -c true\n" // one well-formed row
		all, parent := parseProcesses(splitPSFields([]byte(in)))
		if len(all) != 1 || all[0].pid != 99 {
			t.Fatalf("got %+v, want exactly the one well-formed row", all)
		}
		if parent[99] != 1 {
			t.Errorf("parent[99] = %d, want 1", parent[99])
		}
	})
}

func TestParseSSHSplitsAtTheDestination(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		opts    []string
		dest    string
		command []string
	}{
		{"bare", []string{"host"}, nil, "host", nil},
		{"user@host", []string{"deploy@host"}, nil, "deploy@host", nil},
		{"flag then host", []string{"-A", "host"}, []string{"-A"}, "host", nil},
		{"bundled flags", []string{"-tt", "host"}, []string{"-tt"}, "host", nil},
		{"separate value", []string{"-o", "BatchMode=yes", "host"},
			[]string{"-o", "BatchMode=yes"}, "host", nil},
		{"attached value", []string{"-oBatchMode=yes", "host"},
			[]string{"-oBatchMode=yes"}, "host", nil},
		{"attached port", []string{"-p2222", "host"}, []string{"-p2222"}, "host", nil},
		{"-P port then host", []string{"-P", "2222", "host"},
			[]string{"-P", "2222"}, "host", nil},
		{"value after bundle", []string{"-4p", "2222", "host"},
			[]string{"-4p", "2222"}, "host", nil},
		{"remote command", []string{"host", "uptime", "-a"}, nil, "host", []string{"uptime", "-a"}},
		{"no destination", []string{"-V"}, []string{"-V"}, "", nil},
		{"nothing", nil, nil, "", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := ParseSSH(c.args)
			if !slices.Equal(in.Opts, c.opts) {
				t.Errorf("opts = %q, want %q", in.Opts, c.opts)
			}
			if in.Dest != c.dest {
				t.Errorf("dest = %q, want %q", in.Dest, c.dest)
			}
			if !slices.Equal(in.Command, c.command) {
				t.Errorf("command = %q, want %q", in.Command, c.command)
			}
		})
	}
}

func TestSSHSession(t *testing.T) {
	for _, c := range []struct {
		args []string
		host string
		want bool // interactive
	}{
		{[]string{"myhost"}, "myhost", true},
		{[]string{"myhost", "make", "build"}, "myhost", false},
		{[]string{"-t", "myhost", "make", "build"}, "myhost", true},
		{[]string{"-tt", "myhost", "tail", "-f", "log"}, "myhost", true},
		{[]string{"-T", "myhost", "make"}, "myhost", false},
		{[]string{"-T", "myhost"}, "myhost", false},
		{[]string{"-N", "-L", "8080:x:80", "myhost"}, "myhost", true},
		{[]string{"-p", "2222", "user@box"}, "user@box", true},
		{[]string{"-p", "2222", "user@box", "uptime"}, "user@box", false},
		{[]string{"-p2222", "box"}, "box", true},
		{[]string{"-p2222", "box", "uptime"}, "box", false},
		{[]string{"-J", "jump", "-i", "key", "-o", "X=y", "dest"}, "dest", true},
		{[]string{"-v", "-A", "root@1.2.3.4", "uptime"}, "root@1.2.3.4", false},
		{[]string{"ssh://me@h:22"}, "me@h:22", true},
		{[]string{"-L", "8080:x:80", "--", "h"}, "h", true},
		{[]string{"--", "h", "uptime"}, "h", false},
		{[]string{"-oProxyCommand=nc -T -N %h %p", "h"}, "h", true},
		{[]string{"-v", "-p", "2222"}, "", false},
		{nil, "", false},
	} {
		got := sshSession(c.args)
		if got.Host != c.host || got.Interactive != c.want {
			t.Errorf("%v: got (%q, %v) want (%q, %v)",
				c.args, got.Host, got.Interactive, c.host, c.want)
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
	markAncestors(map[int]bool{}, map[int]int{2: 3, 3: 2}, 2)
}
