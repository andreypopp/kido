package main

import (
	"bytes"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"kido/internal/state"
)

// TestRunHookDebugLog checks the debug.log line format: ts, TMUX_PANE, the
// raw payload compacted to one line, and the effect.
func TestRunHookDebugLog(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%7")

	payload := "{\n  \"hook_event_name\": \"Stop\",\n  \"session_id\": \"abc\"\n}"
	if err := runHook(strings.NewReader(payload), true); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	// An event not in hook's table logs as "unmapped".
	if err := runHook(strings.NewReader(`{"hook_event_name":"FileChanged","session_id":"abc"}`), true); err != nil {
		t.Fatalf("runHook: %v", err)
	}

	b, err := os.ReadFile(filepath.Join(dir, "debug.log"))
	if err != nil {
		t.Fatalf("debug.log: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2:\n%s", len(lines), b)
	}

	fields := strings.Split(lines[0], "\t")
	if len(fields) != 4 {
		t.Fatalf("line 1 fields = %d, want 4: %q", len(fields), lines[0])
	}
	if _, err := time.Parse(time.RFC3339Nano, fields[0]); err != nil {
		t.Errorf("timestamp %q: %v", fields[0], err)
	}
	if fields[1] != "%7" {
		t.Errorf("pane = %q, want %%7", fields[1])
	}
	if strings.Contains(fields[2], "\n") || !json.Valid([]byte(fields[2])) {
		t.Errorf("payload not compact valid JSON: %q", fields[2])
	}
	if fields[3] != "ended" {
		t.Errorf("effect = %q, want ended", fields[3])
	}

	fields2 := strings.Split(lines[1], "\t")
	if len(fields2) != 4 || fields2[3] != "unmapped" {
		t.Errorf("line 2 effect = %v, want unmapped", fields2)
	}

	// Without debug, nothing is logged.
	dir2 := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir2)
	if err := runHook(strings.NewReader(payload), false); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir2, "debug.log")); !os.IsNotExist(err) {
		t.Errorf("debug.log created with debug off: %v", err)
	}
}

// TestHookDebugIsSwitchedOnByTheEnvironment covers the whole switch there
// is: Claude Code runs the hook, from a settings file kido ships and does
// not write, so no flag of kido's can reach it and the environment of the
// pane Claude Code was started in is the only channel left.
func TestHookDebugIsSwitchedOnByTheEnvironment(t *testing.T) {
	bin := dispatchTestBin(t)
	for _, on := range []bool{true, false} {
		dir := t.TempDir()
		cmd := exec.Command(bin, "hook")
		cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "KIDO_STATE_DIR=" + dir}
		if on {
			cmd.Env = append(cmd.Env, hookDebugEnv+"=1")
		}
		cmd.Stdin = strings.NewReader(`{"hook_event_name":"Stop","session_id":"s"}`)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("kido hook: %v (%s)", err, out)
		}
		_, err := os.Stat(filepath.Join(dir, "debug.log"))
		if on && err != nil {
			t.Errorf("with %s set: %v, want a debug log", hookDebugEnv, err)
		}
		if !on && !os.IsNotExist(err) {
			t.Errorf("without %s: debug.log exists (%v)", hookDebugEnv, err)
		}
	}
}

// TestRunHookEndedPreservesEarlierEnd checks that an Ended effect keeps an
// existing idle record's Ended time rather than overwriting it with now,
// since a later event minting Ended for the same turn is a less
// authoritative observation than the one already recorded.
func TestRunHookEndedPreservesEarlierEnd(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%7")

	// No existing record: Ended is stamped to now.
	before := time.Now().UTC()
	if err := runHook(strings.NewReader(`{"hook_event_name":"Stop","session_id":"s"}`), false); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	after := time.Now().UTC()
	states, err := state.Load()
	if err != nil {
		t.Fatalf("state.Load: %v", err)
	}
	got := states["%7"].Ended
	if got.Before(before) || got.After(after) {
		t.Fatalf("Ended = %v, want between %v and %v", got, before, after)
	}
	firstEnded := got

	// A second event that also mints Ended for the same session keeps the
	// earlier, already-recorded Ended rather than overwriting it with now.
	time.Sleep(2 * time.Millisecond)
	if err := runHook(strings.NewReader(`{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s"}`), false); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	states, err = state.Load()
	if err != nil {
		t.Fatalf("state.Load: %v", err)
	}
	if got := states["%7"].Ended; !got.Equal(firstEnded) {
		t.Errorf("Ended = %v, want preserved %v", got, firstEnded)
	}
}

// TestRunHookBackgroundWait checks the full round trip of a turn that ends
// with background work outstanding: the wait is recorded, survives the
// subagent's own tool calls, and ends - with a fresh end time - on the
// SubagentStop that reports nothing left running.
func TestRunHookBackgroundWait(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%9")

	fire := func(payload string) state.Session {
		t.Helper()
		if err := runHook(strings.NewReader(payload), false); err != nil {
			t.Fatalf("runHook: %v", err)
		}
		s, _, err := state.Get("s")
		if err != nil {
			t.Fatalf("state.Get: %v", err)
		}
		return s
	}

	// A turn that ends with a background task running stays running, and
	// the record says why.
	s := fire(`{"hook_event_name":"Stop","session_id":"s","background_tasks":[{"status":"running"}]}`)
	if s.Status != state.Running || !s.Background || !s.Ended.IsZero() {
		t.Fatalf("after Stop: %+v", s)
	}

	// The background subagent's own tool calls carry the session id but
	// say nothing about the main loop: the wait stands.
	s = fire(`{"hook_event_name":"PreToolUse","session_id":"s","agent_id":"a","tool_name":"Bash"}`)
	if s.Status != state.Running || !s.Background {
		t.Fatalf("after subagent PreToolUse: %+v", s)
	}

	// A SubagentStop with work still in flight changes nothing.
	s = fire(`{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a","background_tasks":[{"status":"running"}]}`)
	if s.Status != state.Running || !s.Background {
		t.Fatalf("after busy SubagentStop: %+v", s)
	}

	// idle_prompt fires a minute after any turn ends and carries no view
	// of background work: it must not end this one.
	s = fire(`{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s"}`)
	if s.Status != state.Running || !s.Background || !s.Ended.IsZero() {
		t.Fatalf("after idle_prompt: %+v", s)
	}

	// The last one finishing ends the turn, end time and all.
	before := time.Now().UTC()
	s = fire(`{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a","background_tasks":[]}`)
	if s.Status != state.Idle || s.Background {
		t.Fatalf("after final SubagentStop: %+v", s)
	}
	if s.Ended.Before(before) || s.Ended.After(time.Now().UTC()) {
		t.Errorf("Ended = %v, want stamped now", s.Ended)
	}

	// The main loop working again clears the wait, and a SubagentStop from
	// a subagent it spawned no longer ends the turn.
	fire(`{"hook_event_name":"Stop","session_id":"s","background_tasks":[{"status":"running"}]}`)
	s = fire(`{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash"}`)
	if s.Status != state.Running || s.Background {
		t.Fatalf("after main-loop PreToolUse: %+v", s)
	}
	s = fire(`{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a","background_tasks":[]}`)
	if s.Status != state.Running || !s.Ended.IsZero() {
		t.Errorf("SubagentStop with no wait pending: %+v", s)
	}
}

func TestDebugLogPath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	want := filepath.Join(dir, "debug.log")
	if got := filepath.Join(state.Dir(), "debug.log"); got != want {
		t.Errorf("debug-log path = %q, want %q", got, want)
	}
}

// TestAgentStatus checks the record `kido agent-status` writes for an
// agent that is not Claude Code.
func TestAgentStatus(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%12")

	if err := agentStatus([]string{"--agent", "pi", "--session", "p1", "--status", "running"}); err != nil {
		t.Fatalf("agentStatus: %v", err)
	}
	s, ok, err := state.Get("p1")
	if err != nil || !ok {
		t.Fatalf("state.Get: %v, ok=%v", err, ok)
	}
	if s.Agent != state.AgentPi || s.Pane != "%12" || s.Status != state.Running {
		t.Errorf("record = %+v, want a running pi record for %%12", s)
	}
	if s.PID <= 0 {
		t.Errorf("pid = %d, want the calling agent's pid", s.PID)
	}
	if s.TS.IsZero() || !s.Ended.IsZero() {
		t.Errorf("ts=%v ended=%v, want a timestamp and no end", s.TS, s.Ended)
	}

	// --ended stamps an end.
	if err := agentStatus([]string{"--agent", "pi", "--session", "p1",
		"--status", "idle", "--title", "π - kido", "--ended"}); err != nil {
		t.Fatalf("agentStatus --ended: %v", err)
	}
	s, _, err = state.Get("p1")
	if err != nil {
		t.Fatal(err)
	}
	if s.Status != state.Idle || s.Ended.IsZero() {
		t.Fatalf("record = %+v, want idle with an end", s)
	}
	firstEnded := s.Ended

	// An end describes when the turn ended, not when kido noticed: a
	// second report of the same turn keeps the earlier end.
	time.Sleep(2 * time.Millisecond)
	if err := agentStatus([]string{"--agent", "pi", "--session", "p1", "--status", "idle", "--ended"}); err != nil {
		t.Fatalf("agentStatus: %v", err)
	}
	if s, _, _ = state.Get("p1"); !s.Ended.Equal(firstEnded) {
		t.Errorf("ended = %v, want preserved %v", s.Ended, firstEnded)
	}

	// --remove drops the record, and is idempotent.
	for range 2 {
		if err := agentStatus([]string{"--agent", "pi", "--session", "p1", "--remove"}); err != nil {
			t.Fatalf("agentStatus --remove: %v", err)
		}
	}
	if _, ok, _ := state.Get("p1"); ok {
		t.Error("record still there after --remove")
	}
}

// reporter returns a function that runs one `kido agent-status` report
// for session id - the standard flags plus whatever extra the caller
// passes - and returns the record it wrote. The carry-forward tests below
// all work by repeating a report with one flag varied.
func reporter(t *testing.T, id string) func(extra ...string) state.Session {
	base := []string{"--agent", "pi", "--session", id, "--status", "running"}
	return func(extra ...string) state.Session {
		t.Helper()
		if err := agentStatus(append(append([]string(nil), base...), extra...)); err != nil {
			t.Fatalf("agentStatus %v: %v", extra, err)
		}
		s, ok, err := state.Get(id)
		if err != nil || !ok {
			t.Fatalf("state.Get: %v, ok=%v", err, ok)
		}
		return s
	}
}

// TestAgentStatusInbox checks --inbox: recorded when given, carried across
// reports that omit it (an extension coalescing its reports may not
// re-send it), and cleared by an explicit empty value, which is how an
// agent says its socket is gone.
func TestAgentStatusInbox(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%12")

	report := reporter(t, "p1")

	if s := report(); s.Inbox != "" {
		t.Errorf("inbox = %q, want empty with no --inbox ever given", s.Inbox)
	}
	if s := report("--inbox", "/tmp/pi-inbox.sock"); s.Inbox != "/tmp/pi-inbox.sock" {
		t.Errorf("inbox = %q, want the reported socket", s.Inbox)
	}
	if s := report(); s.Inbox != "/tmp/pi-inbox.sock" {
		t.Errorf("inbox = %q, want it carried across a report that omits --inbox", s.Inbox)
	}
	if s := report("--inbox", ""); s.Inbox != "" {
		t.Errorf("inbox = %q, want cleared by an explicit empty --inbox", s.Inbox)
	}
	if s := report(); s.Inbox != "" {
		t.Errorf("inbox = %q, want it to stay cleared", s.Inbox)
	}
}

// TestAgentStatusProtocol checks --protocol: recorded when given, carried
// across reports that omit it, and cleared by an explicit "--protocol 0" -
// the same carry-forward rule as --inbox, since presence decides it, not
// the value.
func TestAgentStatusProtocol(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%12")

	report := reporter(t, "p1")

	if s := report(); s.Protocol != 0 {
		t.Errorf("protocol = %d, want 0 with no --protocol ever given", s.Protocol)
	}
	if s := report("--protocol", "1"); s.Protocol != 1 {
		t.Errorf("protocol = %d, want 1", s.Protocol)
	}
	if s := report(); s.Protocol != 1 {
		t.Errorf("protocol = %d, want it carried across a report that omits --protocol", s.Protocol)
	}
	if s := report("--protocol", "0"); s.Protocol != 0 {
		t.Errorf("protocol = %d, want cleared by an explicit \"--protocol 0\"", s.Protocol)
	}
	if s := report(); s.Protocol != 0 {
		t.Errorf("protocol = %d, want it to stay cleared", s.Protocol)
	}
}

// TestAgentStatusActivity checks --activity: recorded when given, carried
// across reports that omit it, and cleared by an explicit empty value -
// the same carry-forward rule as --inbox, since a report that changes
// status but says nothing about activity must not blank it.
func TestAgentStatusActivity(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%12")

	report := reporter(t, "p1")

	if s := report(); s.Activity != "" {
		t.Errorf("activity = %q, want empty with no --activity ever given", s.Activity)
	}
	if s := report("--activity", "refactoring internal/ui"); s.Activity != "refactoring internal/ui" {
		t.Errorf("activity = %q, want the reported text", s.Activity)
	}
	if s := report(); s.Activity != "refactoring internal/ui" {
		t.Errorf("activity = %q, want it carried across a report that omits --activity", s.Activity)
	}
	if s := report("--activity", ""); s.Activity != "" {
		t.Errorf("activity = %q, want cleared by an explicit empty --activity", s.Activity)
	}
	if s := report(); s.Activity != "" {
		t.Errorf("activity = %q, want it to stay cleared", s.Activity)
	}
}

// TestAgentStatusModel checks --model: recorded when given, carried
// across reports that omit it, and cleared by an explicit empty value -
// the same carry-forward rule as --inbox and --activity, since a report
// that changes status but says nothing about the model must not blank it.
func TestAgentStatusModel(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%12")

	report := reporter(t, "p1")

	if s := report(); s.Model != "" {
		t.Errorf("model = %q, want empty with no --model ever given", s.Model)
	}
	if s := report("--model", "claude-sonnet-5"); s.Model != "claude-sonnet-5" {
		t.Errorf("model = %q, want the reported name", s.Model)
	}
	if s := report(); s.Model != "claude-sonnet-5" {
		t.Errorf("model = %q, want it carried across a report that omits --model", s.Model)
	}
	if s := report("--model", ""); s.Model != "" {
		t.Errorf("model = %q, want cleared by an explicit empty --model", s.Model)
	}
	if s := report(); s.Model != "" {
		t.Errorf("model = %q, want it to stay cleared", s.Model)
	}
}

// TestAgentStatusActivityIsOneLine pins the sanitising --activity gets on
// the way into a record. The text is model-authored, and both places kido
// draws it assume one line of printable characters: the sidebar budgets
// one terminal line per pane row, so a newline draws a line the row
// accounting knows nothing about and shifts everything below it, and an
// escape sequence would colour the rest of the column; `kido list_agents`
// prints a tab-separated table a tab would split. The byte cap is cut on
// a rune boundary, so a capped multi-byte string is still valid UTF-8.
func TestAgentStatusActivityIsOneLine(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%12")

	report := reporter(t, "p1")

	s := report("--activity", "one\ntwo\tthree\x1b[31m\x07")
	if strings.ContainsAny(s.Activity, "\n\t\x1b\x07") {
		t.Errorf("activity = %q, want no control characters", s.Activity)
	}
	if want := "one two three [31m"; s.Activity != want {
		t.Errorf("activity = %q, want %q", s.Activity, want)
	}

	s = report("--activity", strings.Repeat("é", 300))
	if n := len(s.Activity); n > maxActivity {
		t.Errorf("activity is %d bytes, want at most %d", n, maxActivity)
	}
	if !utf8.ValidString(s.Activity) || strings.ContainsRune(s.Activity, utf8.RuneError) {
		t.Errorf("activity = %q, want it cut on a rune boundary", s.Activity)
	}
}

// TestAgentStatusParentAndDepth checks that --instance, --parent-pid,
// --parent-instance and --depth are recorded exactly as given on every
// call, with no carry-forward: the agent reports them fresh from its own
// environment on every call, so an omitted flag means "root agent", not
// "keep the last one".
func TestAgentStatusParentAndDepth(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%12")

	report := reporter(t, "p1")

	s := report("--instance", "child-inst", "--parent-pid", "4242", "--parent-instance", "parent-inst", "--depth", "1")
	if s.Instance != "child-inst" || s.ParentPID != 4242 || s.ParentInstance != "parent-inst" || s.Depth != 1 {
		t.Fatalf("record = %+v, want instance child-inst, parent pid 4242, parent instance parent-inst and depth 1", s)
	}

	// Unlike --activity, omitting these on the next call resets them to
	// zero rather than carrying the previous values forward.
	if s := report(); s.Instance != "" || s.ParentPID != 0 || s.ParentInstance != "" || s.Depth != 0 {
		t.Errorf("record = %+v, want a root agent (no carry-forward)", s)
	}
}

// TestAgentStatusErrors checks the argument shapes that must fail.
func TestAgentStatusErrors(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%12")

	for _, c := range []struct {
		name string
		args []string
	}{
		{"no status", []string{"--agent", "pi", "--session", "p1"}},
		{"unknown status", []string{"--agent", "pi", "--session", "p1", "--status", "busy"}},
		{"kido's own status", []string{"--agent", "pi", "--session", "p1", "--status", "unknown"}},
		{"no agent", []string{"--session", "p1", "--status", "idle"}},
		{"no session", []string{"--agent", "pi", "--status", "idle"}},
		{"unknown flag", []string{"--agent", "pi", "--session", "p1", "--status", "idle", "--what"}},
		{"stray argument", []string{"--agent", "pi", "--session", "p1", "--status", "idle", "x"}},
	} {
		if err := agentStatus(c.args); err == nil {
			t.Errorf("%s: no error", c.name)
		}
	}
	if entries, _ := os.ReadDir(dir); len(entries) > 0 {
		t.Errorf("failed calls wrote %d files", len(entries))
	}
}

// TestEverySubcommandCaseReturns reads main's switch from the source: a
// case that dispatches and forgets to return falls into the sidebar's
// startup, which fails on the missing TTY with exit 1 after the
// subcommand has already printed its answer, and every caller that
// shells out reads a nonzero exit as inconclusive and ignores it.
// Measured live: `kido agent-alive` did exactly that, so an ask never saw
// its target die and a child never saw its parent die. A binary run
// cannot pin this for every subcommand, since most exit through a usage
// error before the fallthrough is reached; the source can.
func TestEverySubcommandCaseReturns(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var sw *ast.SwitchStmt
	ast.Inspect(f, func(n ast.Node) bool {
		if fd, ok := n.(*ast.FuncDecl); ok && fd.Name.Name != "main" {
			return false
		}
		if s, ok := n.(*ast.SwitchStmt); ok && sw == nil {
			sw = s
		}
		return sw == nil
	})
	if sw == nil {
		t.Fatal("no switch in main")
	}
	for _, c := range sw.Body.List {
		cc := c.(*ast.CaseClause)
		if cc.List == nil {
			continue // default: the flag path, which is the UI
		}
		last := cc.Body[len(cc.Body)-1]
		switch s := last.(type) {
		case *ast.ReturnStmt:
			continue
		case *ast.ExprStmt:
			if call, ok := s.X.(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "Exit" {
					continue
				}
			}
		}
		t.Errorf("case %s at %s falls through to the UI: its last statement is not a return or os.Exit",
			types.ExprString(cc.List[0]), fset.Position(last.Pos()))
	}
}

// TestAgentAliveExitsCleanly is the live half: the built binary, asked
// about an instance nobody claims, answers false and exits 0 with nothing
// on stderr, which is the reading every liveness poll depends on.
func TestAgentAliveExitsCleanly(t *testing.T) {
	bin := dispatchTestBin(t)
	cmd := exec.Command(bin, "agent-alive", "nobody")
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "KIDO_STATE_DIR=" + t.TempDir()}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil || strings.TrimSpace(stdout.String()) != "false" || stderr.Len() != 0 {
		t.Fatalf("kido agent-alive nobody: err=%v stdout=%q stderr=%q; want false, exit 0, no stderr", err, stdout.String(), stderr.String())
	}
}
