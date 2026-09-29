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
	"kido/internal/testutil"
)

func withPiSessionDir(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PI_CODING_AGENT_SESSION_DIR", dir)
}

// writePiSessionFile creates the file piSessionFileExists looks for: pi's
// "<timestamp>_<id>.jsonl" naming (session-manager.js).
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

func newDeadRun(t *testing.T, id subrun.ID, cwd string) {
	t.Helper()
	if err := subrun.Create(id, "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{
		ID: id, Name: "kid", ParentSession: "old-parent", Depth: 1,
		Pane: "%1", PID: testutil.DeadPID(t), Cwd: cwd, StartedAt: time.Now(),
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

// TestSpawnResumeWithNoSessionFileRespawnsUnderTheSameRunID: with no pi
// session file on disk, the run id is free rather than stale, so this
// mints a fresh session under it with --session-id instead of --session,
// and clears the "delivered" marker so the stored task is redelivered.
func TestSpawnResumeWithNoSessionFileRespawnsUnderTheSameRunID(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withPiSessionDir(t, t.TempDir()) // empty: no session file for this run
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	newDeadRun(t, "gone-run", cwd)
	if err := os.WriteFile(subrun.DeliveredPath("gone-run"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{"--resume", "gone-run"}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume with no pi session file = %v, want it to mint a fresh session instead of refusing", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("newWindow called %d times, want 1", len(*calls))
	}
	call := (*calls)[0]
	if !slices.Contains(call.command, "--session-id") || !slices.Contains(call.command, "gone-run") {
		t.Errorf("command = %v, want it to mint a fresh session under the run's own id (--session-id gone-run)", call.command)
	}
	if slices.Contains(call.command, "--session") {
		t.Errorf("command = %v, want --session-id, never --session, since no session file exists to resume", call.command)
	}
	if _, err := os.Stat(subrun.DeliveredPath("gone-run")); !os.IsNotExist(err) {
		t.Errorf("delivered marker still exists (err=%v), want it cleared so the stored task is redelivered", err)
	}
}

func TestSpawnResumeContinuesRunRecord(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "resume-run")
	calls := withNewWindow(t, "@9", "%9", nil)

	if err := state.Record("new-parent", state.Session{
		Agent: state.AgentPi, Pane: "%other", PID: os.Getpid(), Status: state.Idle,
	}); err != nil {
		t.Fatal(err)
	}

	cwd := t.TempDir()
	newDeadRun(t, "resume-run", cwd)
	if err := subrun.WriteScreen("resume-run", []byte("first attempt's screen")); err != nil {
		t.Fatal(err)
	}
	originalMeta, err := subrun.ReadMeta("resume-run")
	if err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{
		"--resume", "resume-run",
		"--parent-pid", "777", "--parent-session", "new-parent",
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
	if got := envValue(t, call.env, "KIDO_AGENT_PARENT_SESSION"); got != "new-parent" {
		t.Errorf("KIDO_AGENT_PARENT_SESSION = %q, want the resumer's own %q", got, "new-parent")
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
	if got.ParentSession != "new-parent" || got.Pane != "%9" || got.PID != fakePanePID {
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
// --parent-session are omitted, they come from the caller's own reported
// identity.
func TestSpawnResumeDefaultsParentFromCallersOwnRecord(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := state.Record("caller-sess", state.Session{
		Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle,
		Depth: 0,
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
	if got := envValue(t, call.env, "KIDO_AGENT_PARENT_SESSION"); got != "caller-sess" {
		t.Errorf("KIDO_AGENT_PARENT_SESSION = %q, want the caller's own session %q", got, "caller-sess")
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
		"--parent-pid", "1", "--parent-session", "p",
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

// TestSpawnResumeRefusesAnUnverifiableParentSession: internal/reap's
// rule 2 closes any marked window whose child reports a Parent nobody
// currently alive claims as their own, so this is refused before the
// window is ever created.
func TestSpawnResumeRefusesAnUnverifiableParentSession(t *testing.T) {
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
		"--parent-pid", "777", "--parent-session", "nobody-is-this",
	})
	if err == nil {
		t.Fatal("spawnSubagentCmd --resume with an unverifiable --parent-session = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "nobody-is-this") || !strings.Contains(err.Error(), "no currently live agent") {
		t.Errorf("error = %q, want it to name the session and say nobody currently live holds it", err)
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
	}
}

func TestSpawnResumeDefaultsModelFromMeta(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withListModels(t, "acme/claude-sonnet-5")
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "modeled-run")
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	if err := subrun.Create("modeled-run", "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{
		ID: "modeled-run", Name: "kid", Depth: 1, Model: "acme/claude-sonnet-5",
		Pane: "%1", PID: testutil.DeadPID(t), Cwd: cwd, StartedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome("modeled-run", subrun.Outcome{Result: subrun.Died, At: time.Now()}); err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{"--resume", "modeled-run"}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume = %v, want it to succeed", err)
	}
	call := (*calls)[0]
	if !slices.Contains(call.command, "--model") || !slices.Contains(call.command, "acme/claude-sonnet-5") {
		t.Errorf("command = %v, want the run's own recorded model carried through", call.command)
	}
}

func TestSpawnResumeExplicitModelWinsOverMeta(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	withListModels(t, "acme/claude-sonnet-5", "acme/claude-opus-5")
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "modeled-run-2")
	calls := withNewWindow(t, "@9", "%9", nil)

	cwd := t.TempDir()
	if err := subrun.Create("modeled-run-2", "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{
		ID: "modeled-run-2", Name: "kid", Depth: 1, Model: "acme/claude-sonnet-5",
		Pane: "%1", PID: testutil.DeadPID(t), Cwd: cwd, StartedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome("modeled-run-2", subrun.Outcome{Result: subrun.Died, At: time.Now()}); err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{
		"--resume", "modeled-run-2",
		"--", "pi", "--model", "acme/claude-opus-5",
	}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume = %v, want it to succeed", err)
	}
	call := (*calls)[0]
	got := slices.Contains(call.command, "acme/claude-opus-5")
	wantNotSonnet := !slices.Contains(call.command, "acme/claude-sonnet-5")
	if !got || !wantNotSonnet {
		t.Errorf("command = %v, want the caller's own --model acme/claude-opus-5 kept, meta's acme/claude-sonnet-5 not also appended", call.command)
	}
}

func withResumableRun(t *testing.T, id string) {
	t.Helper()
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, id)
	newDeadRun(t, subrun.ID(id), t.TempDir())
}

func TestSpawnResumePrintsWindowPaneRun(t *testing.T) {
	withResumableRun(t, "printed-run")
	withNewWindow(t, "@9", "%9", nil)

	var err error
	out := capture(t, &os.Stdout, func() {
		err = spawnSubagentCmd([]string{"--resume", "printed-run"})
	})
	if err != nil {
		t.Fatal(err)
	}
	if out != "@9 %9 printed-run\n" {
		t.Errorf("stdout = %q, want %q", out, "@9 %9 printed-run\n")
	}
}

func TestSpawnResumeMarkFailureKillsTheWindowAndRecordsFailure(t *testing.T) {
	withResumableRun(t, "unmarkable-run")
	withNewWindow(t, "@9", "%9", nil)

	var killed []string
	testutil.Swap(t, &killWindow, func(id string) error {
		killed = append(killed, id)
		return nil
	})
	testutil.Swap(t, &markRun, func(paneID, runID string) error { return errors.New("option failed") })

	if err := spawnSubagentCmd([]string{"--resume", "unmarkable-run"}); err == nil {
		t.Fatal("spawnSubagentCmd --resume = nil, want the mark failure")
	}
	if !slices.Contains(killed, "@9") {
		t.Errorf("killWindow calls = %v, want @9 killed rather than left up unmarked", killed)
	}
	if out, ok, err := subrun.ReadOutcome("unmarkable-run"); err != nil || !ok || out.Result != subrun.Failed {
		t.Errorf("ReadOutcome = %+v, %v, %v, want a recorded failure", out, ok, err)
	}
}

// TestSpawnResumeWindowFailureIsAVisibleFailedRun: a window the resume
// never got has to be recorded, or the run reads as running forever. The
// meta is left alone, unlike a fresh spawn's.
func TestSpawnResumeWindowFailureIsAVisibleFailedRun(t *testing.T) {
	withResumableRun(t, "windowless-run")
	withNewWindow(t, "", "", errors.New("no such session"))
	before, err := subrun.ReadMeta("windowless-run")
	if err != nil {
		t.Fatal(err)
	}

	if err := spawnSubagentCmd([]string{"--resume", "windowless-run"}); err == nil {
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
		{"--resume", "x", "--parent-pid", "1"},
	} {
		if err := spawnSubagentCmd(args); err == nil {
			t.Errorf("spawnSubagentCmd(%v) = nil error, want --resume and %s refused together", args, args[2])
		}
	}
	if len(*calls) != 0 {
		t.Errorf("newWindow was called %d times, want every case refused before any tmux call", len(*calls))
	}
}

// TestSpawnResumeCarriesKeepAliveAndTools: a resumed run must carry
// forward its recorded keepAlive and tool allowlist, not the defaults.
// The fixture is a real fresh spawn rather than a hand-written meta, so
// this fails if either the recording half or the carrying half is
// dropped.
func TestSpawnResumeCarriesKeepAliveAndTools(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	calls := withNewWindow(t, "@9", "%9", nil)

	withListModels(t, "acme/claude-sonnet-5")

	if err := spawnSubagentCmd([]string{
		"--parent-pid", "1", "--parent-session", testParentSession,
		"--name", "helper", "--task-file", writeTaskFile(t, "hold the line"),
		"--model", "acme/claude-sonnet-5", "--tools", "read,bash", "--keep-alive",
	}); err != nil {
		t.Fatalf("fresh spawn = %v, want it to succeed", err)
	}
	runID := marks["%9"]
	if meta, err := subrun.ReadMeta(subrun.ID(runID)); err != nil {
		t.Fatal(err)
	} else if !meta.KeepAlive || !reflect.DeepEqual(meta.Tools, []string{"read", "bash"}) {
		t.Fatalf("meta = %+v, want keepAlive and the tool allowlist recorded", meta)
	}

	if err := subrun.RecordOutcome(subrun.ID(runID), subrun.Outcome{Result: subrun.Completed, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	writePiSessionFile(t, sessDir, runID)

	if err := spawnSubagentCmd([]string{
		"--resume", runID, "--parent-pid", "1", "--parent-session", testParentSession,
	}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume = %v, want it to succeed", err)
	}
	resumed := (*calls)[1]
	if envValue(t, resumed.env, "KIDO_AGENT_KEEP_ALIVE") != "1" {
		t.Errorf("env = %v, want KIDO_AGENT_KEEP_ALIVE=1 carried through by the run's own record", resumed.env)
	}
	if i := slices.Index(resumed.command, "--tools"); i < 0 || resumed.command[i+1] != "read,bash" {
		t.Errorf("command = %v, want the run's own recorded tool allowlist back", resumed.command)
	}
	if meta, err := subrun.ReadMeta(subrun.ID(runID)); err != nil {
		t.Fatal(err)
	} else if !meta.KeepAlive {
		t.Errorf("meta.KeepAlive = false after a resume that kept it alive")
	}
}

// TestSpawnResumeWithoutRecordedKeepAliveOrTools: a meta.json with
// neither key must resume as a plain child with the full toolset,
// rather than fail or find nothing to read.
func TestSpawnResumeWithoutRecordedKeepAliveOrTools(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0)
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "old-run")
	calls := withNewWindow(t, "@9", "%9", nil)

	newDeadRun(t, "old-run", t.TempDir()) // no Model, no Tools, no KeepAlive

	if err := spawnSubagentCmd([]string{
		"--resume", "old-run", "--parent-pid", "1", "--parent-session", testParentSession,
	}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume of a run recorded without them = %v, want it to succeed", err)
	}
	call := (*calls)[0]
	if slices.Contains(call.command, "--tools") {
		t.Errorf("command = %v, want no --tools invented for a run that recorded none", call.command)
	}
	for _, kv := range call.env {
		if strings.HasPrefix(kv, "KIDO_AGENT_KEEP_ALIVE") {
			t.Errorf("env carries %q, want no keepAlive for a run that recorded none", kv)
		}
	}
	if err := subrun.ResetForResume("old-run", false); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome("old-run", subrun.Outcome{Result: subrun.Died, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := spawnSubagentCmd([]string{
		"--resume", "old-run", "--parent-pid", "1", "--parent-session", testParentSession,
		"--keep-alive",
	}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume --keep-alive = %v, want it to succeed", err)
	}
	if envValue(t, (*calls)[1].env, "KIDO_AGENT_KEEP_ALIVE") != "1" {
		t.Errorf("env = %v, want the explicit --keep-alive through", (*calls)[1].env)
	}
}

// TestSpawnResumeNoParentDropsTheCallersOwnEdge: --resume defaults the
// parent edge to the caller's own record; --no-parent drops it.
func TestSpawnResumeNoParentDropsTheCallersOwnEdge(t *testing.T) {
	withPanes(t, samePane)
	t.Setenv("TMUX_PANE", "%1")
	withCallerDepth(t, 0) // the caller does have a session of its own
	sessDir := t.TempDir()
	withPiSessionDir(t, sessDir)
	writePiSessionFile(t, sessDir, "handed-over")
	calls := withNewWindow(t, "@9", "%9", nil)

	newDeadRun(t, "handed-over", t.TempDir())

	if err := spawnSubagentCmd([]string{"--resume", "handed-over", "--no-parent"}); err != nil {
		t.Fatalf("spawnSubagentCmd --resume --no-parent = %v, want it allowed", err)
	}
	for _, kv := range (*calls)[0].env {
		if strings.HasPrefix(kv, "KIDO_AGENT_PARENT_") {
			t.Errorf("env carries %q, want no parent edge at all", kv)
		}
	}
	if meta, err := subrun.ReadMeta("handed-over"); err != nil {
		t.Fatal(err)
	} else if meta.ParentSession != "" {
		t.Errorf("meta.ParentSession = %q, want the run's old edge dropped", meta.ParentSession)
	}
}
