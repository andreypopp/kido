package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestWindowFocusedCmd checks `kido window-focused` against a real
// server: the window the client is actually looking at reads "true", and
// any other window "false" - the same tmux.WindowFocused test the linger
// helper and the sweep already share, now callable by pi/kido-agents.ts's
// idle self-exit timer before it decides to shut a session down.
func TestWindowFocusedCmd(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	focused := h.activeWindowID("alpha")
	unfocusedPane := h.newWindow("alpha", "background", "sleep", "300")
	unfocused := h.windowID(unfocusedPane)

	if got := firstLine(h.runKido("alpha", "focused.out", "window-focused", focused)); got != "true" {
		t.Errorf("window-focused on the client's own window = %q, want %q", got, "true")
	}
	if got := firstLine(h.runKido("alpha", "unfocused.out", "window-focused", unfocused)); got != "false" {
		t.Errorf("window-focused on a window nobody is looking at = %q, want %q", got, "false")
	}
}

// firstLine strips runKido's own trailing "rc=N" line, added by its
// script after the command's real output.
func firstLine(s string) string {
	return strings.SplitN(strings.TrimSpace(s), "\n", 2)[0]
}

// TestSpawnKeepAliveSetsEnv checks that `kido spawn_subagent --keep-alive` reaches
// the child's environment as KIDO_AGENT_KEEP_ALIVE=1, the one thing
// pi/kido-agents.ts reads to opt a subagent out of idle self-exit.
func TestSpawnKeepAliveSetsEnv(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	taskFile := filepath.Join(h.dir, "task.txt")
	if err := os.WriteFile(taskFile, []byte("do the thing"), 0o644); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(h.dir, "spawn.out")
	envFile := filepath.Join(h.dir, "child.env")

	h.liveParent("alpha", "p")
	h.runSpawn(outFile, envFile,
		"--parent-pid", "1", "--parent-instance", "p",
		"--name", "kid-keepalive", "--task-file", taskFile,
		"--keep-alive",
	)
	h.waitFileNonEmpty(outFile)
	env := h.waitFileNonEmpty(envFile)
	if got := envLine(env, "KIDO_AGENT_KEEP_ALIVE"); got != "1" {
		t.Errorf("KIDO_AGENT_KEEP_ALIVE = %q, want %q", got, "1")
	}
}

// TestSpawnResumeRecreatesWindowBoundToSameRun drives `kido spawn_subagent
// --resume` against a real server: a run whose window has already died
// and been swept (outcome "died") gets a brand new window, marked for the
// same run id, with the stale outcome cleared so the run reads as running
// again - the whole point being that this is the same run continuing, not
// a second one.
//
// pi is not available in CI, so the launched command is a fake one (as
// every other spawn e2e test uses); PI_CODING_AGENT_SESSION_DIR is set to
// a directory this test controls, holding a file at the exact path
// spawn.go's piSessionDir computes, standing in for pi's own project
// session directory.
func TestSpawnResumeRecreatesWindowBoundToSameRun(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("resume-src", "exec sleep 300")
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	h.killPane(paneID)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sweep to close window %s", windowID))
	// runOutcome (runs_test.go) always reads back through the same
	// runID+"-show.out" file; called a second time below, after resuming,
	// it would otherwise risk reading this first call's leftover output
	// before the second `kido runs` invocation has overwritten it. A
	// distinct outFile per call, via runOutcomeNamed, avoids that race.
	if got := h.runOutcomeNamed("before", runID); got != "died" {
		t.Fatalf("run %s outcome = %q, want %q before resuming", runID, got, "died")
	}

	sessDir := filepath.Join(h.dir, "pi-sessions")
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		t.Fatal(err)
	}
	sessFile := filepath.Join(sessDir, "2026-01-01T00-00-00-000Z_"+runID+".jsonl")
	if err := os.WriteFile(sessFile, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	outFile := filepath.Join(h.dir, "resume.out")
	envFile := filepath.Join(h.dir, "resume.env")
	fake := shellQuote(fmt.Sprintf("env > %s; sleep 300", envFile))
	cmd := fmt.Sprintf("PI_CODING_AGENT_SESSION_DIR=%s %s spawn_subagent --resume %s -- /bin/sh -c %s > %s 2>&1",
		shellQuote(sessDir), kidoBin, runID, fake, outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")

	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		t.Fatalf("kido spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	newWindowID, gotRunID := fields[0], fields[2]
	if gotRunID != runID {
		t.Errorf("kido spawn_subagent --resume printed run id %q, want the original %q", gotRunID, runID)
	}
	if newWindowID == windowID {
		t.Errorf("resumed window id %s must be a new window, not the swept original", newWindowID)
	}

	env := h.waitFileNonEmpty(envFile)
	if got := envLine(env, "KIDO_AGENT_RUN_ID"); got != runID {
		t.Errorf("KIDO_AGENT_RUN_ID = %q, want the original run id %q", got, runID)
	}

	mark := h.in("show-options", "-w", "-v", "-t", newWindowID, "@kido_subagent")
	if !strings.Contains(mark, "run="+runID) {
		t.Errorf("@kido_subagent on the resumed window = %q, want it to name run %s", mark, runID)
	}

	if got := h.runOutcomeNamed("after", runID); got != "running" {
		t.Errorf("run %s outcome = %q after resuming, want %q (the stale died outcome must be cleared)", runID, got, "running")
	}
}

// runOutcomeNamed is runOutcome (runs_test.go) with an explicit tag on the
// output file, for a test that checks the same run id's outcome more than
// once and cannot let two calls share one file.
func (h *harness) runOutcomeNamed(tag, runID string) string {
	h.t.Helper()
	out := h.runKido("alpha", runID+"-"+tag+"-show.out", "runs", "--json", runID)
	var info runInfo
	line := strings.SplitN(out, "\n", 2)[0]
	if err := json.Unmarshal([]byte(line), &info); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return info.Outcome
}

// TestSpawnResumeRefusesLiveRun checks the refusal from inside a real
// server: a run whose window is still up (never swept, no outcome) must
// not be resumed out from under itself.
func TestSpawnResumeRefusesLiveRun(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("live-src", "exec sleep 300")
	t.Cleanup(func() { h.in("kill-window", "-t", windowID) })

	out := h.runKido("alpha", "resume-live.out", "spawn_subagent", "--resume", runID)
	if !strings.Contains(out, "still running") {
		t.Errorf("kido spawn_subagent --resume on a live run = %q, want a refusal naming it still running", out)
	}
}

// spawnRecordedRun is the fixture the two carry tests below share: a run
// spawned with a tool allowlist and keepAlive, then ended so it can be
// resumed at all. It returns the run's id and the directory holding the
// pi session file `--resume` insists on (spawn_subagent.go's
// piSessionFileExists), which the caller passes back in through
// PI_CODING_AGENT_SESSION_DIR.
//
// What the first attempt actually ran does not matter here - only what
// the run recorded - so it is the same fake command every other spawn
// test uses.
func (h *harness) spawnRecordedRun(name string) (runID, sessDir string) {
	h.t.Helper()
	h.liveParent("alpha", "root-inst")
	outFile := filepath.Join(h.dir, name+"-spawn.out")
	h.sendLiteral(fmt.Sprintf(
		"%s spawn_subagent --parent-pid 1 --parent-instance root-inst --name %s "+
			"--task-file %s --tools read,bash --keep-alive -- /bin/sh -c %s > %s 2>&1",
		kidoBin, name, h.writeTaskFile(name), shellQuote("exec sleep 300"), outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		h.t.Fatalf("kido spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	windowID, runID := fields[0], fields[2]

	// Resuming a live run is refused, so the first attempt has to be over:
	// kill it and let the sweep close its window and record the outcome.
	h.killPane(h.in("list-panes", "-t", windowID, "-F", "#{pane_id}"))
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sweep to close window %s", windowID))

	sessDir = filepath.Join(h.dir, name+"-sessions")
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessDir, "2026-01-01T00-00-00-000Z_"+runID+".jsonl"), []byte("{}"), 0o644); err != nil {
		h.t.Fatal(err)
	}
	return runID, sessDir
}

// TestSpawnResumeCarriesKeepAlive: a deliberately long-lived helper that
// came back arming the thirty-second idle timer it was spawned to opt out
// of was not the helper that was spawned. The unit test reads the
// environment kido asked tmux for; here the resumed child reports what it
// actually got, and nothing on the resume command line says keepAlive -
// it can only have come from the run's own record.
func TestSpawnResumeCarriesKeepAlive(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, sessDir := h.spawnRecordedRun("keepalive-carry-e2e")

	outFile := filepath.Join(h.dir, "resume.out")
	envFile := filepath.Join(h.dir, "resume.env")
	fake := shellQuote(fmt.Sprintf("env > %s; sleep 300", envFile))
	h.sendLiteral(fmt.Sprintf("PI_CODING_AGENT_SESSION_DIR=%s %s spawn_subagent --resume %s -- /bin/sh -c %s > %s 2>&1",
		shellQuote(sessDir), kidoBin, runID, fake, outFile))
	h.sendKeys("Enter")
	if out := strings.TrimSpace(h.waitFileNonEmpty(outFile)); len(strings.Fields(out)) != 3 {
		t.Fatalf("kido spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", out)
	}

	if got := envLine(h.waitFileNonEmpty(envFile), "KIDO_AGENT_KEEP_ALIVE"); got != "1" {
		t.Errorf("resumed child's KIDO_AGENT_KEEP_ALIVE = %q, want %q from the run's own record", got, "1")
	}
}

// TestSpawnResumeCarriesToolsOntoThePiCommandLine is the other half, and
// the more important one: a narrow toolset is the blast-radius bound the
// depth ceiling is not, and a resume that quietly handed the full set back
// widened it without anyone asking.
//
// The allowlist is spelled onto the command line only when the command is
// literally `pi`, so this resume names none - which leaves the pane's
// fate to whether that bare name resolves on the machine running the
// suite. Where it does not, the pane exits before kido's second tmux call
// sets remain-on-exit and the window is gone with it (the race noted in
// internal/tmux/tmux.go), so the resume fails outright. Hence the fake pi
// below, on this server's PATH alone: a live pane, whatever is installed.
//
// `pane_start_command` is read rather than anything the child reports,
// because it is the better witness either way: tmux's own record of the
// argv it was handed, past kido's command-line construction and tmux's
// parsers, rather than what kido believed it passed.
func TestSpawnResumeCarriesToolsOntoThePiCommandLine(t *testing.T) {
	t.Parallel()
	h := startPathPrefix(t, "alpha", piBinDir)

	runID, sessDir := h.spawnRecordedRun("tools-carry-e2e")

	outFile := filepath.Join(h.dir, "resume.out")
	h.sendLiteral(fmt.Sprintf("PI_CODING_AGENT_SESSION_DIR=%s %s spawn_subagent --resume %s > %s 2>&1",
		shellQuote(sessDir), kidoBin, runID, outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		t.Fatalf("kido spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	newWindowID := fields[0]

	started := h.in("display-message", "-p", "-t", newWindowID, "#{pane_start_command}")
	if !strings.Contains(started, "--tools read,bash") {
		t.Errorf("resumed pane's command = %q, want the run's own recorded tool allowlist back", started)
	}
	if !strings.Contains(started, "--session "+runID) {
		t.Errorf("resumed pane's command = %q, want it to resume the run's own session", started)
	}
}
