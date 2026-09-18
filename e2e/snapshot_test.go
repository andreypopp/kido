package e2e

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// layoutNoise removes everything a layout string carries that depends on
// the terminal size or the pane ids, leaving the tree structure.
var layoutNoise = regexp.MustCompile(`[0-9]+`)

func normalizeLayout(s string) string { return layoutNoise.ReplaceAllString(s, "") }

// windowShape is one window as the comparison sees it.
type windowShape struct {
	session string
	name    string
	panes   int
	layout  string
}

// shapes lists the windows of a tmux server in order.
func shapes(t *testing.T, socket string) []windowShape {
	t.Helper()
	cmd := exec.Command(tmuxBin, "-L", socket, "list-panes", "-a", "-F",
		"#{session_name}\t#{window_index}\t#{window_name}\t#{window_layout}")
	cmd.Env = append(os.Environ(), "TMUX=")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("list-panes on %s: %v", socket, err)
	}
	var list []windowShape
	seen := map[string]int{}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		f := strings.SplitN(line, "\t", 4)
		if len(f) < 4 {
			continue
		}
		key := f[0] + "\t" + f[1]
		if i, ok := seen[key]; ok {
			list[i].panes++
			continue
		}
		seen[key] = len(list)
		list = append(list, windowShape{session: f[0], name: f[2], panes: 1,
			layout: normalizeLayout(f[3])})
	}
	return list
}

// TestSnapshotReplays captures the inner server with `kido snapshot` and
// replays the script onto a third, empty server, then compares the two.
func TestSnapshotReplays(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// A layout worth recreating: a split, a second window, and two Claude
	// panes, one of which has hook state (so it resumes by session id).
	h.in("split-window", "-d", "-t", "alpha:")
	h.in("new-window", "-d", "-t", "alpha:", "-n", "editor")
	h.newSession("beta")
	resume := h.claudePane("beta", "✳ Resumable")
	h.claudePane("beta", "✳ Fresh")
	h.hook("sess-resume", resume, "SessionStart")
	h.waitGlyph("Resumable", "○")

	// kido snapshot talks to the server named by $TMUX.
	tmuxEnv := h.in("display-message", "-p", "#{socket_path},#{pid},0")
	cmd := exec.Command(kidoBin, "snapshot")
	cmd.Env = append(os.Environ(), "TMUX="+tmuxEnv, "KIDO_STATE_DIR="+h.stateDir)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("kido snapshot: %v\n%s", err, errb.String())
	}
	script := string(out)

	if !strings.Contains(script, "claude --resume sess-resume") {
		t.Errorf("snapshot does not resume the hooked pane:\n%s", script)
	}
	if !strings.Contains(script, "claude --continue") {
		t.Errorf("snapshot does not continue the unhooked claude pane:\n%s", script)
	}

	// There is no claude here: run "true" instead, keeping everything else.
	replay := regexp.MustCompile(`'claude --[^']*'`).ReplaceAllString(script, "'true'")
	path := filepath.Join(h.dir, "replay.sh")
	if err := os.WriteFile(path, []byte(replay), 0o755); err != nil {
		t.Fatal(err)
	}

	third := strings.Replace(h.inner, "kido-i-", "kido-3-", 1)
	t.Cleanup(func() { killServer(third) })

	run := exec.Command("/bin/sh", path)
	run.Env = append(os.Environ(), "TMUX=", "TMUX_BIN="+tmuxBin+" -f /dev/null -L "+third)
	if b, err := run.CombinedOutput(); err != nil {
		t.Fatalf("replay: %v\n%s\nscript:\n%s", err, b, replay)
	}

	want, got := shapes(t, h.inner), shapes(t, third)
	// alpha: the split window and "editor"; beta: its shell and two
	// claude windows.
	if len(want) != 5 {
		t.Fatalf("the source server has %d windows, want 5: %+v", len(want), want)
	}
	if want[0].panes != 2 {
		t.Fatalf("alpha's first window has %d panes, want 2", want[0].panes)
	}
	if len(want) != len(got) {
		t.Fatalf("recreated %d windows, want %d\nwant %+v\ngot %+v", len(got), len(want), want, got)
	}
	for i := range want {
		w, g := want[i], got[i]
		if w.session != g.session || w.name != g.name || w.panes != g.panes {
			t.Errorf("window %d: got %+v, want %+v", i, g, w)
		}
		if w.layout != g.layout {
			t.Errorf("window %d (%s:%s) layout:\n got %s\nwant %s", i, w.session, w.name, g.layout, w.layout)
		}
	}
}
