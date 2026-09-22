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

// TestSpawnKeepAliveSetsEnv checks that `kido spawn --keep-alive` reaches
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

// TestSpawnResumeRecreatesWindowBoundToSameRun drives `kido spawn
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
	cmd := fmt.Sprintf("PI_CODING_AGENT_SESSION_DIR=%s %s spawn --resume %s -- /bin/sh -c %s > %s 2>&1",
		shellQuote(sessDir), kidoBin, runID, fake, outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")

	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		t.Fatalf("kido spawn --resume printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	newWindowID, gotRunID := fields[0], fields[2]
	if gotRunID != runID {
		t.Errorf("kido spawn --resume printed run id %q, want the original %q", gotRunID, runID)
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

	out := h.runKido("alpha", "resume-live.out", "spawn", "--resume", runID)
	if !strings.Contains(out, "still running") {
		t.Errorf("kido spawn --resume on a live run = %q, want a refusal naming it still running", out)
	}
}
