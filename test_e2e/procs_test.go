package e2e

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"testing"
)

func TestSnapshotFindsOnlyPiRootApp(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	for _, script := range []string{"/opt/pi/libexec/bin/pi", "/src/pizza/bin/index.js"} {
		pane := h.newWindow("alpha", "")
		h.in("send-keys", "-t", pane, fmt.Sprintf("%q %s", nodeBin, script), "Enter")
		h.waitPaneCommand(pane, "node")
		if script == "/src/pizza/bin/index.js" {
			h.programStatus(pane, "state=idle:app=pi")
		}
	}

	cmd := exec.Command(kidoBin, "snapshot")
	cmd.Env = cleanEnv("TMUX="+h.in("display-message", "-p", "#{socket_path},#{pid},0"),
		"KIDO_STATE_DIR="+h.stateDir)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("kido snapshot: %v\n%s", err, errb.String())
	}
	if n := strings.Count(string(out), "'pi' Enter"); n != 1 {
		t.Errorf("snapshot restarts %d pi panes, want the one with the pi root app:\n%s", n, out)
	}
}
