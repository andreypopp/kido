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
	"time"

	"kido/internal/reap"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// newWindowCall is one recorded call to the faked newWindow.
type newWindowCall struct {
	session, name, cwd string
	env, command       []string
}

var marks map[string]string

const fakePanePID = 42424242

func withNewWindow(t *testing.T, windowID, paneID string, err error) *[]newWindowCall {
	t.Helper()
	var calls []newWindowCall
	testutil.Swap(t, &newWindow, func(session, name, cwd string, env, command []string) (string, string, int, error) {
		calls = append(calls, newWindowCall{session, name, cwd, env, command})
		return windowID, paneID, fakePanePID, err
	})
	marks = map[string]string{}
	testutil.Swap(t, &markRun, func(paneID, runID string) error {
		marks[paneID] = runID
		return nil
	})
	// The fake window is in no real tmux server for createRunWindow to check on a failure.
	testutil.Swap(t, &windowExists, func(string) bool { return true })
	return &calls
}

func withListModels(t *testing.T, rows ...string) {
	t.Helper()
	var b strings.Builder
	b.WriteString("PROVIDER\tMODEL\n")
	for _, r := range rows {
		parts := strings.SplitN(r, "/", 2)
		b.WriteString(parts[0] + "\t" + parts[1] + "\n")
	}
	out := []byte(b.String())
	testutil.Swap(t, &listModels, func() ([]byte, error) { return out, nil })
}

// capture returns what f wrote to *target (os.Stdout or os.Stderr).
func capture(t *testing.T, target **os.File, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	prev := *target
	*target = w
	defer func() { *target = prev }()
	f()
	*target = prev
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
// pi/kido-agents.ts splits it on spaces to learn what it has just created.
func TestSpawnPrintsWindowPaneRun(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "@9", "%9", nil)

	var err error
	out := capture(t, &os.Stdout, func() {
		err = spawnSubagentCmd([]string{
			"--parent-pid", "1", "--parent-session", testParentSession,
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
	if got := marks["%9"]; got != fields[2] {
		t.Errorf("stdout run id %q, mark's run id %q; the two name the same run", fields[2], got)
	}
}

// TestSpawnMarksThePane pins what makes a spawned window reapable at
// all: without @kido_run nothing will ever close it.
func TestSpawnMarksThePane(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "@9", "%9", nil)
	if err := spawnSubagentCmd([]string{
		"--parent-pid", "123", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", writeTaskFile(t, "x"),
	}); err != nil {
		t.Fatal(err)
	}
	if marks["%9"] == "" {
		t.Errorf("mark on %%9 = %q, want a run id a sweep can read back", marks["%9"])
	}
}

func writeTaskFile(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "task.txt")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

const testParentSession = "parent-sess"

func withCallerDepth(t *testing.T, depth int) {
	t.Helper()
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := state.Record(testParentSession, state.Session{
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
	err := spawnSubagentCmd([]string{
		"--parent-pid", "123", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd for a caller at the ceiling = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "maximum nesting") {
		t.Errorf("error = %q, want it to name the depth ceiling", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

// TestSpawnCannotEscapeCeilingWithSmallerDepth: only the caller's own
// state record decides the depth, so the ceiling holds regardless of
// what the caller asks for.
func TestSpawnCannotEscapeCeilingWithSmallerDepth(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, maxDepth)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "do the thing")
	err := spawnSubagentCmd([]string{
		"--parent-pid", "123", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd at the ceiling = nil error, want a refusal")
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
	err := spawnSubagentCmd([]string{
		"--parent-pid", "123", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", taskFile,
	})
	if err != nil {
		t.Fatalf("spawnSubagentCmd landing exactly on the ceiling = %v, want it allowed", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
	if got := (*calls)[0].env; !slices.Contains(got, "KIDO_AGENT_DEPTH=2") {
		t.Errorf("env = %v, want KIDO_AGENT_DEPTH=2", got)
	}
}

// TestSpawnUnreportedCallerIsDepthZero: a caller with no state record
// at all is treated as depth 0, so its child lands at depth 1.
func TestSpawnUnreportedCallerIsDepthZero(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("KIDO_STATE_DIR", t.TempDir()) // empty: no record for the caller
	if err := state.Record(testParentSession, state.Session{
		Agent: state.AgentPi, Pane: "%parent", PID: os.Getpid(), Status: state.Idle,
	}); err != nil {
		t.Fatal(err)
	}
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "do the thing")
	if err := spawnSubagentCmd([]string{
		"--parent-pid", "123", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", taskFile,
	}); err != nil {
		t.Fatalf("spawnSubagentCmd with no caller record = %v, want it allowed at depth 0", err)
	}
	if got := (*calls)[0].env; !slices.Contains(got, "KIDO_AGENT_DEPTH=1") {
		t.Errorf("env = %v, want KIDO_AGENT_DEPTH=1", got)
	}
}

func TestSpawnRejectsUnsafeName(t *testing.T) {
	calls := withNewWindow(t, "@1", "%1", nil)
	for _, name := range []string{`kid"s`, "kid$x", "kid#x", "kid`x", "kid\\x", "kid'x", "kid\nx", "kid\rx"} {
		err := spawnSubagentCmd([]string{
			"--parent-pid", "123", "--parent-session", testParentSession,
			"--name", name, "--task-file", "/tmp/task",
		})
		if err == nil {
			t.Errorf("spawnSubagentCmd with name %q = nil error, want a refusal", name)
		}
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times for an unsafe name, want 0", len(*calls))
	}
}

func TestSpawnRejectsLongName(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, "task")
	err := spawnSubagentCmd([]string{
		"--parent-pid", "123", "--parent-session", testParentSession,
		"--name", strings.Repeat("x", maxWindowNameLen+1), "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd with an over-long name = nil error, want a refusal")
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
	err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid one", "--task-file", taskFile,
	})
	if err != nil {
		t.Fatalf("spawnSubagentCmd with a space in the name = %v, want it allowed", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
}

func TestSpawnMissingTaskFile(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", filepath.Join(t.TempDir(), "does-not-exist.txt"),
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd with a missing --task-file = nil error, want a refusal")
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times for a missing task file, want 0", len(*calls))
	}
}

func TestSpawnRejectsOversizedTaskFile(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)
	taskFile := writeTaskFile(t, strings.Repeat("x", maxTaskBytes+1))
	err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", taskFile,
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd with an oversized task file = nil error, want a refusal")
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
	err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", taskFile,
	})
	if err != nil {
		t.Fatalf("spawnSubagentCmd with a task file exactly at the cap = %v, want it allowed", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
}

// TestSpawnTaskNeverOnCommandLine checks that the task's own text never
// appears in any argument or environment entry handed to tmux.
func TestSpawnTaskNeverOnCommandLine(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@1", "%1", nil)

	const taskText = "secret task text, arbitrary shape\nwith a newline and $(a shell metachar)"
	taskFile := writeTaskFile(t, taskText)

	if err := spawnSubagentCmd([]string{
		"--parent-pid", "123", "--parent-session", testParentSession,
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
	relocated := envValue(t, call.env, "KIDO_AGENT_TASK_FILE")
	if relocated == taskFile {
		t.Errorf("KIDO_AGENT_TASK_FILE = %s, want it relocated into the run directory, not the caller's own path", relocated)
	}
	got, err := os.ReadFile(relocated)
	if err != nil || string(got) != taskText {
		t.Errorf("relocated task file contents = %q, %v, want %q, nil", got, err, taskText)
	}
}

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

func TestSpawnPassesParentAndDepth(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 1)
	calls := withNewWindow(t, "@2", "%3", nil)

	taskFile := writeTaskFile(t, "task")
	err := spawnSubagentCmd([]string{
		"--parent-pid", "555", "--parent-session", testParentSession,
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
		"KIDO_AGENT_PARENT_SESSION=parent-sess",
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
	if err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", taskFile,
	}); err != nil {
		t.Fatal(err)
	}
	// A plain "pi" command gets --session-id inserted, tying the run id to
	// the child's own session from birth.
	got := (*calls)[0].command
	if len(got) != 3 || got[0] != "pi" || got[1] != "--session-id" || got[2] == "" {
		t.Errorf("command = %v, want [pi --session-id <run-id>]", got)
	}
}

// TestSpawnFailureIsAVisibleFailedRun: a spawn whose window creation
// fails records that as the run's outcome, read back through listRuns
// rather than subrun directly.
func TestSpawnFailureIsAVisibleFailedRun(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "", "", errors.New("no such session"))
	if err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", writeTaskFile(t, "task"),
	}); err == nil {
		t.Fatal("spawnSubagentCmd = nil, want the window creation failure")
	}

	var out bytes.Buffer
	if err := listRuns(&out, true); err != nil {
		t.Fatal(err)
	}
	var infos []RunInfo
	if err := json.Unmarshal(out.Bytes(), &infos); err != nil {
		t.Fatalf("runs --json: %v (%q)", err, out.String())
	}
	if len(infos) != 1 || infos[0].Outcome == nil || infos[0].Outcome.Result != subrun.Failed {
		t.Errorf("runs --json = %+v, want one failed run", infos)
	}
}

// TestSpawnMarkFailureKillsTheWindowAndRecordsFailure: a failed markRun
// must not leave the window up unmarked. Its negative control is
// TestSpawnMarkFailureOnAVanishedWindowIsNotAFailure.
func TestSpawnMarkFailureKillsTheWindowAndRecordsFailure(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "@9", "%9", nil)

	var killed []string
	testutil.Swap(t, &killWindow, func(id string) error {
		killed = append(killed, id)
		return nil
	})
	testutil.Swap(t, &markRun, func(paneID, runID string) error { return errors.New("option failed") })

	if err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", writeTaskFile(t, "task"),
	}); err == nil {
		t.Fatal("spawnSubagentCmd = nil, want the mark failure")
	}

	if !slices.Contains(killed, "@9") {
		t.Errorf("killWindow calls = %v, want @9 killed rather than left up unmarked", killed)
	}

	if infos := runOutcomes(t); len(infos) != 1 || infos[0].Outcome == nil || infos[0].Outcome.Result != subrun.Failed {
		t.Errorf("runs --json = %+v, want one failed run", infos)
	}
}

func withVanishedMark(t *testing.T) func() []string {
	t.Helper()
	var killed []string
	testutil.Swap(t, &killWindow, func(id string) error {
		killed = append(killed, id)
		return nil
	})
	testutil.Swap(t, &markRun, func(paneID, runID string) error { return errors.New("cannot find window @9") })
	testutil.Swap(t, &windowExists, func(string) bool { return false })
	return func() []string { return killed }
}

func runOutcomes(t *testing.T) []RunInfo {
	t.Helper()
	var buf bytes.Buffer
	if err := listRuns(&buf, true); err != nil {
		t.Fatal(err)
	}
	var infos []RunInfo
	if err := json.Unmarshal(buf.Bytes(), &infos); err != nil {
		t.Fatalf("runs --json: %v (%q)", err, buf.String())
	}
	return infos
}

// TestSpawnMarkFailureOnAVanishedWindowIsNotAFailure is the negative
// control for the test above: a command that exits fast enough can take
// the window with it before remain-on-exit and the mark are set, and
// that is not a mark failure when the run's own wrapper already recorded
// and reported truthfully.
func TestSpawnMarkFailureOnAVanishedWindowIsNotAFailure(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	withNewWindow(t, "@9", "%9", nil)
	killed := withVanishedMark(t)

	runID := subrun.NewID()
	if err := subrun.Create(runID, "true"); err != nil {
		t.Fatal(err)
	}
	meta := subrun.Meta{ID: runID, Name: "build", Kind: subrun.KindBash, ParentSession: testParentSession}

	var err error
	out := capture(t, &os.Stdout, func() {
		err = createRunWindow(meta, "$0", nil, []string{"kido", "async-run"})
	})
	if err != nil {
		t.Fatalf("createRunWindow = %v, want a window that has already ended reported as the ordinary ending it is", err)
	}
	fields := strings.Fields(out)
	if len(fields) != 4 || fields[0] != "@9" || fields[1] != "%9" || fields[2] != string(runID) {
		t.Errorf("stdout = %q, want the window, pane and run ids the caller parses, and the output path", out)
	} else if fields[3] != subrun.OutputPath(runID) {
		t.Errorf("output field = %q, want %q", fields[3], subrun.OutputPath(runID))
	}
	if len(killed()) != 0 {
		t.Errorf("killWindow calls = %v, want none: the window is already gone", killed())
	}

	if infos := runOutcomes(t); len(infos) != 1 || (infos[0].Outcome != nil && infos[0].Outcome.Result == subrun.Failed) {
		t.Errorf("runs --json = %+v, want the run left for its own command to describe rather than recorded failed here", infos)
	}
}

// TestAgentMarkFailureOnAVanishedWindowIsStillAFailure is the other half
// of the distinction above: an agent run has no wrapper in the window to
// describe its own ending, so the failure recorded here is the only
// account of the run there will be.
func TestAgentMarkFailureOnAVanishedWindowIsStillAFailure(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withNewWindow(t, "@9", "%9", nil)
	killed := withVanishedMark(t)

	err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", writeTaskFile(t, "task"),
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd = nil, want the mark failure reported: nobody else can speak for this run")
	}
	if !slices.Contains(killed(), "@9") {
		t.Errorf("killWindow calls = %v, want @9 killed as any other mark failure is", killed())
	}
	if infos := runOutcomes(t); len(infos) != 1 || infos[0].Outcome == nil || infos[0].Outcome.Result != subrun.Failed {
		t.Errorf("runs --json = %+v, want one failed run", infos)
	}
}

// TestSpawnNoParentIsNotReaped: --no-parent makes a child owned by
// nobody that nothing will collect. The assertion that matters is a real
// sweep, not the field: a record with no Parent is exempt from
// internal/reap's rule 2.
func TestSpawnNoParentIsNotReaped(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@9", "%9", nil)

	if err := spawnSubagentCmd([]string{
		"--no-parent", "--name", "loner", "--task-file", writeTaskFile(t, "stand alone"),
	}); err != nil {
		t.Fatalf("spawnSubagentCmd --no-parent = %v, want it allowed", err)
	}
	for _, kv := range (*calls)[0].env {
		if strings.HasPrefix(kv, "KIDO_AGENT_PARENT_") {
			t.Errorf("env carries %q, want no parent edge at all", kv)
		}
	}

	runID := marks["%9"]
	meta, err := subrun.ReadMeta(subrun.ID(runID))
	if err != nil {
		t.Fatal(err)
	}
	if meta.ParentSession != "" {
		t.Errorf("meta.ParentSession = %q, want it empty", meta.ParentSession)
	}

	panes := []tmux.Pane{
		{PaneID: "%other", WindowID: "@other", SessionID: "$1"},
		{PaneID: "%9", WindowID: "@9", SessionID: "$1", Run: marks["%9"]},
	}
	sessions := []state.Session{{
		Agent: state.AgentPi, Pane: "%9", PID: os.Getpid(), Status: state.Idle,
		ID: "loner-sess", Parent: state.NewParent(meta.ParentSession, 0), Depth: meta.Depth,
	}}
	if closed, _ := reap.Sweep(panes, sessions, time.Now()); len(closed) != 0 {
		t.Errorf("Sweep closed %v, want nothing: a child owned by nobody is not an orphan", closed)
	}
}

// TestSpawnRefusesAFabricatedParentSession: --no-parent is the way to
// spawn without a parent, so a session nobody holds is a mistake rather
// than a spelling of it.
func TestSpawnRefusesAFabricatedParentSession(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@9", "%9", nil)

	err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", "nobody-is-this",
		"--name", "kid", "--task-file", writeTaskFile(t, "task"),
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd with a fabricated --parent-session = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "nobody-is-this") || !strings.Contains(err.Error(), "--no-parent") {
		t.Errorf("error = %q, want it to name the session and point at --no-parent", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal before any tmux call", len(*calls))
	}
}

func TestSpawnNoParentRefusesAParentToo(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@9", "%9", nil)

	err := spawnSubagentCmd([]string{
		"--no-parent", "--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", writeTaskFile(t, "task"),
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd --no-parent with a parent = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "contradicts") {
		t.Errorf("error = %q, want it to say the two contradict each other", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal before any tmux call", len(*calls))
	}
}

// TestSpawnForkCarriesBothFlagsOntoThePiCommandLine: a forked child must
// come up holding both the run id and the caller's transcript. Measured
// against pi 0.85.1: --fork and --session-id compose on the line, in the
// order measured.
func TestSpawnForkCarriesBothFlagsOntoThePiCommandLine(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@7", "%7", nil)

	out := capture(t, &os.Stdout, func() {
		if err := spawnSubagentCmd([]string{
			"--parent-pid", "1", "--parent-session", testParentSession,
			"--name", "kid", "--task-file", writeTaskFile(t, "merge the two branches"),
			"--fork", "caller-session-id",
		}); err != nil {
			t.Fatal(err)
		}
	})
	runID := strings.Fields(out)[2]

	want := []string{"pi", "--fork", "caller-session-id", "--session-id", runID}
	if got := (*calls)[0].command; !reflect.DeepEqual(got, want) {
		t.Errorf("command = %v, want %v", got, want)
	}
	task, err := os.ReadFile(envValue(t, (*calls)[0].env, "KIDO_AGENT_TASK_FILE"))
	if err != nil || string(task) != "merge the two branches" {
		t.Errorf("task file = %q, %v, want the task a forked child is still given", task, err)
	}
}

// TestSpawnForkKeepsTheChildsOwnFlags: --fork is inserted into the pi
// command the caller asked for rather than replacing it.
func TestSpawnForkKeepsTheChildsOwnFlags(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withListModels(t, "acme/claude-sonnet-5")
	calls := withNewWindow(t, "@7", "%7", nil)

	out := capture(t, &os.Stdout, func() {
		if err := spawnSubagentCmd([]string{
			"--parent-pid", "1", "--parent-session", testParentSession,
			"--name", "kid", "--task-file", writeTaskFile(t, "x"),
			"--fork", "caller-session-id",
			"--", "pi", "--name", "kid", "--model", "acme/claude-sonnet-5",
		}); err != nil {
			t.Fatal(err)
		}
	})
	runID := strings.Fields(out)[2]

	want := []string{"pi", "--fork", "caller-session-id", "--session-id", runID, "--name", "kid", "--model", "acme/claude-sonnet-5"}
	if got := (*calls)[0].command; !reflect.DeepEqual(got, want) {
		t.Errorf("command = %v, want %v", got, want)
	}
}

func TestSpawnForkRefusals(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@7", "%7", nil)

	if err := spawnSubagentCmd([]string{"--resume", "run-1", "--fork", "sess-1"}); err == nil {
		t.Error("spawn --resume --fork = nil, want a refusal: a run cannot both continue and be forked from elsewhere")
	}
	if err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", writeTaskFile(t, "x"),
		"--fork", "sess$(id)",
	}); err == nil {
		t.Error("spawn --fork with an unsafe id = nil, want the same refusal a window name gets")
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow called %d times, want 0: nothing refused may reach tmux", len(*calls))
	}
}

// TestValidateModelExactProviderMatch: a full model id is accepted only
// when its own provider is in the configured list; a bare alias like
// "sonnet" is refused the same as an unconfigured provider.
func TestValidateModelExactProviderMatch(t *testing.T) {
	withListModels(t, "acme/claude-sonnet-5", "acme/claude-opus-5", "other/gemini-pro")

	if err := validateModel([]string{"pi", "--model", "acme/claude-sonnet-5"}); err != nil {
		t.Errorf("validateModel(%q) = %v, want nil: it is a configured provider's own model", "acme/claude-sonnet-5", err)
	}
	for _, bad := range []string{"sonnet", "claude-sonnet-5", "nope/claude-sonnet-5"} {
		err := validateModel([]string{"pi", "--model", bad})
		if err == nil {
			t.Errorf("validateModel(%q) = nil, want a refusal", bad)
			continue
		}
		if !strings.Contains(err.Error(), bad) || !strings.Contains(err.Error(), "claude-sonnet-5") {
			t.Errorf("validateModel(%q) error = %q, want it to name the model and list what is configured", bad, err)
		}
	}
}

func TestValidateModelAcceptsNoModelGiven(t *testing.T) {
	called := false
	testutil.Swap(t, &listModels, func() ([]byte, error) {
		called = true
		return nil, errors.New("should never be called")
	})

	for _, command := range [][]string{{"pi"}, {"sh", "--model", "sonnet"}} {
		if err := validateModel(command); err != nil {
			t.Errorf("validateModel(%q) = %v, want nil", command, err)
		}
	}
	if called {
		t.Error("listModels was called for an empty model; want it skipped entirely")
	}
}

func TestValidateModelRefusesWhenListModelsFails(t *testing.T) {
	testutil.Swap(t, &listModels, func() ([]byte, error) { return nil, errors.New("exec: \"pi\": executable file not found in $PATH") })

	err := validateModel([]string{"pi", "--model", "acme/claude-sonnet-5"})
	if err == nil || !strings.Contains(err.Error(), "pi --list-models") {
		t.Errorf("validateModel = %v, want a refusal naming pi --list-models", err)
	}
}

// TestSpawnRefusesUnconfiguredModel: the model on the child's own pi
// command line is checked before any window is created.
func TestSpawnRefusesUnconfiguredModel(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withListModels(t, "acme/claude-sonnet-5")
	calls := withNewWindow(t, "@9", "%9", nil)

	err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "kid", "--task-file", writeTaskFile(t, "x"),
		"--", "pi", "--name", "kid", "--model", "sonnet",
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd with an unconfigured model = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "sonnet") || !strings.Contains(err.Error(), "claude-sonnet-5") {
		t.Errorf("error = %q, want it to name the model and what is configured", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}
