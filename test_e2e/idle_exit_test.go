package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The window the client is actually looking at reads "true", any other
// "false" - callable by share/pi/kido-agents.ts's idle self-exit timer before
// it shuts a session down.
func TestGetWindowCmd(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	focused := h.activeWindowID("alpha")
	unfocusedPane := h.newWindow("alpha", "background", "sleep", "300")
	unfocused := h.windowID(unfocusedPane)

	for i, c := range []struct {
		id      string
		focused bool
	}{
		{focused, true}, {unfocused, false}, {"@999999", false},
	} {
		want := fmt.Sprintf(`{"id":%q,"focused":%t}`, c.id, c.focused)
		if got := firstLine(h.runKido("alpha", fmt.Sprintf("focus-%d.out", i), "get-window", c.id)); got != want {
			t.Errorf("get-window %s = %q, want %q", c.id, got, want)
		}
	}
	for i, c := range []struct{ arg, want string }{
		{"''", "kido get-window: usage: kido get-window WINDOW_ID\nrc=1"},
		{"@", `kido get-window: "@" is not a window id (@N)` + "\nrc=1"},
		{"7", `kido get-window: "7" is not a window id (@N)` + "\nrc=1"},
		{"@1x", `kido get-window: "@1x" is not a window id (@N)` + "\nrc=1"},
	} {
		if got := strings.TrimSpace(h.runKido("alpha", fmt.Sprintf("invalid-%d.out", i), "get-window", c.arg)); got != c.want {
			t.Errorf("get-window %s = %q, want %q", c.arg, got, c.want)
		}
	}
}

// firstLine strips runKido's own trailing "rc=N" line.
func firstLine(s string) string {
	return strings.SplitN(strings.TrimSpace(s), "\n", 2)[0]
}

func TestSpawnKeepAliveSetsRunMetadata(t *testing.T) {
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
	fields := strings.Fields(h.waitFileNonEmpty(outFile))
	if len(fields) != 3 {
		t.Fatalf("spawn output = %q", fields)
	}
	h.waitFileNonEmpty(envFile)
	if got := h.runMeta("keepalive", fields[2])["keepAlive"]; got != true {
		t.Errorf("keepAlive = %v, want true", got)
	}
	var lookup map[string]any
	if err := json.Unmarshal([]byte(firstLine(h.runKido("alpha", "lookup.out", "get-agent", fields[2], "--children"))), &lookup); err != nil {
		t.Fatal(err)
	}
	if lookup["keepAlive"] != true {
		t.Errorf("get-agent keepAlive = %v, want true", lookup["keepAlive"])
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

	runID, windowID := h.spawnRun("resume-src", "echo resume-screen-e2e; exec sleep 300")
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	h.killPane(paneID)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sweep to close window %s", windowID))
	// runOutcomeNamed, not runOutcome, so the second call below does not risk
	// reading this call's leftover output file before it is overwritten.
	if got := h.runOutcomeNamed("before", runID); got != "died" {
		t.Fatalf("run %s outcome = %q, want %q before resuming", runID, got, "died")
	}
	before := h.runMeta("before", runID)
	if screen, _ := before["screen"].(string); !strings.Contains(screen, "resume-screen-e2e") {
		t.Fatalf("run %s screen = %q, want the sweep's capture of the first attempt", runID, screen)
	}
	newParentPane := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.agentStatus("new-parent-e2e", newParentPane, "pi", "idle")

	sessDir := filepath.Join(h.dir, "pi-sessions")
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		t.Fatal(err)
	}
	sessFile := filepath.Join(sessDir, "2026-01-01T00-00-00-000Z_"+runID+".jsonl")
	if err := os.WriteFile(sessFile, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Typed from another directory, under another parent: a resume keeps
	// the run's own cwd, since pi sessions are project-scoped.
	outFile := filepath.Join(h.dir, "resume.out")
	envFile := filepath.Join(h.dir, "resume.env")
	fake := shellQuote(fmt.Sprintf("env > %s; pwd >> %s; sleep 300", envFile, envFile))
	cmd := fmt.Sprintf("cd / && PI_CODING_AGENT_SESSION_DIR=%s %s tool spawn_subagent --resume %s --parent-pid 777 --parent-session new-parent-e2e --keep-alive -- /bin/sh -c %s > %s 2>&1",
		shellQuote(sessDir), kidoBin, runID, fake, outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")

	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		t.Fatalf("kido tool spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	newWindowID, newPaneID, gotRunID := fields[0], fields[1], fields[2]
	if gotRunID != runID {
		t.Errorf("kido tool spawn_subagent --resume printed run id %q, want the original %q", gotRunID, runID)
	}
	if newWindowID == windowID {
		t.Errorf("resumed window id %s must be a new window, not the swept original", newWindowID)
	}

	env := h.waitFileNonEmpty(envFile)
	for k, want := range map[string]string{
		"KIDO_AGENT_RUN_ID":         runID,
		"KIDO_AGENT_PARENT_SESSION": "new-parent-e2e",
		"KIDO_AGENT_PARENT_PID":     "777",
	} {
		if got := envLine(env, k); got != want {
			t.Errorf("resumed child's %s = %q, want %q", k, got, want)
		}
	}
	lines := strings.Split(strings.TrimRight(env, "\n"), "\n")
	wantCwd, err := filepath.EvalSymlinks(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	if cwd := lines[len(lines)-1]; cwd != wantCwd {
		t.Errorf("resumed child's cwd = %q, want the run's own %q", cwd, wantCwd)
	}
	after := h.runMeta("after", runID)
	if _, ok := after["screen"]; ok {
		t.Errorf("run %s still shows the first attempt's screen after resuming", runID)
	}
	if after["keepAlive"] != true {
		t.Errorf("resumed keepAlive = %v, want true", after["keepAlive"])
	}
	if after["startedAt"] != before["startedAt"] || after["parentSession"] != "new-parent-e2e" {
		t.Errorf("resumed meta startedAt=%v parentSession=%v, want startedAt %v kept and the new parent",
			after["startedAt"], after["parentSession"], before["startedAt"])
	}

	mark := h.in("show-options", "-p", "-v", "-t", newPaneID, "@kido_run")
	if mark != runID {
		t.Errorf("@kido_run on the resumed pane = %q, want it to name run %s", mark, runID)
	}

	if got := h.runOutcomeNamed("after", runID); got != "running" {
		t.Errorf("run %s outcome = %q after resuming, want %q (the stale died outcome must be cleared)", runID, got, "running")
	}
}

// A completed pane can linger across a resume. Collecting that old life
// must not capture its screen or record an ending for the new one.
func TestSpawnResumeBeforeOldPaneIsSwept(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.hideSidebar()
	in := h.asyncParent("alpha", "resume-parent-e2e")
	gate := filepath.Join(h.dir, "finish")
	fake := filepath.Join(h.dir, "pi")
	script := fmt.Sprintf(`#!/bin/bash
%s agent-status --agent pi --session "$KIDO_AGENT_RUN_ID" --parent-session resume-parent-e2e
until [ -f %s ]; do
  [ "$SECONDS" -lt 10 ] || exit 1
  read -r -t 1 ignored
done
printf 'finished first life' | %s tool notify_parent
%s run-outcome --result completed -- "$KIDO_AGENT_RUN_ID"
`, kidoBin, shellQuote(gate), kidoBin, kidoBin)
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	out := h.runKido("alpha", "first-life.out", "tool", "spawn_subagent", "--parent-pid", "1",
		"--parent-session", "resume-parent-e2e", "--name", "resumable",
		"--task-file", h.writeTaskFile("resumable"), "--", fake)
	fields := strings.Fields(firstLine(out))
	if len(fields) != 3 {
		t.Fatalf("spawn output = %q", out)
	}
	oldWindow, oldPane, runID := fields[0], fields[1], fields[2]
	if err := os.WriteFile(gate, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { return h.in("display-message", "-p", "-t", oldPane, "#{pane_dead}") == "1" }, settle,
		msgf("the reported first life to exit"))
	if got := h.runOutcomeNamed("first-life", runID); got != "completed" {
		t.Fatalf("first life outcome = %q, want completed", got)
	}
	if len(in.Received()) != 1 || !strings.Contains(in.Received()[0], "finished first life") {
		t.Fatalf("first life notices = %q", in.Received())
	}
	out = h.runKido("alpha", "second-life.out", "tool", "spawn_subagent", "--resume", runID,
		"--parent-pid", "1", "--parent-session", "resume-parent-e2e", "--", "/bin/sh", "-c", shellQuote("exec sleep 300"))
	fields = strings.Fields(firstLine(out))
	if len(fields) != 3 {
		t.Fatalf("resume output = %q", out)
	}
	newPane := fields[1]
	attempt := 0
	h.waitFor(func() bool {
		attempt++
		h.runKido("alpha", fmt.Sprintf("collect-old-%d.out", attempt), "reap")
		return !h.windowExists(oldWindow)
	}, settle, msgf("the old pane to be collected"))
	if got := h.runOutcomeNamed("second-life", runID); got != "running" {
		t.Errorf("resumed live run outcome = %q, want running", got)
	}
	if got := h.in("display-message", "-p", "-t", newPane, "#{pane_dead}"); got != "0" {
		t.Errorf("resumed pane dead = %q, want 0", got)
	}
	if _, ok := h.runMeta("second-life", runID)["screen"]; ok {
		t.Error("resumed live run has the old life's screen")
	}
	h.stableCount(in, 1, "a resumed live run must not send an inferred ending")
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

	out := h.runKido("alpha", "resume-live.out", "tool", "spawn_subagent", "--resume", runID)
	if !strings.Contains(out, "still running") {
		t.Errorf("kido tool spawn_subagent --resume on a live run = %q, want a refusal naming it still running", out)
	}
	h.expectKido(h.firstPane("alpha"), "", nil, "", "run-outcome", "--result", "completed", "--", runID)
	out, rc := h.kidoAs(h.firstPane("alpha"), "", nil, "tool", "spawn_subagent", "--resume", runID)
	if rc != 1 || !strings.Contains(out, "still running") {
		t.Errorf("resume a live run with an outcome: got (rc=%d) %q, want rc=1 and still running", rc, out)
	}
	want := fmt.Sprintf("kido tool spawn_subagent: run \"no-such-run\": no readable %s\nrc=1\n",
		filepath.Join(h.stateDir, "runs", "no-such-run", "meta.json"))
	if got := h.runKido("alpha", "resume-unknown.out", "tool", "spawn_subagent", "--resume", "no-such-run"); got != want {
		t.Errorf("kido tool spawn_subagent --resume no-such-run = %q, want %q", got, want)
	}
}

// resumeRun ends a run's current attempt and resumes it with a fake
// command that dumps its environment, returning that environment and the
// new attempt's window.
func (h *harness) resumeRun(tag, runID, windowID, sessDir string, flags ...string) (env, newWindowID string) {
	h.t.Helper()
	h.killPane(h.in("list-panes", "-t", windowID, "-F", "#{pane_id}"))
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sweep to close window %s", windowID))
	outFile := filepath.Join(h.dir, tag+".out")
	envFile := filepath.Join(h.dir, tag+".env")
	fake := shellQuote(fmt.Sprintf("env > %s; sleep 300", envFile))
	h.sendLiteral(fmt.Sprintf("PI_CODING_AGENT_SESSION_DIR=%s %s tool spawn_subagent --resume %s %s -- /bin/sh -c %s > %s 2>&1",
		shellQuote(sessDir), kidoBin, runID, strings.Join(flags, " "), fake, outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		h.t.Fatalf("kido tool spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	return h.waitFileNonEmpty(envFile), fields[0]
}

// With no parent flags a resume's child is the caller's own, by the
// caller's record, and --no-parent drops even that; neither invents a
// keep-alive the run never had.
func TestSpawnResumeParentIsTheCallersOrNobody(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("edge-src", "exec sleep 300")
	sessDir := filepath.Join(h.dir, "pi-sessions")
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sessDir, "2026-01-01T00-00-00-000Z_"+runID+".jsonl"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	env, windowID := h.resumeRun("defaulted", runID, windowID, sessDir)
	for k, want := range map[string]string{"KIDO_AGENT_PARENT_SESSION": "root-e2e"} {
		if got := envLine(env, k); got != want {
			t.Errorf("resumed child's %s = %q, want %q", k, got, want)
		}
	}

	if got, _ := h.runMeta("defaulted", runID)["keepAlive"].(bool); got {
		t.Errorf("resumed keepAlive = %v, want false", got)
	}

	env, _ = h.resumeRun("handed-over", runID, windowID, sessDir, "--no-parent")
	for _, k := range []string{"KIDO_AGENT_PARENT_SESSION", "KIDO_AGENT_PARENT_PID"} {
		if got := envLine(env, k); got != "" {
			t.Errorf("child resumed with --no-parent has %s = %q, want it unset", k, got)
		}
	}
	if got, _ := h.runMeta("handed-over", runID)["parentSession"].(string); got != "" {
		t.Errorf("run meta parentSession = %q after --no-parent, want none", got)
	}
}

// With no pi session file under the run's id there is nothing to resume:
// the id is free, not stale, so the child mints a session under it with
// --session-id, and the delivered marker goes so the stored task is
// delivered again. TestSpawnResumeCarriesToolsOntoThePiCommandLine is the
// other half: a file there, `--session`, and the marker kept.
func TestSpawnResumeWithNoPiSessionMintsOne(t *testing.T) {
	t.Parallel()
	h := startPathPrefix(t, "alpha", piBinDir)

	runID, windowID := h.spawnRun("mint-src", "exec sleep 300")
	h.killPane(h.in("list-panes", "-t", windowID, "-F", "#{pane_id}"))
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sweep to close window %s", windowID))
	delivered := filepath.Join(h.stateDir, "runs", runID, "delivered")
	if err := os.WriteFile(delivered, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	outFile := filepath.Join(h.dir, "resume.out")
	h.sendLiteral(fmt.Sprintf("PI_CODING_AGENT_SESSION_DIR=%s %s tool spawn_subagent --resume %s > %s 2>&1",
		shellQuote(t.TempDir()), kidoBin, runID, outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		t.Fatalf("kido tool spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	if started := h.startCommand(fields[0]); !strings.Contains(started, "pi --session-id "+runID) {
		t.Errorf("resumed pane's command = %q, want a session minted under the run's own id", started)
	}
	if _, err := os.Stat(delivered); !os.IsNotExist(err) {
		t.Errorf("delivered marker %s still there (%v); the task must be delivered again", delivered, err)
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
		"%s tool spawn_subagent --parent-pid 1 --parent-session root-e2e --name %s "+
			"--task-file %s --model acme/claude-sonnet-5 --tools read,bash --keep-alive -- /bin/sh -c %s > %s 2>&1",
		kidoBin, name, h.writeTaskFile(name), shellQuote("exec sleep 300"), outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		h.t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", fields)
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
// come from the run's own record.
func TestSpawnResumeCarriesKeepAlive(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, sessDir := h.spawnRecordedRun("keepalive-carry-e2e")

	outFile := filepath.Join(h.dir, "resume.out")
	envFile := filepath.Join(h.dir, "resume.env")
	fake := shellQuote(fmt.Sprintf("env > %s; sleep 300", envFile))
	h.sendLiteral(fmt.Sprintf("PI_CODING_AGENT_SESSION_DIR=%s %s tool spawn_subagent --resume %s -- /bin/sh -c %s > %s 2>&1",
		shellQuote(sessDir), kidoBin, runID, fake, outFile))
	h.sendKeys("Enter")
	if out := strings.TrimSpace(h.waitFileNonEmpty(outFile)); len(strings.Fields(out)) != 3 {
		t.Fatalf("kido tool spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", out)
	}

	h.waitFileNonEmpty(envFile)
	if got := h.runMeta("resumed-keepalive", runID)["keepAlive"]; got != true {
		t.Errorf("resumed keepAlive = %v, want true from the run's own record", got)
	}
}

// A narrow toolset is a blast-radius bound the depth ceiling is not; a
// resume that quietly handed the full set back would widen it unasked.
// The model comes back the same way, unless the resume names its own.
//
// Both are spelled onto the command line only when the command is
// literally `pi`; whether that name resolves decides whether the pane
// lives long enough to set remain-on-exit (Tmux.Exec.new_window's
// race), so this test's own fake pi goes on this server's PATH alone.
// It answers --list-models too, which the carried model is checked by.
func TestSpawnResumeCarriesToolsOntoThePiCommandLine(t *testing.T) {
	t.Parallel()
	piDir := filepath.Join(t.TempDir(), "model-pi-bin")
	writeFakeListModelsPi(t, piDir)
	h := startPathPrefix(t, "alpha", piDir)

	runID, sessDir := h.spawnRecordedRun("tools-carry-e2e")
	delivered := filepath.Join(h.stateDir, "runs", runID, "delivered")
	if err := os.WriteFile(delivered, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	resume := func(tag string, command ...string) string {
		outFile := filepath.Join(h.dir, tag+".out")
		h.sendLiteral(fmt.Sprintf("PATH=%s:$PATH PI_CODING_AGENT_SESSION_DIR=%s %s tool spawn_subagent --resume %s -- %s > %s 2>&1",
			shellQuote(piDir), shellQuote(sessDir), kidoBin, runID, strings.Join(command, " "), outFile))
		h.sendKeys("Enter")
		fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
		if len(fields) != 3 {
			t.Fatalf("kido tool spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", fields)
		}
		return fields[0]
	}
	newWindowID := resume("resume", "pi")

	started := h.startCommand(newWindowID)
	for _, want := range []string{"--tools read,bash", "--model acme/claude-sonnet-5", "--session " + runID} {
		if !strings.Contains(started, want) {
			t.Errorf("resumed pane's command = %q, want %q: the run's own session, tools and model back", started, want)
		}
	}
	if _, err := os.Stat(delivered); err != nil {
		t.Errorf("delivered marker: %v; resuming a session pi still has must not deliver the task again", err)
	}

	h.killPane(h.in("list-panes", "-t", newWindowID, "-F", "#{pane_id}"))
	h.waitFor(func() bool { return !h.windowExists(newWindowID) }, settle,
		msgf("the sweep to close window %s", newWindowID))
	started = h.startCommand(resume("override", "pi", "--model", "acme/claude-opus-5"))
	if !strings.Contains(started, "--model acme/claude-opus-5") || strings.Contains(started, "claude-sonnet-5") {
		t.Errorf("resumed pane's command = %q, want the model the resume named and not the recorded one", started)
	}
}

// The real agent extension's timer uses the real lookup against a spawned run.
// A gated settle makes the metadata edit happen before any idle check.
func TestSpawnKeepAliveChangesAtIdleExit(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not installed")
	}
	version, err := exec.Command(node, "-e", "process.exit(Number(process.versions.node.split('.')[0]) >= 24 ? 0 : 1)").CombinedOutput()
	if err != nil {
		t.Skipf("need node >=24: %s", version)
	}
	extension, err := filepath.Abs("../share/pi/kido-agents.ts")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(extension), "node_modules")); err != nil {
		t.Skip("pi extension dependencies not installed")
	}
	for _, initial := range []bool{false, true} {
		t.Run(fmt.Sprint(initial), func(t *testing.T) {
			h := start(t, "alpha")
			h.liveParent("alpha", "dynamic-parent")
			gate := filepath.Join(h.dir, "settle")
			log := filepath.Join(h.dir, "checks")
			script := filepath.Join(h.dir, "child.mjs")
			source := fmt.Sprintf(`import agents from %q;
import { execFileSync } from 'node:child_process';
import { existsSync, appendFileSync } from 'node:fs';
const handlers = new Map();
const run = process.env.KIDO_AGENT_RUN_ID;
globalThis.__kidoPiExtensionSeam = { host: {
 sessionId: () => run,
 runKido: async (args) => {
  const out = execFileSync(%q, args, { encoding: 'utf8', timeout: 2000 });
  if (args.includes('--children')) appendFileSync(%q, out);
  return { ok: true, out };
 }
}, agents: null };
agents({ on: (name, fn) => handlers.set(name, fn), registerTool() {}, registerMessageRenderer() {} });
globalThis.__kidoPiExtensionSeam.agents.sessionStarting({
 shutdown: () => { appendFileSync(%q, 'shutdown'); process.exit(0); },
 isIdle: () => true
});
const wait = setInterval(async () => {
 if (!existsSync(%q)) return;
 clearInterval(wait);
 await handlers.get('agent_settled')({}, { isIdle: () => true });
}, 20);
setTimeout(() => process.exit(2), 15000);
`, extension, kidoBin, log, log, gate)
			if err := os.WriteFile(script, []byte(source), 0o644); err != nil {
				t.Fatal(err)
			}
			args := []string{"tool", "spawn_subagent", "--parent-pid", "1", "--parent-session", "dynamic-parent", "--name", "dynamic-keepalive", "--task-file", h.writeTaskFile("wait")}
			if initial {
				args = append(args, "--keep-alive")
			}
			h.in("set-environment", "-g", "KIDO_IDLE_EXIT_SECONDS", "0.2")
			args = append(args, "--", node, script)
			// runKido assembles shell arguments; quote the absolute file paths.
			for i := range args {
				args[i] = shellQuote(args[i])
			}
			fields := strings.Fields(firstLine(h.runKido("alpha", "dynamic-spawn.out", args...)))
			if len(fields) != 3 {
				t.Fatalf("spawn = %q", fields)
			}
			window, pane, runID := fields[0], fields[1], fields[2]
			flip := func(keep bool) {
				path := filepath.Join(h.stateDir, "runs", runID, "meta.json")
				data, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				var meta map[string]any
				if err := json.Unmarshal(data, &meta); err != nil {
					t.Fatal(err)
				}
				meta["keepAlive"] = keep
				data, err = json.Marshal(meta)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path+".edit", data, 0o600); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(path+".edit", path); err != nil {
					t.Fatal(err)
				}
			}
			if !initial {
				flip(true)
			}
			if err := os.WriteFile(gate, nil, 0o644); err != nil {
				t.Fatal(err)
			}
			h.waitFor(func() bool {
				data, _ := os.ReadFile(log)
				return strings.Count(string(data), "\n") >= 2
			}, 4*time.Second, msgf("kept-alive child to re-arm the idle-exit check"))
			if !h.windowExists(window) || h.in("display-message", "-p", "-t", pane, "#{pane_dead}") == "1" {
				t.Fatal("kept-alive child exited")
			}
			metaPath := filepath.Join(h.stateDir, "runs", runID, "meta.json")
			meta, err := os.ReadFile(metaPath)
			if err != nil {
				t.Fatal(err)
			}
			checks, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(metaPath, []byte("{"), 0o600); err != nil {
				t.Fatal(err)
			}
			h.waitFor(func() bool {
				data, _ := os.ReadFile(log)
				return strings.Count(string(data), "\n") >= strings.Count(string(checks), "\n")+3
			}, 4*time.Second, msgf("child to re-arm while its metadata is invalid JSON"))
			if !h.windowExists(window) || h.in("display-message", "-p", "-t", pane, "#{pane_dead}") == "1" {
				t.Fatal("child exited while its metadata was unreadable")
			}
			if err := os.WriteFile(metaPath, meta, 0o600); err != nil {
				t.Fatal(err)
			}
			flip(false)
			h.waitFor(func() bool {
				data, _ := os.ReadFile(log)
				return strings.Contains(string(data), "shutdown")
			}, settle, msgf("idle timer to shut down after keepAlive is disabled"))
			h.waitFor(func() bool {
				return !h.windowExists(window) || h.in("display-message", "-p", "-t", pane, "#{pane_dead}") == "1"
			}, settle, msgf("child to exit after keepAlive is disabled"))
		})
	}
}
