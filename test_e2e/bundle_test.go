package e2e

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestKidoSeparateServerAndState(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	pane := r.primedPane()
	first := r.mustServer("")
	app := *r
	app.state = filepath.Join(r.dir, "app-state")
	app.kidoSock = socketPath(r.tmpdir, "kido-app")
	watchSocketIn(r.tmpdir, "kido-app")
	t.Cleanup(func() { app.kido("kill-session", "-t", "main") })
	app.launch("app")
	app.waitUp()
	appPane := app.firstPane()
	app.waitFor(func() bool {
		return reportedPrompt(app.mustKido("display-message", "-p", "-t", appPane, "#{pane_last_prompt_time}"))
	}, "the app pane's prompt")
	second := app.mustServer("")
	if first.Socket == second.Socket || first.Build != second.Build {
		t.Fatalf("endpoints: %+v, %+v", first, second)
	}
	if pane != appPane {
		t.Fatalf("pane ids = %s and %s, want a collision to test state isolation", pane, appPane)
	}
	for _, server := range []*kidoRun{r, &app} {
		if got := server.mustKido("show-environment", "-g", "KIDO_STATE_DIR"); got != "KIDO_STATE_DIR="+server.state {
			t.Errorf("global state environment = %q", got)
		}
		if _, err := os.Stat(filepath.Join(server.state, "server.conf")); err != nil {
			t.Fatal(err)
		}
		if got := server.shellIn(pane, "tmux display-message -p '#{socket_path}'"); got != server.mustServer("").Socket {
			t.Errorf("pane reaches %q, want %s", got, server.kidoSock)
		}
		if got := server.shellIn(pane, "kido agent-status --agent pi --session isolated --status running; echo $?"); got != "0" {
			t.Fatalf("agent-status: %q", got)
		}
		body, err := os.ReadFile(filepath.Join(server.state, "isolated.json"))
		if err != nil {
			t.Fatal(err)
		}
		var record struct {
			Pane string `json:"pane"`
		}
		if err := json.Unmarshal(body, &record); err != nil || record.Pane != pane {
			t.Fatalf("state = %s (%v), want pane %s", body, err, pane)
		}
	}
	if r.realClients() != 1 || app.realClients() != 1 {
		t.Fatal("both servers must still have their own attached client")
	}
}
