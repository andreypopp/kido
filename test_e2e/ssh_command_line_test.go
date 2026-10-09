package e2e

import (
	"testing"
)

// OSC 133 markers cross the connection and land on the local pane - the
// whole basis of kido's remote shell status - so the row must name the
// far side's running command as well as the destination.
//
func TestSSHRowShowsRemoteCommandLine(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	script := "{ sleep 1; printf '\\033]133;C\\007';" +
		" sleep 2; printf '\\033]133;A\\007';" +
		" sleep 1; printf '\\033]133;C;cmdline=sleep 45\\007'; } >/dev/tty &\n" +
		"exec " + kidoBin + " ssh -F /dev/null -o ProxyCommand=" + h.sshProxy() + " deploy@example.test\n"
	h.newWindow("alpha", "", "sh", "-c", script)
	h.waitRow("ssh deploy@example.test")
	h.waitRow("ssh deploy@example.test: sleep 45")
}
