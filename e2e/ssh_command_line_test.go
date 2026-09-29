package e2e

import (
	"testing"
)

// TestSSHRowShowsRemoteCommandLine drives one ssh pane whose far side
// reports OSC 133 - the markers cross the connection and land on the
// local pane, which is the whole basis of kido's remote shell status -
// and expects the row to name the command the far side is running as well
// as the destination.
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
