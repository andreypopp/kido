package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The window the client is actually looking at reads "true", any other
// "false" - callable by share/pi/kido-agents.ts's idle self-exit timer before
// it shuts a session down.
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
	for i, c := range []struct{ arg, want string }{
		{"''", "kido window-focused: usage: kido window-focused WINDOW_ID\nrc=1"},
		{"@", `kido window-focused: "@" is not a window id (@N)` + "\nrc=1"},
		{"7", `kido window-focused: "7" is not a window id (@N)` + "\nrc=1"},
		{"@1x", `kido window-focused: "@1x" is not a window id (@N)` + "\nrc=1"},
	} {
		if got := strings.TrimSpace(h.runKido("alpha", fmt.Sprintf("invalid-%d.out", i), "window-focused", c.arg)); got != c.want {
			t.Errorf("window-focused %s = %q, want %q", c.arg, got, c.want)
		}
	}
}

// firstLine strips runKido's own trailing "rc=N" line.
func firstLine(s string) string {
	return strings.SplitN(strings.TrimSpace(s), "\n", 2)[0]
}

// --keep-alive reaches the child's environment as KIDO_AGENT_KEEP_ALIVE=1,
// the one thing share/pi/kido-agents.ts reads to opt out of idle self-exit.
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
		"--parent-pid", "1", "--parent-session", "p",
		"--name", "kid-keepalive", "--task-file", taskFile,
		"--keep-alive",
	)
	h.waitFileNonEmpty(outFile)
	env := h.waitFileNonEmpty(envFile)
	if got := envLine(env, "KIDO_AGENT_KEEP_ALIVE"); got != "1" {
		t.Errorf("KIDO_AGENT_KEEP_ALIVE = %q, want %q", got, "1")
	}
}

// A run whose window died and was swept (outcome "died") gets a brand
// new window marked for the same run id, with the stale outcome cleared:
// the same run continuing, not a second one.
//
// pi is not available in CI, so the launched command is a fake one; the
// session dir holds a file at the exact path pi_session_file_exists
// (lib/spawn_subagent.ml) computes, standing in for pi's project session dir.
func TestSpawnResumeRecreatesWindowBoundToSameRun(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("resume-src", "exec sleep 300")
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	h.killPane(paneID)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sweep to close window %s", windowID))
	// runOutcomeNamed, not runOutcome, so the second call below does not risk
	// reading this call's leftover output file before it is overwritten.
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
	newWindowID, newPaneID, gotRunID := fields[0], fields[1], fields[2]
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

	mark := h.in("show-options", "-p", "-v", "-t", newPaneID, "@kido_run")
	if mark != runID {
		t.Errorf("@kido_run on the resumed pane = %q, want it to name run %s", mark, runID)
	}

	if got := h.runOutcomeNamed("after", runID); got != "running" {
		t.Errorf("run %s outcome = %q after resuming, want %q (the stale died outcome must be cleared)", runID, got, "running")
	}
}

// runOutcomeNamed is runOutcome (runs_test.go) with a tag on the output
// file, for a test checking one run id's outcome more than once.
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

// A run whose window is still up (never swept, no outcome) must not be
// resumed out from under itself.
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
// resumed. Returns the run id and the session dir `--resume` insists on
// (lib/spawn_subagent.ml's pi_session_file_exists).
func (h *harness) spawnRecordedRun(name string) (runID, sessDir string) {
	h.t.Helper()
	h.liveParent("alpha", "root-e2e")
	outFile := filepath.Join(h.dir, name+"-spawn.out")
	h.sendLiteral(fmt.Sprintf(
		"%s spawn_subagent --parent-pid 1 --parent-session root-e2e --name %s "+
			"--task-file %s --tools read,bash --keep-alive -- /bin/sh -c %s > %s 2>&1",
		kidoBin, name, h.writeTaskFile(name), shellQuote("exec sleep 300"), outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		h.t.Fatalf("kido spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	windowID, runID := fields[0], fields[2]

	// Resuming a live run is refused, so the first attempt must be over first.
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

// Nothing on the resume command line says keepAlive; it can only have
// come from the run's own record, and the resumed child reports what it
// actually got, not what kido asked tmux for.
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

// A narrow toolset is a blast-radius bound the depth ceiling is not; a
// resume that quietly handed the full set back would widen it unasked.
//
// The allowlist is spelled onto the command line only when the command is
// literally `pi`; whether that name resolves decides whether the pane
// lives long enough to set remain-on-exit (Tmux.Exec.new_window's
// race), so this test's own fake pi goes on this server's PATH alone.
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

	started := h.startCommand(newWindowID)
	if !strings.Contains(started, "--tools read,bash") {
		t.Errorf("resumed pane's command = %q, want the run's own recorded tool allowlist back", started)
	}
	if !strings.Contains(started, "--session "+runID) {
		t.Errorf("resumed pane's command = %q, want it to resume the run's own session", started)
	}
}
