package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// pi as Homebrew installs it, a script at libexec/bin/pi that node runs,
// typed at the pane's shell: the pane's own process is only an ancestor of
// the one naming pi. A node running anything else is no pi.
func TestSnapshotFindsPiBehindItsShim(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	for _, script := range []string{"/opt/pi/libexec/bin/pi", "/src/pizza/bin/index.js"} {
		pane := h.newWindow("alpha", "")
		h.in("send-keys", "-t", pane, fmt.Sprintf("%q %s", nodeBin, script), "Enter")
		h.waitPaneCommand(pane, "node")
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
		t.Errorf("snapshot restarts %d pi panes, want the one behind the shim:\n%s", n, out)
	}
}

// Claude Code runs `sh -c "kido hook"`, and a shell that does not exec its
// last command leaves a shell as kido's parent: the pid recorded is the
// first process past up to three of them.
func TestHookRecordsTheProcessPastWrappingShells(t *testing.T) {
	t.Parallel()
	state := serverDir(t)
	script := fmt.Sprintf("%q hook; :", kidoBin)
	for depth := 1; depth <= 3; depth++ {
		id := fmt.Sprintf("wrapped-%d", depth)
		cmd := exec.Command("/bin/sh", "-c", script)
		cmd.Stdin = strings.NewReader(`{"hook_event_name":"UserPromptSubmit","session_id":"` + id + `"}`)
		cmd.Env = cleanEnv("TMUX_PANE=%1", "KIDO_STATE_DIR="+state)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s: %v\n%s", script, err, out)
		}
		var rec struct{ Pid int }
		body, err := os.ReadFile(filepath.Join(state, id+".json"))
		if err == nil {
			err = json.Unmarshal(body, &rec)
		}
		if err != nil || rec.Pid != os.Getpid() {
			t.Errorf("under %d shells: recorded %q (%v), want pid %d", depth, body, err, os.Getpid())
		}
		script = fmt.Sprintf("sh -c %q; :", script)
	}
}
