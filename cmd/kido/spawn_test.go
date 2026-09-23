package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"kido/internal/state"
	"kido/internal/tmux"
)

// newWindowCall is one recorded call to the faked newWindow.
type newWindowCall struct {
	session, name, cwd string
	env, command       []string
}

// marks records what markSubagent was asked to set, window id to value;
// withNewWindow resets it.
var marks map[string]string

// withNewWindow points newWindow and markSubagent at fakes that record
// their calls, so spawnCmd never talks to a real tmux server. newWindow
// returns (windowID, paneID, a fixed fake pid, err).
const fakePanePID = 42424242

func withNewWindow(t *testing.T, windowID, paneID string, err error) *[]newWindowCall {
	t.Helper()
	prev, prevMark := newWindow, markSubagent
	var calls []newWindowCall
	newWindow = func(session, name, cwd string, env, command []string) (string, string, int, error) {
		calls = append(calls, newWindowCall{session, name, cwd, env, command})
		return windowID, paneID, fakePanePID, err
	}
	marks = map[string]string{}
	markSubagent = func(windowID, info string) error {
		marks[windowID] = info
		return nil
	}
	t.Cleanup(func() { newWindow, markSubagent = prev, prevMark })
	return &calls
}

// captureStdout returns what f wrote to os.Stdout. The line kido spawn
// prints is parsed by pi/kido-agents.ts, so it is contract rather than
// logging and has to be read back verbatim.
func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	prev := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = prev }()
	f()
	os.Stdout = prev
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

// TestSpawnPrintsWindowPaneRun pins the one line spawn writes to stdout:
// pi/kido-agents.ts splits it on spaces to learn what it has just
// created, and a reordered or extra field would be read as garbage by a
// parser that lives outside this repo's tests.
func TestSpawnPrintsWindowPaneRun(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "@9", "%9", nil)

	var err error
	out := captureStdout(t, func() {
		err = spawnCmd([]string{
			"--parent-pid", "1", "--parent-instance", "x",
			"--name", "kid", "--task-file", writeTaskFile(t, "task"),
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(out, "\n") || strings.Count(out, "\n") != 1 {
		t.Fatalf("stdout = %q, want exactly one newline-terminated line", out)
	}
	fields := strings.Fields(out)
	if len(fields) != 3 || fields[0] != "@9" || fields[1] != "%9" {
		t.Fatalf("stdout = %q, want \"@9 %%9 <run-id>\"", out)
	}
	if got := tmux.SubagentRunID(marks["@9"]); got != fields[2] {
		t.Errorf("stdout run id %q, mark's run id %q; the two name the same run", fields[2], got)
	}
}

// TestSpawnMarksTheWindow pins what makes a spawned window reapable at
// all: without the @kido_subagent option (internal/reap) nothing will
// ever close it, since a sweep refuses every window it did not create.
// The run id in it is checked by reading it back with the parser a sweep
// uses, which is the only thing holding the two ends of that mini-format
// together (see tmux.SubagentMark); the consumer's own half is pinned
// against a literal in internal/reap's tests.
func TestSpawnMarksTheWindow(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "@9", "%9", nil)
	if err := spawnCmd([]string{
		"--parent-pid", "123", "--parent-instance", "abc",
		"--name", "kid", "--task-file", writeTaskFile(t, "x"),
	}); err != nil {
		t.Fatal(err)
	}
	got := marks["@9"]
	if !strings.Contains(got, "abc") {
		t.Errorf("mark on @9 = %q, want it to name the parent instance", got)
	}
	if tmux.SubagentRunID(got) == "" {
		t.Errorf("mark on @9 = %q, want a run= token a sweep can read back", got)
	}
}

// writeTaskFile returns a path to a real, readable file under maxTaskBytes,
// which every spawnCmd call needs since --task-file existence and size
// are checked.
func writeTaskFile(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "task.txt")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// withCallerDepth records a state.Session for the caller pane (%1, in
// samePane) reporting depth, so spawnCmd's derivation of the child's depth
// from the caller's own record (see spawn.go) has something to read.
func withCallerDepth(t *testing.T, depth int) {
	t.Helper()
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := state.Record("caller", state.Session{
		Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle, Depth: depth,
	}); err != nil {
		t.Fatal(err)
	}
}

func TestSpawnRefusedAtMaxDepth(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, maxDepth) // caller is already at the ceiling
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "do the thing")
	err := spawnCmd([]string{
		"--parent-pid", "123", "--parent-instance", "abc",
		"--name", "kid", "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnCmd for a caller at the ceiling = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "maximum nesting") {
		t.Errorf("error = %q, want it to name the depth ceiling", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

// TestSpawnCannotEscapeCeilingWithSmallerDepth: a caller already at the
// ceiling passes a smaller --depth. It must not matter what --depth says;
// only the caller's own state record does, or the ceiling is only as real
// as the caller chooses to make it.
func TestSpawnCannotEscapeCeilingWithSmallerDepth(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, maxDepth)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "do the thing")
	err := spawnCmd([]string{
		"--parent-pid", "123", "--parent-instance", "abc",
		"--depth", "1", "--name", "kid", "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnCmd with a forged smaller --depth = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "maximum nesting") {
		t.Errorf("error = %q, want it to name the depth ceiling", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

func TestSpawnAllowsMaxDepth(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, maxDepth-1) // one below the ceiling, so the child lands exactly on it
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "do the thing")
	err := spawnCmd([]string{
		"--parent-pid", "123", "--parent-instance", "abc",
		"--name", "kid", "--task-file", taskFile,
	})
	if err != nil {
		t.Fatalf("spawnCmd landing exactly on the ceiling = %v, want it allowed", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
	if got := (*calls)[0].env; !slices.Contains(got, "KIDO_AGENT_DEPTH=2") {
		t.Errorf("env = %v, want KIDO_AGENT_DEPTH=2", got)
	}
}

// TestSpawnUnreportedCallerIsDepthZero is the documented fallback for a
// caller with no state record at all (a human running kido spawn by hand,
// or an agent that has not reported yet): treated as depth 0, so its
// child lands at depth 1.
func TestSpawnUnreportedCallerIsDepthZero(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("KIDO_STATE_DIR", t.TempDir()) // empty: no record for the caller
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "do the thing")
	if err := spawnCmd([]string{
		"--parent-pid", "123", "--parent-instance", "abc",
		"--name", "kid", "--task-file", taskFile,
	}); err != nil {
		t.Fatalf("spawnCmd with no caller record = %v, want it allowed at depth 0", err)
	}
	if got := (*calls)[0].env; !slices.Contains(got, "KIDO_AGENT_DEPTH=1") {
		t.Errorf("env = %v, want KIDO_AGENT_DEPTH=1", got)
	}
}

func TestSpawnRejectsUnsafeName(t *testing.T) {
	calls := withNewWindow(t, "@1", "%1", nil)
	for _, name := range []string{`kid"s`, "kid$x", "kid#x", "kid`x", "kid\\x", "kid'x", "kid\nx", "kid\rx"} {
		err := spawnCmd([]string{
			"--parent-pid", "123", "--parent-instance", "abc",
			"--name", name, "--task-file", "/tmp/task",
		})
		if err == nil {
			t.Errorf("spawnCmd with name %q = nil error, want a refusal", name)
		}
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times for an unsafe name, want 0", len(*calls))
	}
}

// TestSpawnRejectsLongName: the tmuxConfUnsafe check rejects dangerous
// characters but does not cap length.
func TestSpawnRejectsLongName(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "task")
	err := spawnCmd([]string{
		"--parent-pid", "123", "--parent-instance", "abc",
		"--name", strings.Repeat("x", maxWindowNameLen+1), "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnCmd with an over-long name = nil error, want a refusal")
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times for an over-long name, want 0", len(*calls))
	}
}

func TestSpawnAllowsSpaceInName(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "task")
	err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--name", "kid one", "--task-file", taskFile,
	})
	if err != nil {
		t.Fatalf("spawnCmd with a space in the name = %v, want it allowed", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
}

// TestSpawnMissingTaskFile: a typo in --task-file must not create the
// window, which would leave a child with no task and no sign anything was
// lost.
func TestSpawnMissingTaskFile(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--name", "kid", "--task-file", filepath.Join(t.TempDir(), "does-not-exist.txt"),
	})
	if err == nil {
		t.Fatal("spawnCmd with a missing --task-file = nil error, want a refusal")
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times for a missing task file, want 0", len(*calls))
	}
}

// TestSpawnRejectsOversizedTaskFile: the inbox drops a payload over
// MAX_PROMPT_BYTES, and the task-file path must apply the same cap.
func TestSpawnRejectsOversizedTaskFile(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, strings.Repeat("x", maxTaskBytes+1))
	err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--name", "kid", "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnCmd with an oversized task file = nil error, want a refusal")
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times for an oversized task file, want 0", len(*calls))
	}
}

func TestSpawnAllowsTaskFileAtCap(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, strings.Repeat("x", maxTaskBytes))
	err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--name", "kid", "--task-file", taskFile,
	})
	if err != nil {
		t.Fatalf("spawnCmd with a task file exactly at the cap = %v, want it allowed", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
}

// TestSpawnRejectsNegativeDepth: an explicit wrong --depth is not the
// same as an omitted one, and must not be reported as "required".
func TestSpawnRejectsNegativeDepth(t *testing.T) {
	calls := withNewWindow(t, "@1", "%1", nil)
	err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--depth", "-1", "--name", "kid", "--task-file", "/tmp/task",
	})
	if err == nil {
		t.Fatal("spawnCmd with --depth -1 = nil error, want a refusal")
	}
	if strings.Contains(err.Error(), "is required") {
		t.Errorf("error = %q, an explicit negative --depth is a wrong value, not an omission", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times for a negative depth, want 0", len(*calls))
	}
}

// TestSpawnTaskNeverOnCommandLine checks that the task's own text - which
// only ever exists in the file --task-file names - never appears in any
// argument or environment entry handed to tmux; only the file's path does.
func TestSpawnTaskNeverOnCommandLine(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)

	const taskText = "secret task text, arbitrary shape\nwith a newline and $(a shell metachar)"
	taskFile := writeTaskFile(t, taskText)

	if err := spawnCmd([]string{
		"--parent-pid", "123", "--parent-instance", "abc",
		"--name", "kid", "--task-file", taskFile,
	}); err != nil {
		t.Fatal(err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
	call := (*calls)[0]

	for _, arg := range append(append([]string{}, call.env...), call.command...) {
		if strings.Contains(arg, "secret task text") {
			t.Errorf("task text leaked into the tmux invocation: %q", arg)
		}
	}
	// The task lives in the run's own directory: KIDO_AGENT_TASK_FILE does
	// not name the caller's --task-file, but its content must still be
	// exactly the task.
	relocated := envValue(t, call.env, "KIDO_AGENT_TASK_FILE")
	if relocated == taskFile {
		t.Errorf("KIDO_AGENT_TASK_FILE = %s, want it relocated into the run directory, not the caller's own path", relocated)
	}
	got, err := os.ReadFile(relocated)
	if err != nil || string(got) != taskText {
		t.Errorf("relocated task file contents = %q, %v, want %q, nil", got, err, taskText)
	}
}

// envValue returns the value of key=... in env, failing the test if key
// is not present at all.
func envValue(t *testing.T, env []string, key string) string {
	t.Helper()
	prefix := key + "="
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, prefix); ok {
			return v
		}
	}
	t.Fatalf("env %v missing %s", env, key)
	return ""
}

// TestSpawnPassesParentAndDepth checks the full environment kido spawn
// sets, the target session (the caller's own, not any other), and that a
// command given after -- is passed through unmodified.
func TestSpawnPassesParentAndDepth(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 1)
	calls := withNewWindow(t, "@2", "%3", nil)

	taskFile := writeTaskFile(t, "task")
	err := spawnCmd([]string{
		"--parent-pid", "555", "--parent-instance", "parent-inst",
		"--name", "kid", "--task-file", taskFile,
		"--", "fakepi", "--flag",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
	call := (*calls)[0]

	for _, kv := range []string{
		"KIDO_AGENT_PARENT_PID=555",
		"KIDO_AGENT_PARENT_INSTANCE=parent-inst",
		"KIDO_AGENT_DEPTH=2", // caller reported depth 1, so the child is 2
	} {
		if !slices.Contains(call.env, kv) {
			t.Errorf("env = %v, missing %s", call.env, kv)
		}
	}
	if got := envValue(t, call.env, "KIDO_AGENT_TASK_FILE"); got == taskFile {
		t.Errorf("KIDO_AGENT_TASK_FILE = %s, want it relocated into the run directory, not the caller's own path", got)
	}
	if call.session != "$1" {
		t.Errorf("session = %q, want %q (the caller's own)", call.session, "$1")
	}
	if want := []string{"fakepi", "--flag"}; !reflect.DeepEqual(call.command, want) {
		t.Errorf("command = %v, want %v", call.command, want)
	}
}

func TestSpawnDefaultsCommandToPi(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "task")
	if err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--name", "kid", "--task-file", taskFile,
	}); err != nil {
		t.Fatal(err)
	}
	// A plain "pi" command gets --session-id inserted, tying the run id to
	// the child's own session from birth (see spawn.go's doc comment).
	got := (*calls)[0].command
	if len(got) != 3 || got[0] != "pi" || got[1] != "--session-id" || got[2] == "" {
		t.Errorf("command = %v, want [pi --session-id <run-id>]", got)
	}
}

// TestSpawnFailureIsAVisibleFailedRun: a spawn whose window creation fails
// records that as the run's outcome, rather than leaving a caller of `kido
// runs` to work out why a run has no window. Read back through listRuns
// rather than subrun directly, because the meta file the failure path
// writes is exactly what makes the outcome visible there - a run directory
// without one is skipped, outcome and all.
func TestSpawnFailureIsAVisibleFailedRun(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "", "", errors.New("no such session"))
	if err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--name", "kid", "--task-file", writeTaskFile(t, "task"),
	}); err == nil {
		t.Fatal("spawnCmd = nil, want the window creation failure")
	}

	var out bytes.Buffer
	if err := listRuns(&out, true); err != nil {
		t.Fatal(err)
	}
	var infos []RunInfo
	if err := json.Unmarshal(out.Bytes(), &infos); err != nil {
		t.Fatalf("runs --json: %v (%q)", err, out.String())
	}
	if len(infos) != 1 || infos[0].Outcome != "failed" {
		t.Errorf("runs --json = %+v, want one failed run", infos)
	}
}

// TestSpawnMarkFailureKillsTheWindowAndRecordsFailure: a failed
// markSubagent must not leave the window up unmarked, which no sweep
// would ever find since internal/reap only touches a window carrying
// @kido_subagent. It kills the window and records the run as failed, the
// same as the newWindow-failure path.
func TestSpawnMarkFailureKillsTheWindowAndRecordsFailure(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "@9", "%9", nil)

	prevKill := killWindow
	var killed []string
	killWindow = func(id string) error {
		killed = append(killed, id)
		return nil
	}
	t.Cleanup(func() { killWindow = prevKill })

	prevMark := markSubagent
	markSubagent = func(windowID, info string) error { return errors.New("option failed") }
	t.Cleanup(func() { markSubagent = prevMark })

	if err := spawnCmd([]string{
		"--parent-pid", "1", "--parent-instance", "x",
		"--name", "kid", "--task-file", writeTaskFile(t, "task"),
	}); err == nil {
		t.Fatal("spawnCmd = nil, want the mark failure")
	}

	if !slices.Contains(killed, "@9") {
		t.Errorf("killWindow calls = %v, want @9 killed rather than left up unmarked", killed)
	}

	var out bytes.Buffer
	if err := listRuns(&out, true); err != nil {
		t.Fatal(err)
	}
	var infos []RunInfo
	if err := json.Unmarshal(out.Bytes(), &infos); err != nil {
		t.Fatalf("runs --json: %v (%q)", err, out.String())
	}
	if len(infos) != 1 || infos[0].Outcome != "failed" {
		t.Errorf("runs --json = %+v, want one failed run", infos)
	}
}
