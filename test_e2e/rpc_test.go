package e2e

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type feedRow struct {
	Pane          *string       `json:"pane"`
	Window        *string       `json:"window"`
	Kind          string        `json:"kind"`
	ID            string        `json:"id"`
	Name          string        `json:"name"`
	Children      []feedRow     `json:"children"`
	Title         string        `json:"title"`
	Lifecycle     feedLifecycle `json:"lifecycle"`
	Started       *float64      `json:"started"`
	Run           *string       `json:"run"`
	ProgramStatus struct {
		Serial  int `json:"serial"`
		Records []struct {
			ID, State, App, Kind, Title, Msg string
			Progress                         *int
		} `json:"records"`
	} `json:"program_status"`
}

type feedSnapshot struct {
	V              int `json:"v"`
	ServerInstance struct {
		StartedAt int `json:"started_at"`
		Pid       int `json:"pid"`
	} `json:"server_instance"`
	Client struct {
		Session string `json:"session"`
		Window  string `json:"window"`
		Pane    string `json:"pane"`
	} `json:"client"`
	Error    *string `json:"error"`
	Sessions []struct {
		ID      string    `json:"id"`
		Name    string    `json:"name"`
		Current bool      `json:"current"`
		Nodes   []feedRow `json:"nodes"`
	} `json:"sessions"`
	raw string
}

// elapsedText is the TUI's elapsed format (Kido_sidebar.elapsed).
func elapsedText(started float64) string {
	s := max(0, int(float64(time.Now().UnixNano())/1e9-started))
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm%02ds", s/60, s%60)
	}
	return fmt.Sprintf("%dh%02dm", s/3600, s/60%60)
}

// drawn spells each row as the TUI does, a running bash run's elapsed
// time read from the clock now.
func (s feedSnapshot) drawn() []string {
	var out []string
	var draw func(feedRow, string, string, string)
	var item func(feedRow, string, string)
	item = func(r feedRow, tree, nested string) {
		label := feedLabel(r)
		if caption := r.caption(); caption != "" {
			label += " " + caption
		} else if r.Started != nil {
			label += " " + elapsedText(*r.Started)
		}
		out = append(out, strings.TrimSpace(tree+feedGlyph(r)+label))
		for i, child := range r.Children {
			lead, stem := "├", "│"
			if i == len(r.Children)-1 {
				lead, stem = "└", " "
			}
			draw(child, nested, lead, stem)
		}
	}
	draw = func(r feedRow, prefix, lead, stem string) {
		if r.Kind != "window" {
			if lead == "" {
				lead, stem = "╶", " "
			}
			item(r, prefix+lead, prefix+stem+" ")
			return
		}
		for i, child := range r.Children {
			bracket, cont := "├", "│"
			if i == 0 {
				bracket = "┌"
			}
			if i == len(r.Children)-1 {
				bracket, cont = "└", " "
			}
			g, nested := bracket, prefix+cont+" "
			if lead != "" {
				g = stem + bracket
				if i == 0 {
					g = lead + bracket
				}
				nested = prefix + stem + cont + " "
			}
			item(child, prefix+g, nested)
		}
	}
	for _, sess := range s.Sessions {
		out = append(out, sess.Name)
		for _, r := range sess.Nodes {
			draw(r, "", "", "")
		}
	}
	return out
}

func feedItems(nodes []feedRow) []feedRow {
	var out []feedRow
	for _, node := range nodes {
		if node.Kind != "window" {
			out = append(out, node)
		}
		out = append(out, feedItems(node.Children)...)
	}
	return out
}

// feed is a running `kido rpc` for an app-like control client
// of the inner server: its own `tmux -C` attached to session, the way
// Kido.app attaches one.
type feed struct {
	h       *harness
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	stderr  *bytes.Buffer
	client  string
	mu      sync.Mutex
	lines   []feedSnapshot
	done    chan struct{}
	waitErr error
}

func (h *harness) appClient(session string) string {
	h.t.Helper()
	app := exec.Command(tmuxBin, "-S", socketPath(h.inner), "-C", "attach-session", "-t", session)
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
	cmd := exec.Command(kidoBin, append([]string{"rpc"}, args...)...)
	// The knobs the inner server gives its own sidebar, so both agree.
	cmd.Env = cleanEnv("TMUX=", "TMUX_PANE=", "KIDO_STATE_DIR="+serverDir(h.t),
		"KIDO_LINGER_SECONDS=1")
	return cmd
}

// env overrides feedCmd's environment.
func (h *harness) startFeed(session string, env ...string) *feed {
	h.t.Helper()
	f := &feed{h: h, client: h.appClient(session), stderr: &bytes.Buffer{}, done: make(chan struct{})}
	f.cmd = feedCmd(h, "--server", h.stateDir, "--client", f.client)
	f.cmd.Env = append(f.cmd.Env, env...)
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
		f.waitErr = f.cmd.Wait()
		close(f.done)
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
func TestRpcMatchesTheTUI(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	_, childWindow := h.recordedRun("kid-e2e")
	slowRun := h.asyncBash("slow-e2e", "sleep", "300")
	h.newSession("beta")
	const name = "beta-shells"
	h.in("rename-window", "-t", "beta:", name)
	h.in("split-window", "-d", "-t", "beta:")
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

	if s.V != 2 || s.Error != nil {
		t.Errorf("v/error = %d %v, want 2 null: %s", s.V, s.Error, s.raw)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(s.raw), &fields); err != nil {
		t.Fatal(err)
	}
	if _, ok := fields["filter"]; ok {
		t.Fatalf("snapshot contains filter: %s", s.raw)
	}
	pane := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id} #{pane_id}")
	if got := s.Client.Session + " " + s.Client.Window + " " + s.Client.Pane; got != pane {
		t.Errorf("client = %q, want %q", got, pane)
	}
	if len(s.Sessions) != 2 || s.Sessions[0].Name != "alpha" || !s.Sessions[0].Current || s.Sessions[1].Current {
		t.Fatalf("sessions: %s", s.raw)
	}
	if s.ServerInstance.StartedAt <= 0 || s.ServerInstance.Pid <= 0 {
		t.Errorf("server_instance: %s", s.raw)
	}
	pair := h.in("display-message", "-p", "#{start_time} #{pid}")
	if got := fmt.Sprintf("%d %d", s.ServerInstance.StartedAt, s.ServerInstance.Pid); got != pair {
		t.Errorf("server_instance = %s, want tmux's %s", got, pair)
	}
	// Display composition is the frontend's: no item carries a span, tail, indicator or attention.
	for _, field := range []string{`"tail"`, `"role"`, `"indicator"`, `"attention"`, `"kind":"agent"`, `"kind":"shell"`, `"kind":"run"`} {
		if strings.Contains(s.raw, field) {
			t.Errorf("snapshot still sends %s: %s", field, s.raw)
		}
	}
	byTitle := map[string]feedRow{}
	for _, r := range feedItems(s.Sessions[0].Nodes) {
		if r.Pane == nil || r.Window == nil || !strings.HasPrefix(*r.Pane, "%") || !strings.HasPrefix(*r.Window, "@") || r.Kind != "pane" {
			t.Errorf("row without pane/window ids: %+v", r)
		}
		byTitle[r.Title] = r
	}
	if r := byTitle["slow-e2e"]; !r.isShell() || r.Run == nil || *r.Run != slowRun || r.Started == nil || r.caption() != "" {
		t.Errorf("the lingering run's row: %+v in %s", r, s.raw)
	}
	for title, r := range byTitle {
		if title != "slow-e2e" && *r.Window != childWindow && r.Started != nil {
			t.Errorf("row %q sends a start time: %s", title, s.raw)
		}
	}
	nested := false
	for _, root := range feedItems(s.Sessions[0].Nodes) {
		for _, r := range feedItems(root.Children) {
			if *r.Window == childWindow {
				nested = r.isAgent()
				if r.Started == nil || r.caption() != "" {
					t.Errorf("the subagent's elapsed caption: %s", s.raw)
				}
				if !r.isAgent() || r.Lifecycle.Agent.State != "Idle" || r.Lifecycle.Agent.Outcome != nil {
					t.Errorf("the idle subagent's status: %s", s.raw)
				}
			}
		}
	}
	if !nested {
		t.Errorf("the subagent window is not nested under its parent: %s", s.raw)
	}
	if g := s.Sessions[1].Nodes; len(g) != 1 || g[0].Kind != "window" || g[0].Name != name || len(g[0].Children) != 2 ||
		!g[0].Children[0].isShell() || g[0].Children[0].Run != nil {
		t.Errorf("beta's two-pane window, named %q: %s", name, s.raw)
	}
}

func TestRpcHyperlinks(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 1 }, "the first snapshot")

	clients := h.in("list-clients", "-F", "#{client_name}\t#{client_control_mode}\t#{client_flags}\t#{client_termfeatures}")
	count := 0
	for _, line := range strings.Split(clients, "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 4 || fields[1] != "1" || !strings.Contains(fields[2], "no-output") || !strings.Contains(fields[2], "ignore-size") {
			continue
		}
		count++
		if !strings.Contains(fields[3], "hyperlinks") {
			t.Errorf("kido control client %s: client_termfeatures = %q, want hyperlinks", fields[0], fields[3])
		}
	}
	if count != 2 {
		t.Errorf("found %d kido control clients, want sidebar and rpc: %s", count, clients)
	}
}

func TestRpcWindowRename(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.in("rename-window", "-t", "alpha:", "before-rename")
	h.in("split-window", "-d", "-t", "alpha:")
	f := h.startFeed("alpha")
	for _, name := range []string{"before-rename", "after-rename"} {
		if name == "after-rename" {
			h.in("rename-window", "-t", "alpha:", name)
		}
		f.waitLast(func(s feedSnapshot) bool {
			for _, session := range s.Sessions {
				for _, node := range session.Nodes {
					if node.Kind == "window" && node.Name == name && len(node.Children) == 2 {
						return true
					}
				}
			}
			return false
		}, "window group named "+name)
	}
}

func TestRpcRunStartedWithActivity(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	agentRun, agentWindow := h.recordedRun("feed-agent", "--title", "feed-agent")
	agentPane := h.in("list-panes", "-t", agentWindow, "-F", "#{pane_id}")
	h.in("set-option", "-p", "-t", agentPane, "@kido_activity", "checking tests")
	bash := h.startRun(caller, "run", "--name", "feed-bash", "--", "sleep", "300")
	f := h.startFeed("alpha")
	for _, c := range []struct{ pane, id string }{
		{agentPane, agentRun},
		{bash.paneID(), bash.ID},
	} {
		metaBytes, err := os.ReadFile(filepath.Join(h.stateDir, "runs", c.id, "meta.json"))
		if err != nil {
			t.Fatal(err)
		}
		var meta struct {
			StartedAt string `json:"startedAt"`
		}
		if err := json.Unmarshal(metaBytes, &meta); err != nil {
			t.Fatal(err)
		}
		at, err := time.Parse(time.RFC3339Nano, meta.StartedAt)
		if err != nil {
			t.Fatal(err)
		}
		want := float64(at.Unix()) + float64(at.Nanosecond())/1e9
		f.waitLast(func(s feedSnapshot) bool {
			r, ok := feedRowFor(s, c.pane)
			return ok && !r.Lifecycle.Ended && r.Run != nil && *r.Run == c.id &&
				r.Started != nil && *r.Started == want
		}, "live run's id and meta start time")

		h.runKido("alpha", "end-"+c.id+".out", "run-outcome", "--result", "completed", "--", c.id)
		f.waitLast(func(s feedSnapshot) bool {
			r, ok := feedRowFor(s, c.pane)
			return ok && r.Run != nil && *r.Run == c.id && r.Started == nil &&
				r.Lifecycle.Ended && feedValue(r.Lifecycle.Result) == "completed"
		}, "ended run retains its run id but clears started")
	}
	rootPane := h.in("display-message", "-p", "-t", "alpha:0", "#{pane_id}")
	for _, agent := range []string{"pi", "claude-code"} {
		for _, status := range []string{"running", "idle"} {
			state := "idle"
			if status == "running" {
				state = "working"
			}
			if agent == "pi" {
				h.programStatus(rootPane, "state="+state+":app=pi", "feed-root")
				h.setPiOptions(rootPane, "root-e2e", h.paneTitle(rootPane), "", status)
			} else {
				h.clearPiOptions(rootPane)
				h.programStatus(rootPane, "state="+state+":app=claude-code:msg="+base64.StdEncoding.EncodeToString([]byte(status)), "feed-root")
			}
			mark := h.in("display-message", "-p", "-t", rootPane, "#{@kido_run}")
			f.waitLast(func(s feedSnapshot) bool {
				r, ok := feedRowFor(s, rootPane)
				run := r.Run == nil && mark == "" || r.Run != nil && mark != "" && *r.Run == mark
				return ok && r.isAgent() && run && r.Started == nil && r.caption() == status
			}, agent+" "+status+" top-level agent carries its pane's run mark")
		}
	}
}

// A window linked into two sessions has one copy of its pane per
// session; the snapshot's client must name the session the client is
// actually switched to, not whichever copy list-panes happens to return
// first.
func TestRpcLinkedWindowClientSession(t *testing.T) {
	t.Parallel()
	h := start(t, "one")
	h.newSession("two")
	f := h.startFeed("one")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 }, "both sessions")

	windowID := h.in("display-message", "-p", "-t", "one", "#{window_id}")
	h.in("link-window", "-s", "one", "-t", "two:")
	var index string
	for _, line := range strings.Split(h.in("list-windows", "-t", "two", "-F", "#{window_index} #{window_id}"), "\n") {
		if idx, id, ok := strings.Cut(line, " "); ok && id == windowID {
			index = idx
		}
	}
	if index == "" {
		t.Fatalf("linked window not found in two: %s",
			h.in("list-windows", "-t", "two", "-F", "#{window_index} #{window_id}"))
	}
	h.in("switch-client", "-c", f.client, "-t", "two:"+index)

	want := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id} #{pane_id}")
	s := f.waitLast(func(s feedSnapshot) bool {
		return s.Client.Session+" "+s.Client.Window+" "+s.Client.Pane == want
	}, "client switched into two's copy of the linked window")
	if got := s.Client.Session + " " + s.Client.Window + " " + s.Client.Pane; got != want {
		t.Errorf("client = %q, want %q: %s", got, want, s.raw)
	}
}

func TestRpcStream(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 }, "both sessions")

	// Its elapsed time ticks in the TUI; the feed sends only the start.
	caller := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	callerTitle := f.last().Sessions[0].Nodes[0].Title
	tickRun := h.asyncBash("tick-e2e", "sleep", "300")
	f.waitLast(func(s feedSnapshot) bool {
		var shellSettled, bashRunning bool
		for _, session := range s.Sessions {
			for _, r := range feedItems(session.Nodes) {
				if r.Pane != nil && *r.Pane == caller {
					// An unintegrated shell is unknown while kido is still its foreground command.
					shellSettled = r.isShell() && r.state() == "Unknown" && r.Started == nil &&
						r.Title == callerTitle
				}
				if r.Run != nil && *r.Run == tickRun && r.Title == "tick-e2e" {
					bashRunning = !r.Lifecycle.Ended && r.Started != nil
				}
			}
		}
		return shellSettled && bashRunning
	}, "the caller shell settled and the bash run running")

	n := f.count()
	h.newWindow("beta", "fresh")
	// The new pane's command settles a tick or more after the window
	// appears (its title passes through the program starting it), so wait
	// for it to read like beta's first shell.
	f.waitLast(func(s feedSnapshot) bool {
		if len(s.Sessions) != 2 || len(s.Sessions[1].Nodes) != 2 {
			return false
		}
		rows := s.Sessions[1].Nodes
		return rows[1].Title == rows[0].Title
	}, "beta's new window, settled")
	if f.count() <= n {
		t.Fatalf("no new line for a new window")
	}

	f.send(`{"filter":"bet"}`)
	if s := f.last(); len(s.Sessions) != 2 {
		t.Errorf("sessions changed by filter: %s", s.raw)
	}
	f.send("frobnicate")
	f.send(`{"filter":""}`)

	f.stdin.Close()
	select {
	case <-f.done:
		if f.waitErr != nil {
			t.Errorf("exit on EOF: %v, stderr %q", f.waitErr, f.stderr)
		}
	case <-time.After(settle):
		t.Fatal("still running after stdin closed")
	}
}

// Every failure is one "kido rpc: " line and exit 1.
func TestRpcFailures(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--server", filepath.Join(serverDir(t), "absent"), "--client", h.client}, "no tmux server at "},
		{[]string{"--server", h.stateDir, "--client", "no-such-client"}, `no tmux client "no-such-client"`},
		{[]string{"--server", h.stateDir}, "usage: kido rpc"},
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
		if msg := stderr.String(); !strings.HasPrefix(msg, "kido rpc: "+c.want) {
			t.Errorf("%q: stderr %q, want kido rpc: %s...", c.args, msg, c.want)
		}
		if len(out) != 0 && string(out) != "{\"hello\":{\"protocol\":\"6.0\"}}\n" {
			t.Errorf("%q: unexpected stdout %q", c.args, out)
		}
	}
}

// A stdin that cannot be read ends the feed with exit 1, as EOF ends it
// with 0: a directory's descriptor fails every read.
func TestRpcStdinError(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	cmd := feedCmd(h, "--server", h.stateDir, "--client", h.appClient("alpha"))
	d, err := os.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	cmd.Stdin = d
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 1 {
			t.Errorf("exit %v, want 1", err)
		}
		if msg := stderr.String(); !strings.HasPrefix(msg, "kido rpc: ") {
			t.Errorf("stderr %q, want kido rpc: ...", msg)
		}
	case <-time.After(settle):
		cmd.Process.Kill()
		<-done
		t.Fatalf("still running with an unreadable stdin; stderr %q", stderr.String())
	}
}
