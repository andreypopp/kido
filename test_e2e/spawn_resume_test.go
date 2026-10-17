package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
	// A tag keeps the second call below from reading this call's leftover
	// output file before it is overwritten.
	if got := h.runOutcome(runID, "before"); got != "died" {
		t.Fatalf("run %s outcome = %q, want %q before resuming", runID, got, "died")
	}
	before := h.runMeta("before", runID)
	if screen, _ := before["screen"].(string); !strings.Contains(screen, "resume-screen-e2e") {
		t.Fatalf("run %s screen = %q, want the sweep's capture of the first attempt", runID, screen)
	}
	newParentPane := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.programStatus(newParentPane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", newParentPane, "#{pane_title}"), "π - "))
	h.agentStatus("new-parent-e2e", newParentPane)

	h.savedSession(runID)

	// Typed from another directory, under another parent: a resume keeps
	// the run's own cwd, since pi sessions are project-scoped.
	outFile := filepath.Join(h.dir, "resume.out")
	envFile := filepath.Join(h.dir, "resume.env")
	fake := shellQuote(fmt.Sprintf("env > %s; pwd >> %s; sleep 300", envFile, envFile))
	cmd := fmt.Sprintf("cd / && PI_SESSION_ID=new-parent-e2e %s tool spawn_subagent --resume %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, runID, fake, outFile)
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
	if after["startedAt"] != before["startedAt"] || fmt.Sprint(after["parent"]) != "new-parent-e2e" {
		t.Errorf("resumed meta startedAt=%v parent=%v, want startedAt %v kept and the new parent",
			after["startedAt"], after["parent"], before["startedAt"])
	}

	mark := h.in("show-options", "-p", "-v", "-t", newPaneID, "@kido_run")
	if mark != runID {
		t.Errorf("@kido_run on the resumed pane = %q, want it to name run %s", mark, runID)
	}

	if got := h.runOutcome(runID, "after"); got != "running" {
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
PI_SESSION_ID="$KIDO_AGENT_RUN_ID" %s agent-status
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
	out := h.runScript("alpha", "first-life.out", "PI_SESSION_ID=resume-parent-e2e "+kidoBin+
		" tool spawn_subagent --name resumable --task-file "+h.writeTaskFile("resumable")+" -- "+fake)
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
	if got := h.runOutcome(runID, "first-life"); got != "completed" {
		t.Fatalf("first life outcome = %q, want completed", got)
	}
	if len(in.Received()) != 1 || !strings.Contains(in.Received()[0], "finished first life") {
		t.Fatalf("first life notices = %q", in.Received())
	}
	out = h.runScript("alpha", "second-life.out", "PI_SESSION_ID=resume-parent-e2e "+kidoBin+
		" tool spawn_subagent --resume "+runID+" -- /bin/sh -c "+shellQuote("exec sleep 300"))
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
	if got := h.runOutcome(runID, "second-life"); got != "running" {
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

// A run whose window is still up (never swept, no outcome) must not be
// resumed out from under itself.
func TestSpawnResumeRefusesLiveRun(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("live-src", "exec sleep 300")
	t.Cleanup(func() { h.in("kill-window", "-t", windowID) })
	// The manual ending below speaks for an unreported child, so its parent
	// must have an inbox for that notice to arrive at.
	h.agentStatus("root-e2e", h.firstPane("alpha"), "--inbox", startInbox(t, "ok\n").Path)

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
	// A pi kido did not start records no pid in its meta, so only its kind refuses it.
	h.agentStatus("top-e2e", h.firstPane("alpha"))
	if out, rc := h.kidoAs(h.firstPane("alpha"), "", nil, "tool", "spawn_subagent", "--resume", "top-e2e"); rc != 1 || !strings.Contains(out, "not a subagent run") {
		t.Errorf("resume a top-level pi's run: got (rc=%d) %q, want rc=1 and not a subagent run", rc, out)
	}
}

// resumeRun ends a run's current attempt and resumes it with a fake
// command that dumps its environment, returning that environment and the
// new attempt's window.
func (h *harness) resumeRun(tag, runID, windowID string, flags ...string) (env, newWindowID string) {
	h.t.Helper()
	h.killPane(h.in("list-panes", "-t", windowID, "-F", "#{pane_id}"))
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sweep to close window %s", windowID))
	outFile := filepath.Join(h.dir, tag+".out")
	envFile := filepath.Join(h.dir, tag+".env")
	fake := shellQuote(fmt.Sprintf("env > %s; sleep 300", envFile))
	h.sendLiteral(fmt.Sprintf("%s %s tool spawn_subagent --resume %s %s -- /bin/sh -c %s > %s 2>&1",
		h.callerShell(""), kidoBin, runID, strings.Join(flags, " "), fake, outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		h.t.Fatalf("kido tool spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	return h.waitFileNonEmpty(envFile), fields[0]
}

// With no parent flags a resume's child is the caller's own, by the
// caller's record, and --no-parent drops even that.
func TestSpawnResumeParentIsTheCallersOrNobody(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("edge-src", "exec sleep 300")
	h.savedSession(runID)

	env, windowID := h.resumeRun("defaulted", runID, windowID)
	for k, want := range map[string]string{"KIDO_AGENT_PARENT_SESSION": "root-e2e"} {
		if got := envLine(env, k); got != want {
			t.Errorf("resumed child's %s = %q, want %q", k, got, want)
		}
	}

	env, _ = h.resumeRun("handed-over", runID, windowID, "--no-parent")
	for _, k := range []string{"KIDO_AGENT_PARENT_SESSION"} {
		if got := envLine(env, k); got != "" {
			t.Errorf("child resumed with --no-parent has %s = %q, want it unset", k, got)
		}
	}
	if got := h.runMeta("handed-over", runID)["parent"]; got != nil {
		t.Errorf("run meta parent = %v after --no-parent, want no parent", got)
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
	h.sendLiteral(fmt.Sprintf("%s tool spawn_subagent --resume %s > %s 2>&1", kidoBin, runID, outFile))
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
// spawned with a tool allowlist and a model, then ended so it can be
// resumed from its saved pi session.
func (h *harness) spawnRecordedRun(name string) (runID string) {
	h.t.Helper()
	h.liveParent("alpha", "root-e2e")
	outFile := filepath.Join(h.dir, name+"-spawn.out")
	h.sendLiteral(fmt.Sprintf(
		"PI_SESSION_ID=root-e2e %s tool spawn_subagent --name %s "+
			"--task-file %s --model acme/claude-sonnet-5 --tools read,bash -- /bin/sh -c %s > %s 2>&1",
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

	h.savedSession(runID)
	return runID
}

// A narrow toolset is a blast-radius bound the depth ceiling is not; a
// resume that quietly handed the full set back would widen it unasked.
// The model comes back the same way, unless the resume names its own.
//
// Both are spelled onto the command line only when the command is
// literally `pi`, so this test's own fake pi goes on this server's PATH alone.
// It answers --list-models too, which the carried model is checked by.
func TestSpawnResumeCarriesToolsOntoThePiCommandLine(t *testing.T) {
	t.Parallel()
	piDir := filepath.Join(t.TempDir(), "model-pi-bin")
	writeFakeListModelsPi(t, piDir)
	h := startPathPrefix(t, "alpha", piDir)

	runID := h.spawnRecordedRun("tools-carry-e2e")
	delivered := filepath.Join(h.stateDir, "runs", runID, "delivered")
	if err := os.WriteFile(delivered, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	resume := func(tag, tools string, command ...string) string {
		outFile := filepath.Join(h.dir, tag+".out")
		h.sendLiteral(fmt.Sprintf("PATH=%s:$PATH PI_SESSION_ID=root-e2e %s tool spawn_subagent --resume %s %s -- %s > %s 2>&1",
			shellQuote(piDir), kidoBin, runID, tools, strings.Join(command, " "), outFile))
		h.sendKeys("Enter")
		fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
		if len(fields) != 3 {
			t.Fatalf("kido tool spawn_subagent --resume printed %q, want \"<window id> <pane id> <run id>\"", fields)
		}
		return fields[0]
	}
	newWindowID := resume("resume", "", "pi")

	started := h.startCommand(newWindowID)
	for _, want := range []string{"--tools read,bash,notify_parent", "--model acme/claude-sonnet-5", "--session ", runID + ".jsonl"} {
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
	started = h.startCommand(resume("override", "--tools read", "pi", "--model", "acme/claude-opus-5"))
	if !strings.HasSuffix(started, "--tools read,notify_parent") {
		t.Errorf("resumed pane's command = %q, want notify_parent in the tools override", started)
	}
	if !strings.Contains(started, "--model acme/claude-opus-5") || strings.Contains(started, "claude-sonnet-5") {
		t.Errorf("resumed pane's command = %q, want the model the resume named and not the recorded one", started)
	}
}

// firstLine strips runKido's own trailing "rc=N" line.
func firstLine(s string) string {
	return strings.SplitN(strings.TrimSpace(s), "\n", 2)[0]
}
