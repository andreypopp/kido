package e2e

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"
)

type feedSpan struct {
	Text string `json:"text"`
	Role string `json:"role"`
}

type feedRow struct {
	Pane      *string `json:"pane"`
	Window    *string `json:"window"`
	Tree      string  `json:"tree"`
	Indicator *struct {
		Kind    string  `json:"kind"`
		Outcome *string `json:"outcome"`
	} `json:"indicator"`
	Title     []feedSpan `json:"title"`
	Tail      []feedSpan `json:"tail"`
	Attention bool       `json:"attention"`
}

type feedSnapshot struct {
	V      int `json:"v"`
	Client struct {
		Session string `json:"session"`
		Window  string `json:"window"`
		Pane    string `json:"pane"`
	} `json:"client"`
	Filter   string  `json:"filter"`
	Error    *string `json:"error"`
	Sessions []struct {
		ID      string    `json:"id"`
		Name    string    `json:"name"`
		Current bool      `json:"current"`
		Rows    []feedRow `json:"rows"`
	} `json:"sessions"`
	raw string
}

// feedGlyph is the TUI's indicator table (Ui.glyph), so a snapshot can be
// drawn the way the sidebar draws it and compared row for row.
func feedGlyph(r feedRow) string {
	if r.Indicator == nil {
		return " "
	}
	switch r.Indicator.Kind {
	case "running", "failed":
		return "◼"
	case "waiting":
		return "◆"
	case "compacting":
		return "◌"
	case "idle":
		return " "
	case "unknown":
		return "?"
	case "done":
		return "✓"
	case "stalled":
		return "!"
	case "gone":
		if r.Indicator.Outcome != nil && *r.Indicator.Outcome == "completed" {
			return "✓"
		}
		return "×"
	}
	return "<" + r.Indicator.Kind + ">"
}

func (s feedSnapshot) drawn() []string {
	var out []string
	text := func(spans []feedSpan) string {
		var b strings.Builder
		for _, sp := range spans {
			b.WriteString(sp.Text)
		}
		return b.String()
	}
	for _, sess := range s.Sessions {
		out = append(out, sess.Name)
		for _, r := range sess.Rows {
			out = append(out, strings.TrimSpace(r.Tree+feedGlyph(r)+" "+text(r.Title)+text(r.Tail)))
		}
	}
	return out
}

// feed is a running `kido sidebar-feed` for an app-like control client
// of the inner server: its own `tmux -C` attached to session, the way
// Kido.app attaches one.
type feed struct {
	h      *harness
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stderr *bytes.Buffer
	client string
	mu     sync.Mutex
	lines  []feedSnapshot
	done   chan error
}

func (h *harness) appClient(session string) string {
	h.t.Helper()
	app := exec.Command(tmuxBin, "-S", socketPath("", h.inner), "-C", "attach-session", "-t", session)
	app.Env = cleanEnv("TMUX=")
	in, err := app.StdinPipe()
	if err != nil {
		h.t.Fatal(err)
	}
	if err := app.Start(); err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() {
		in.Close()
		app.Process.Kill()
		app.Wait()
	})
	var name string
	h.waitFor(func() bool {
		for _, line := range strings.Split(h.in("list-clients", "-F", "#{client_pid}\t#{client_name}"), "\n") {
			if pid, n, _ := strings.Cut(line, "\t"); pid == fmt.Sprint(app.Process.Pid) {
				name = n
				return true
			}
		}
		return false
	}, settle, msgf("the app's control client to attach"))
	return name
}

func feedCmd(h *harness, args ...string) *exec.Cmd {
	cmd := exec.Command(kidoBin, append([]string{"sidebar-feed"}, args...)...)
	// The knobs the inner server gives its own sidebar, so both agree.
	cmd.Env = cleanEnv("TMUX=", "TMUX_PANE=", "KIDO_STATE_DIR="+h.stateDir,
		"KIDO_LINGER_SECONDS=1", "KIDO_STALL_THRESHOLD_MS=3000")
	return cmd
}

func (h *harness) startFeed(session string) *feed {
	h.t.Helper()
	f := &feed{h: h, client: h.appClient(session), stderr: &bytes.Buffer{}, done: make(chan error, 1)}
	f.cmd = feedCmd(h, "--socket", socketPath("", h.inner), "--client", f.client)
	f.cmd.Stderr = f.stderr
	var err error
	if f.stdin, err = f.cmd.StdinPipe(); err != nil {
		h.t.Fatal(err)
	}
	out, err := f.cmd.StdoutPipe()
	if err != nil {
		h.t.Fatal(err)
	}
	if err := f.cmd.Start(); err != nil {
		h.t.Fatal(err)
	}
	go func() {
		sc := bufio.NewScanner(out)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			var s feedSnapshot
			if err := json.Unmarshal(sc.Bytes(), &s); err != nil {
				s.V = -1
			}
			s.raw = sc.Text()
			f.mu.Lock()
			f.lines = append(f.lines, s)
			f.mu.Unlock()
		}
		f.done <- f.cmd.Wait()
	}()
	h.t.Cleanup(func() {
		f.stdin.Close()
		select {
		case <-f.done:
		case <-time.After(settle):
			f.cmd.Process.Kill()
		}
	})
	return f
}

func (f *feed) count() int { f.mu.Lock(); defer f.mu.Unlock(); return len(f.lines) }

func (f *feed) last() feedSnapshot {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.lines) == 0 {
		return feedSnapshot{}
	}
	return f.lines[len(f.lines)-1]
}

func (f *feed) waitLast(cond func(feedSnapshot) bool, describe string) feedSnapshot {
	f.h.t.Helper()
	f.h.waitFor(func() bool { return f.count() > 0 && cond(f.last()) }, settle,
		func() string { return fmt.Sprintf("%s; last line %s; stderr %q", describe, f.last().raw, f.stderr) })
	return f.last()
}

func (f *feed) send(line string) {
	f.h.t.Helper()
	if _, err := io.WriteString(f.stdin, line+"\n"); err != nil {
		f.h.t.Fatal(err)
	}
}

// The first snapshot is the tree the TUI draws for the same server - an
// agent, a subagent window nested under it, a lingering run - row for
// row, with the client's own ids. The comparison carries the ordering; the
// field checks pin what drawing alone cannot tell apart (a null indicator
// and an idle one both draw a blank).
func TestSidebarFeedMatchesTheTUI(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	_, childWindow := h.recordedRun("kid-e2e")
	h.asyncBash("slow-e2e", "sleep", "300")
	h.newSession("beta")
	h.waitRow("slow-e2e")

	f := h.startFeed("alpha")
	var s feedSnapshot
	h.waitFor(func() bool {
		s = f.last()
		want := h.rows()
		got := s.drawn()
		if len(got) != len(want) {
			return false
		}
		// The TUI cuts a row to its width with an ellipsis; the feed never does.
		for i := range want {
			w := strings.TrimSpace(want[i])
			if cut, ok := strings.CutSuffix(w, "…"); ok && strings.HasPrefix(got[i], cut) {
				continue
			}
			if w != got[i] {
				return false
			}
		}
		return true
	}, settle, func() string { return fmt.Sprintf("feed draws %q, TUI %q", s.drawn(), h.rows()) })

	if s.V != 1 || s.Filter != "" || s.Error != nil {
		t.Errorf("v/filter/error = %d %q %v, want 1 \"\" null: %s", s.V, s.Filter, s.Error, s.raw)
	}
	pane := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id} #{pane_id}")
	if got := s.Client.Session + " " + s.Client.Window + " " + s.Client.Pane; got != pane {
		t.Errorf("client = %q, want %q", got, pane)
	}
	if len(s.Sessions) != 2 || s.Sessions[0].Name != "alpha" || !s.Sessions[0].Current || s.Sessions[1].Current {
		t.Fatalf("sessions: %s", s.raw)
	}
	byTitle := map[string]feedRow{}
	for _, r := range s.Sessions[0].Rows {
		if r.Pane == nil || r.Window == nil || !strings.HasPrefix(*r.Pane, "%") || !strings.HasPrefix(*r.Window, "@") {
			t.Errorf("row without pane/window ids: %+v", r)
		}
		byTitle[r.Title[0].Text] = r
	}
	if r := byTitle["slow-e2e"]; r.Indicator == nil || r.Indicator.Kind != "running" {
		t.Errorf("the lingering run's row: %+v in %s", r, s.raw)
	}
	nested := false
	for _, r := range s.Sessions[0].Rows {
		if *r.Window == childWindow {
			nested = strings.HasPrefix(r.Tree, "│ ") || strings.HasPrefix(r.Tree, "  ")
			if r.Indicator == nil || r.Indicator.Kind != "idle" {
				t.Errorf("the idle subagent's indicator: %s", s.raw)
			}
		}
	}
	if !nested {
		t.Errorf("the subagent window is not nested under its parent: %s", s.raw)
	}
	if rows := s.Sessions[1].Rows; len(rows) != 1 || rows[0].Tree != "╶" || rows[0].Title[0].Role != "proc" {
		t.Errorf("beta's shell row: %s", s.raw)
	}
}

// A change is one new line; a quiet server is no line at all; the filter
// narrows the next line and a bare "filter" clears it; an unknown command
// is ignored; EOF on stdin is exit 0.
func TestSidebarFeedStream(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 }, "both sessions")

	quiet := func(why string) {
		t.Helper()
		n := f.count()
		deadline := time.Now().Add(1500 * time.Millisecond)
		for time.Now().Before(deadline) {
			if f.count() != n {
				t.Fatalf("%s: a line with nothing changed: %s", why, f.last().raw)
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	quiet("settled")

	n := f.count()
	h.newWindow("beta", "fresh")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 && len(s.Sessions[1].Rows) == 2 },
		"beta's new window")
	if f.count() <= n {
		t.Fatalf("no new line for a new window")
	}
	quiet("after the new window")

	f.send("filter bet")
	s := f.waitLast(func(s feedSnapshot) bool { return s.Filter == "bet" }, "the filter")
	if len(s.Sessions) != 1 || s.Sessions[0].Name != "beta" {
		t.Errorf("filtered sessions: %s", s.raw)
	}
	f.send("frobnicate")
	quiet("an unknown command")
	f.send("filter")
	s = f.waitLast(func(s feedSnapshot) bool { return s.Filter == "" }, "the filter cleared")
	if len(s.Sessions) != 2 {
		t.Errorf("unfiltered sessions: %s", s.raw)
	}

	f.stdin.Close()
	select {
	case err := <-f.done:
		if err != nil {
			t.Errorf("exit on EOF: %v, stderr %q", err, f.stderr)
		}
	case <-time.After(settle):
		t.Fatal("still running after stdin closed")
	}
}

// Every failure is one "kido sidebar-feed: " line and exit 1.
func TestSidebarFeedFailures(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--socket", h.dir + "/no-such-socket", "--client", h.client}, "no tmux server at "},
		{[]string{"--socket", socketPath("", h.inner), "--client", "no-such-client"}, `no tmux client "no-such-client"`},
		{[]string{"--socket", socketPath("", h.inner)}, "usage: kido sidebar-feed"},
	} {
		cmd := feedCmd(h, c.args...)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		cmd.Stdin = strings.NewReader("")
		out, err := cmd.Output()
		ee, ok := err.(*exec.ExitError)
		if !ok || ee.ExitCode() != 1 {
			t.Errorf("%q: exit %v, want 1", c.args, err)
		}
		if msg := stderr.String(); !strings.HasPrefix(msg, "kido sidebar-feed: "+c.want) {
			t.Errorf("%q: stderr %q, want kido sidebar-feed: %s...", c.args, msg, c.want)
		}
		if len(out) != 0 {
			t.Errorf("%q: stdout %q, want nothing", c.args, out)
		}
	}
}
