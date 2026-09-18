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
