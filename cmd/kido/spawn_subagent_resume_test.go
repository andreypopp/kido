package main

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
)

// withPiSessionDir points piSessionDir at dir for the duration of the
// test, so a resume test never depends on a real ~/.pi/agent/sessions.
func withPiSessionDir(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", dir)
}

// writePiSessionFile creates the file piSessionFileExists looks for: pi's
// own "<timestamp>_<id>.jsonl" naming (session-manager.js, see
// spawn.go's piSessionDir doc).
func writePiSessionFile(t *testing.T, dir, runID string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "2026-01-01T00-00-00-000Z_"+runID+".jsonl")
	if err := os.WriteFile(path, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newDeadRun sets up a run record for resume: created, met with a dead
// pid, and (unless the caller wants a live-run test) an outcome recorded
// so EffectiveOutcome reads it as not-running.
func newDeadRun(t *testing.T, id, cwd string) {
	t.Helper()
	if err := subrun.Create(id, "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{
		ID: id, Name: "kid", ParentInstance: "old-parent", Depth: 1,
		Window: "@1", Pane: "%1", PID: deadPID(t), Cwd: cwd, StartedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome(id, subrun.Outcome{Result: subrun.Died, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
}

func TestSpawnResumeRefusesUnknownRunID(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@9", "%9", nil)

	err := spawnSubagentCmd([]string{"--resume", "no-such-run"})
	if err == nil {
		t.Fatal("spawnSubagentCmd --resume with an unknown run id = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "no-such-run") {
		t.Errorf("error = %q, want it to name the run id", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

func TestSpawnResumeRefusesLiveRun(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	if err := subrun.Create("live-run", "x"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{ID: "live-run", Name: "kid", PID: os.Getpid(), Cwd: cwd, StartedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	// No outcome recorded, and Meta.PID is this very test process: alive.

	err := spawnSubagentCmd([]string{"--resume", "live-run"})
	if err == nil {
		t.Fatal("spawnSubagentCmd --resume on a live run = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "still running") {
		t.Errorf("error = %q, want it to say the run is still running", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

func TestSpawnResumeRefusesMissingSessionFile(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withPiSessionDir(t, t.TempDir()) // empty: no session file for this run
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	newDeadRun(t, "gone-run", cwd)

	err := spawnSubagentCmd([]string{"--resume", "gone-run"})
	if err == nil {
		t.Fatal("spawnSubagentCmd --resume with no pi session file = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "no pi session file") {
		t.Errorf("error = %q, want it to say no pi session file was found", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

// TestSpawnResumeContinuesRunRecord checks the success path: the run's
// task, id and StartedAt survive, the outcome is cleared so the run reads
// as running again, the window/pane/pid and parent edge are updated to
// the new spawn, and the launched command resumes by session rather than
// minting one.
func TestSpawnResumeContinuesRunRecord(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "resume-run")
	calls := withNewWindow(t, "@9", "%9", nil)

	// --parent-instance must name somebody currently alive, or spawnResume
	// now refuses before ever reaching newWindow - see liveInstance's own
	// doc.
	if err := state.Record("some-other-pane", state.Session{
		Agent: state.AgentPi, Pane: "%other", PID: os.Getpid(), Status: state.Idle,
		Instance: "new-parent",
	}); err != nil {
		t.Fatal(err)
	}

	cwd := t.TempDir()
	newDeadRun(t, "resume-run", cwd)
	// A screen captured for the first attempt describes that attempt, not
	// the one about to run; resuming must clear it the same way it clears
	// the stale outcome, or `kido runs` would show it as this attempt's own.
	if err := subrun.WriteScreen("resume-run", []byte("first attempt's screen")); err != nil {
		t.Fatal(err)
	}
	originalMeta, err := subrun.ReadMeta("resume-run")
	if err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{
		"--resume", "resume-run",
		"--parent-pid", "777", "--parent-instance", "new-parent",
	}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume = %v, want it to succeed", err)
	}

	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
	call := (*calls)[0]
	if !slices.Contains(call.command, "--session") || !slices.Contains(call.command, "resume-run") {
		t.Errorf("command = %v, want it to resume by --session resume-run, not mint a new one", call.command)
	}
	if call.cwd != cwd {
		t.Errorf("window cwd = %q, want the run's own cwd %q, not the caller's", call.cwd, cwd)
	}
	if got := envValue(t, call.env, "KIDO_AGENT_PARENT_INSTANCE"); got != "new-parent" {
		t.Errorf("KIDO_AGENT_PARENT_INSTANCE = %q, want the resumer's own %q", got, "new-parent")
	}
	if got := envValue(t, call.env, "KIDO_AGENT_RUN_ID"); got != "resume-run" {
		t.Errorf("KIDO_AGENT_RUN_ID = %q, want %q", got, "resume-run")
	}

	got, err := subrun.ReadMeta("resume-run")
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != originalMeta.ID || got.Name != originalMeta.Name || !got.StartedAt.Equal(originalMeta.StartedAt) {
		t.Errorf("meta = %+v, want id/name/startedAt unchanged from %+v", got, originalMeta)
	}
	if got.ParentInstance != "new-parent" || got.Window != "@9" || got.Pane != "%9" || got.PID != fakePanePID {
		t.Errorf("meta = %+v, want the new window/pane/pid and parent edge", got)
	}

	task, err := subrun.ReadTask("resume-run")
	if err != nil || task != "do the thing" {
		t.Errorf("task = %q, %v, want the original task to survive the resume", task, err)
	}

	if _, ok, err := subrun.ReadOutcome("resume-run"); err != nil || ok {
		t.Errorf("ReadOutcome = %v, %v, want the stale outcome cleared so the run reads as running again", ok, err)
	}
	if _, ok, err := subrun.ReadScreen("resume-run"); err != nil || ok {
		t.Errorf("ReadScreen = %v, %v, want the first attempt's screen cleared by the resume", ok, err)
	}
}

// TestSpawnResumeDefaultsParentFromCallersOwnRecord: when --parent-pid/
// --parent-instance are omitted, they come from the caller's own reported
// identity, exactly as depth already does - the resumer becomes the new
// parent without kido runs's printed line having to name it up front.
func TestSpawnResumeDefaultsParentFromCallersOwnRecord(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	// Load() filters out any record whose pid is dead, so the caller's own
	// record needs a real, live pid - this test process's own.
	if err := state.Record("caller", state.Session{
		Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle,
		Instance: "caller-inst", Depth: 0,
	}); err != nil {
		t.Fatal(err)
	}
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "resume-defaulted")
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	newDeadRun(t, "resume-defaulted", cwd)

	if err := spawnSubagentCmd([]string{"--resume", "resume-defaulted"}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume with no parent flags = %v, want it allowed, defaulting from the caller's own record", err)
	}
	call := (*calls)[0]
	if got := envValue(t, call.env, "KIDO_AGENT_PARENT_PID"); got != strconv.Itoa(os.Getpid()) {
		t.Errorf("KIDO_AGENT_PARENT_PID = %q, want the caller's own pid %d", got, os.Getpid())
	}
	if got := envValue(t, call.env, "KIDO_AGENT_PARENT_INSTANCE"); got != "caller-inst" {
		t.Errorf("KIDO_AGENT_PARENT_INSTANCE = %q, want the caller's own instance %q", got, "caller-inst")
	}
}

func TestSpawnResumeRespectsDepthCeiling(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, maxDepth) // caller is already at the ceiling
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "deep-run")
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	newDeadRun(t, "deep-run", cwd)

	err := spawnSubagentCmd([]string{
		"--resume", "deep-run",
		"--parent-pid", "1", "--parent-instance", "p",
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd --resume for a caller at the ceiling = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "maximum nesting") {
		t.Errorf("error = %q, want it to name the depth ceiling", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

// TestSpawnResumeRefusesAnUnverifiableParentInstance pins the fix for the
// window that used to die within moments of a resume: internal/reap's
// rule 2 closes any marked window whose child reports a ParentInstance
// nobody currently alive claims as their own, and KIDO_AGENT_PARENT_INSTANCE
// is exactly what makes a resumed pi report one. Refusing here, before the
// window is ever created, replaces that silent near-instant close (the run
// left recording a useless "died") with an error at spawn time.
func TestSpawnResumeRefusesAnUnverifiableParentInstance(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "orphan-run")
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	newDeadRun(t, "orphan-run", cwd)

	err := spawnSubagentCmd([]string{
		"--resume", "orphan-run",
		"--parent-pid", "777", "--parent-instance", "nobody-is-this",
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd --resume with an unverifiable --parent-instance = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "nobody-is-this") || !strings.Contains(err.Error(), "no currently live agent") {
		t.Errorf("error = %q, want it to name the instance and say nobody currently live claims it", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

// TestSpawnResumeDefaultsModelFromMeta: a bare `--resume` with no `-- pi
// --model ...` used to come up on pi's default provider, which may have no
// API key configured - the run's own meta already remembers what it ran
// under.
func TestSpawnResumeDefaultsModelFromMeta(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "modeled-run")
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	if err := subrun.Create("modeled-run", "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{
		ID: "modeled-run", Name: "kid", Depth: 1, Model: "claude-sonnet-5",
		Window: "@1", Pane: "%1", PID: deadPID(t), Cwd: cwd, StartedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome("modeled-run", subrun.Outcome{Result: subrun.Died, At: time.Now()}); err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{"--resume", "modeled-run", "--parent-pid", "1"}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume = %v, want it to succeed", err)
	}
	call := (*calls)[0]
	if !slices.Contains(call.command, "--model") || !slices.Contains(call.command, "claude-sonnet-5") {
		t.Errorf("command = %v, want the run's own recorded model carried through", call.command)
	}
}

// TestSpawnResumeExplicitModelWinsOverMeta: a caller naming its own --model
// in the command after -- is not overridden by the run's recorded one.
func TestSpawnResumeExplicitModelWinsOverMeta(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "modeled-run-2")
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	if err := subrun.Create("modeled-run-2", "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{
		ID: "modeled-run-2", Name: "kid", Depth: 1, Model: "claude-sonnet-5",
		Window: "@1", Pane: "%1", PID: deadPID(t), Cwd: cwd, StartedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome("modeled-run-2", subrun.Outcome{Result: subrun.Died, At: time.Now()}); err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{
		"--resume", "modeled-run-2", "--parent-pid", "1",
		"--", "pi", "--model", "claude-opus-5",
	}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume = %v, want it to succeed", err)
	}
	call := (*calls)[0]
	got := slices.Contains(call.command, "claude-opus-5")
	wantNotSonnet := !slices.Contains(call.command, "claude-sonnet-5")
	if !got || !wantNotSonnet {
		t.Errorf("command = %v, want the caller's own --model claude-opus-5 kept, meta's claude-sonnet-5 not also appended", call.command)
	}
}

// withResumableRun is the whole setup a resume success path needs: a
// dead run with a pi session file beside it, at a cwd of its own.
func withResumableRun(t *testing.T, id string) {
	t.Helper()
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, id)
	newDeadRun(t, id, t.TempDir())
}

// TestSpawnResumePrintsWindowPaneRun: a resume is spawn_subagent's other
// entry point and its caller parses the same line, so the resume path
// owes stdout the same three fields - with the run id it continued, not
// a new one.
func TestSpawnResumePrintsWindowPaneRun(t *testing.T) {
	withResumableRun(t, "printed-run")
	withNewWindow(t, "@9", "%9", nil)

	var err error
	out := captureStdout(t, func() {
		err = spawnSubagentCmd([]string{"--resume", "printed-run", "--parent-pid", "1"})
	})
	if err != nil {
		t.Fatal(err)
	}
	if out != "@9 %9 printed-run\n" {
		t.Errorf("stdout = %q, want %q", out, "@9 %9 printed-run\n")
	}
}

// TestSpawnResumeMarkFailureKillsTheWindowAndRecordsFailure is the fresh
// spawn's own mark-failure test applied to the path nobody exercises by
// hand: an unmarked window is invisible to internal/reap and so would
// never be closed by anything, and a resume creates exactly the same kind
// of window.
func TestSpawnResumeMarkFailureKillsTheWindowAndRecordsFailure(t *testing.T) {
	withResumableRun(t, "unmarkable-run")
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

	if err := spawnSubagentCmd([]string{"--resume", "unmarkable-run", "--parent-pid", "1"}); err == nil {
		t.Fatal("spawnSubagentCmd --resume = nil, want the mark failure")
	}
	if !slices.Contains(killed, "@9") {
		t.Errorf("killWindow calls = %v, want @9 killed rather than left up unmarked", killed)
	}
	// The resume cleared the old outcome on its way through, so a failure
	// recorded here is the only thing left saying what became of the run.
	if out, ok, err := subrun.ReadOutcome("unmarkable-run"); err != nil || !ok || out.Result != subrun.Failed {
		t.Errorf("ReadOutcome = %+v, %v, %v, want a recorded failure", out, ok, err)
	}
}

// TestSpawnResumeWindowFailureIsAVisibleFailedRun: the resume cleared the
// run's previous outcome before asking tmux for a window, so a window it
// never got has to be recorded, or the run reads as running forever. The
// meta, though, is left alone: a fresh spawn writes one here because it
// has none and the outcome would be invisible without it, while an
// attempt that never reached tmux has nothing truer to say about the run
// than what the last attempt recorded.
func TestSpawnResumeWindowFailureIsAVisibleFailedRun(t *testing.T) {
	withResumableRun(t, "windowless-run")
	withNewWindow(t, "", "", errors.New("no such session"))
	before, err := subrun.ReadMeta("windowless-run")
	if err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{"--resume", "windowless-run", "--parent-pid", "1"}); err == nil {
		t.Fatal("spawnSubagentCmd --resume = nil, want the window creation failure")
	}
	if out, ok, err := subrun.ReadOutcome("windowless-run"); err != nil || !ok || out.Result != subrun.Failed {
		t.Errorf("ReadOutcome = %+v, %v, %v, want a recorded failure", out, ok, err)
	}
	after, err := subrun.ReadMeta("windowless-run")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, after) {
		t.Errorf("meta = %+v, want it untouched at %+v by an attempt that never got a window", after, before)
	}
}

func TestSpawnResumeRefusesNameAndTaskFile(t *testing.T) {
	calls := withNewWindow(t, "@9", "%9", nil)
	for _, args := range [][]string{
		{"--resume", "x", "--name", "kid"},
		{"--resume", "x", "--task-file", "/tmp/task"},
	} {
		if err := spawnSubagentCmd(args); err == nil {
			t.Errorf("spawnSubagentCmd(%v) = nil error, want --resume and %s refused together", args, args[2])
		}
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want every case refused before any tmux call", len(*calls))
	}
}
