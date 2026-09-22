package main

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"kido/internal/state"
)

// newWindowCall is one recorded call to the faked newWindow.
type newWindowCall struct {
	session, name, cwd string
	env, command       []string
}

// withNewWindow points newWindow at a fake that records its calls and
// returns (windowID, paneID, err), so spawnCmd never talks to a real tmux
// server.
func withNewWindow(t *testing.T, windowID, paneID string, err error) *[]newWindowCall {
	t.Helper()
	prev := newWindow
	var calls []newWindowCall
	newWindow = func(session, name, cwd string, env, command []string) (string, string, error) {
		calls = append(calls, newWindowCall{session, name, cwd, env, command})
		return windowID, paneID, err
	}
	t.Cleanup(func() { newWindow = prev })
	return &calls
}

// writeTaskFile returns a path to a real, readable file under maxTaskBytes,
// which every spawnCmd call needs now that --task-file existence and size
// are checked (D12, D9).
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

// TestSpawnCannotEscapeCeilingWithSmallerDepth is D5: a caller already at
// the ceiling used to be able to pass a smaller --depth and spawn anyway,
// since --depth was trusted as the caller's own claim about itself. It
// must not matter what --depth says; only the caller's own state record
// does.
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
	for _, name := range []string{`kid"s`, "kid$x", "kid#x", "kid`x", "kid\\x", "kid'x", "kid\nx"} {
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

// TestSpawnRejectsLongName is D13: the window name has no cap otherwise,
// even though the tmuxConfUnsafe check already rejects the characters
// that would make one dangerous.
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

// TestSpawnMissingTaskFile is D12: a typo in --task-file used to create
// the window anyway, leaving a child with no task and no sign anything
// was lost.
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

// TestSpawnRejectsOversizedTaskFile is D9: the inbox drops a payload over
// MAX_PROMPT_BYTES, but the task-file path had no matching cap at either
// end.
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

// TestSpawnRejectsNegativeDepth is D6: an explicit wrong --depth is not
// the same as an omitted one, and must not be reported as "required".
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
	if !slices.Contains(call.env, "KIDO_AGENT_TASK_FILE="+taskFile) {
		t.Errorf("env = %v, want KIDO_AGENT_TASK_FILE=%s", call.env, taskFile)
	}
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
		"KIDO_AGENT_TASK_FILE=" + taskFile,
	} {
		if !slices.Contains(call.env, kv) {
			t.Errorf("env = %v, missing %s", call.env, kv)
		}
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
	if got := (*calls)[0].command; !reflect.DeepEqual(got, []string{"pi"}) {
		t.Errorf("command = %v, want [pi]", got)
	}
}
