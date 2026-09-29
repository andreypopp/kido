package e2e

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// layoutNoise removes everything a layout string carries that depends on
// the terminal size or the pane ids, leaving the tree structure.
var layoutNoise = regexp.MustCompile(`[0-9]+`)

func normalizeLayout(s string) string { return layoutNoise.ReplaceAllString(s, "") }

type windowShape struct {
	session string
	name    string
	panes   int
	layout  string
}

func shapes(t *testing.T, socket string) []windowShape {
	t.Helper()
	cmd := exec.Command(tmuxBin, "-L", socket, "list-panes", "-a", "-F",
		"#{session_name}\t#{window_index}\t#{window_name}\t#{window_layout}")
	cmd.Env = cleanEnv("TMUX=")
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

func TestSnapshotReplays(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.in("split-window", "-d", "-t", "alpha:")
	h.in("new-window", "-d", "-t", "alpha:", "-n", "editor")
	h.newSession("beta")
	resume := h.claudePane("beta", "✳ Resumable")
	h.claudePane("beta", "✳ Fresh")
	h.hook("sess-resume", resume, "SessionStart")
	h.waitGlyph("Resumable", "")

	// Resumes by its own session id too, like a hooked Claude pane.
	piPane := h.piPane("beta", "π - resumable - kido")
	h.agentStatus("pi-resume", piPane, "pi", "idle")
	h.waitGlyph("resumable - kido", "")

	// A window is named after the client that created it until tmux renames
	// it to its pane's command a moment later; wait for that to settle, or
	// a snapshot taken in between records "tmux" as the window name.
	var prev []windowShape
	h.waitFor(func() bool {
		now := shapes(t, h.inner)
		settled := prev != nil && slices.Equal(prev, now)
		prev = now
		time.Sleep(200 * time.Millisecond)
		return settled
	}, settle, func() string { return fmt.Sprintf("a steady server (shapes are %+v)", shapes(t, h.inner)) })

	// kido snapshot talks to the server named by $TMUX.
	tmuxEnv := h.in("display-message", "-p", "#{socket_path},#{pid},0")
	cmd := exec.Command(kidoBin, "snapshot")
	// No KIDO_TMUX: resolved through the kido-tmux sibling setup() symlinks
	// next to kidoBin, the resolution a real install ships.
	cmd.Env = cleanEnv("TMUX="+tmuxEnv, "KIDO_STATE_DIR="+h.stateDir)
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
	if !strings.Contains(script, "pi --session pi-resume") {
		t.Errorf("snapshot does not resume the reported pi pane:\n%s", script)
	}

	// Neither claude nor real pi is available in CI, and the assertions
	// above already checked the commands the script would have run: run
	// "true" for both instead. Anchored on the trailing " Enter" send-keys
	// always writes, so this only touches a send-keys command line, not a
	// bare "claude" window name a -n flag may carry.
	replay := regexp.MustCompile(`'(claude|pi)(?: [^']*)?' Enter`).ReplaceAllString(script, "'true' Enter")
	path := filepath.Join(h.dir, "replay.sh")
	if err := os.WriteFile(path, []byte(replay), 0o755); err != nil {
		t.Fatal(err)
	}

	third := strings.Replace(h.inner, "kido-i-", "kido-3-", 1)
	t.Cleanup(func() { killServer(third) })

	run := exec.Command("/bin/sh", path)
	run.Env = cleanEnv("TMUX=", "TMUX_BIN="+tmuxBin+" -f /dev/null -L "+third)
	if b, err := run.CombinedOutput(); err != nil {
		t.Fatalf("replay: %v\n%s\nscript:\n%s", err, b, replay)
	}

	want, got := shapes(t, h.inner), shapes(t, third)
	if len(want) != 6 { // alpha: split window and "editor"; beta: shell, two claude windows, pi window
		t.Fatalf("the source server has %d windows, want 6: %+v", len(want), want)
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
