package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestKidoSeparateServerAndState(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	pane := r.primedPane()
	first := r.mustServer("")
	app := *r
	app.state = serverDir(t)
	app.kidoSock = filepath.Join(app.state, "socket")
	watchSocketPath(app.kidoSock)
	t.Cleanup(func() { app.kido("kill-session", "-t", "main") })
	app.launch("app")
	app.waitUp()
	appPane := app.firstPane()
	app.waitFor(func() bool {
		return reportedPrompt(app.mustKido("display-message", "-p", "-t", appPane, "#{pane_last_prompt_time}"))
	}, "the app pane's prompt")
	second := app.mustServer("")
	if first.Socket == second.Socket || first.Protocol != second.Protocol || first.Server != second.Server {
		t.Fatalf("endpoints: %+v, %+v", first, second)
	}
	if pane != appPane {
		t.Fatalf("pane ids = %s and %s, want a collision to test state isolation", pane, appPane)
	}
	for _, server := range []*kidoRun{r, &app} {
		if got := server.shellIn(pane, "printf '%s' \"$KIDO_STATE_DIR$KIDO_RUN_ID\""); got != "" {
			t.Errorf("pane state and caller environment = %q, want absent", got)
		}
		if _, err := os.Stat(filepath.Join(server.state, "server.conf")); err != nil {
			t.Fatal(err)
		}
		if got := server.shellIn(pane, "tmux display-message -p '#{socket_path}'"); got != server.mustServer("").Socket {
			t.Errorf("pane reaches %q, want %s", got, server.kidoSock)
		}
		if got := server.shellIn(pane, "KIDO_STATE_DIR=/must-not-use kido run --name isolated -- /bin/true >/dev/null; echo $?"); got != "0" {
			t.Fatalf("run: %q", got)
		}
		if out := server.shellIn(pane, "KIDO_STATE_DIR=/must-not-use kido run --name isolated -- /bin/true"); !strings.Contains(out, server.state+"/runs/") {
			t.Fatalf("the run did not use the server's own state: %q", out)
		}
	}
	if r.realClients() != 1 || app.realClients() != 1 {
		t.Fatal("both servers must still have their own attached client")
	}
}
