package e2e

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestStateReportingOutsideTmux(t *testing.T) {
	t.Parallel()
	for _, tool := range []string{"agent-status"} {
		t.Run(tool, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.Chmod(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(kidoBin, tool)
			cmd.Env = cleanEnv("KIDO_STATE_DIR=" + dir)
			cmd.Args = append(cmd.Args, "--agent", "pi", "--session", "outside")
			if out, err := cmd.CombinedOutput(); err != nil || len(out) != 0 {
				t.Fatalf("%s outside tmux = %v %q", tool, err, out)
			}
			raw, err := os.ReadFile(filepath.Join(dir, "outside.json"))
			if err != nil {
				t.Fatal(err)
			}
			var state struct {
				Pane string `json:"pane"`
			}
			if err := json.Unmarshal(raw, &state); err != nil || state.Pane != "" {
				t.Fatalf("pane-less state = %s: %v", raw, err)
			}
			cmd = exec.Command(kidoBin, "get-agent", "outside")
			cmd.Env = cleanEnv("KIDO_STATE_DIR=" + dir)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("get-agent = %v %q", err, out)
			}
			var agent struct {
				Alive bool `json:"alive"`
			}
			if err := json.Unmarshal(out, &agent); err != nil || !agent.Alive {
				t.Fatalf("pane-less state did not load: %q, %v", out, err)
			}
		})
	}
}
