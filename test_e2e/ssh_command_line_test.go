package e2e

import (
	"testing"
)

// OSC 133 markers cross the connection and land on the local pane - the
// whole basis of kido's remote shell status - so the row must name the
// far side's running command as well as the destination.
//
// The markers are written to the pane's tty by a background subshell,
// and ssh is exec'd into the foreground: kido only asks the process table
// about a pane whose foreground command is ssh, so a backgrounded ssh is
// invisible to it. What the subshell writes is the sequence the two
// shells would produce between them - the local 133;C for the ssh itself,
// the far side's first prompt a second later, which is what unlatches the
// remote reading, and then a remote command with its command line.
func TestSSHRowShowsRemoteCommandLine(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	script := "{ sleep 1; printf '\\033]133;C\\007';" +
		" sleep 2; printf '\\033]133;A\\007';" +
		" sleep 1; printf '\\033]133;C;cmdline=sleep 45\\007'; } >/dev/tty &\n" +
		"exec ssh -F /dev/null -o ProxyCommand=" + h.sshProxy() + " deploy@example.test\n"
	h.newWindow("alpha", "", "sh", "-c", script)
	h.waitRow("ssh deploy@example.test")
	h.waitRow("ssh deploy@example.test: sleep 45")
}
