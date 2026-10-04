package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"testing"
)

func withoutLocale(env []string) []string {
	var out []string
	for _, kv := range env {
		if !strings.HasPrefix(kv, "LANG=") && !strings.HasPrefix(kv, "LANGUAGE=") && !strings.HasPrefix(kv, "LC_") && !strings.HasPrefix(kv, "TMUX=") {
			out = append(out, kv)
		}
	}
	return out
}

func TestServerWithoutLocale(t *testing.T) {
	requireTmux(t)
	env := withoutLocale(launcherEnv(t))
	var first string
	t.Cleanup(func() {
		cmd := exec.Command(tmuxBin, "-u", "-S", first, "kill-session", "-t", "main")
		cmd.Env = env
		cmd.Run()
	})
	for i := 0; i < 2; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), settle)
		cmd := exec.CommandContext(ctx, kidoBin, "server")
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		cancel()
		if err != nil {
			t.Fatalf("server call %d without locale: %v: %s", i+1, err, out)
		}
		var endpoint struct {
			Socket string `json:"socket"`
		}
		if err := json.Unmarshal(out, &endpoint); err != nil || endpoint.Socket == "" {
			t.Fatalf("invalid endpoint: %s (%v)", out, err)
		}
		if i == 0 {
			first = endpoint.Socket
		} else if endpoint.Socket != first {
			t.Fatalf("server changed socket: %q != %q", endpoint.Socket, first)
		}
	}
}

func TestSidebarFeedWithoutLocale(t *testing.T) {
	h := start(t, "alpha")
	const name = "日本語 café"
	h.in("rename-window", "-t", "alpha:", name)
	h.in("split-window", "-d", "-t", "alpha:")
	cmd := feedCmd(h, "--server", h.stateDir, "--client", h.appClient("alpha"))
	cmd.Env = withoutLocale(cmd.Env)
	cmd.Stdin = strings.NewReader("")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("sidebar-feed without locale: %v: %s", err, &stderr)
	}
	var snapshot feedSnapshot
	if err := json.Unmarshal(bytes.TrimSpace(out), &snapshot); err != nil {
		t.Fatalf("invalid feed: %s (%v)", out, err)
	}
	if snapshot.Error != nil || len(snapshot.Sessions) != 1 || len(snapshot.Sessions[0].Nodes) != 1 || snapshot.Sessions[0].Nodes[0].Name != name || len(snapshot.Sessions[0].Nodes[0].Children) != 2 {
		t.Fatalf("locale-free feed lost pane formats or UTF-8 name: %s", out)
	}
}
