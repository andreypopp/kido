package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// runSpawn types a shell command line into the client's active pane (the
// session's plain shell, exactly as runPrompt does for kido prompt) that
// runs `kido spawn_subagent` with the given extra args and a fake command, so
// KIDO_AGENT_* and the new window's cwd can be checked by reading a file
// the fake command writes on start rather than by talking to a
// TypeScript pi extension the e2e suite cannot host. Its own stdout
// (the new window and pane ids) goes to outFile.
//
// The fake command is /bin/sh -c "env > envFile; pwd >> envFile; sleep
// 300": env dumps every KIDO_AGENT_* variable new-window's -e flags set,
// and pwd after it proves -c put the child in the caller's own directory,
// not the session default.
func (h *harness) runSpawn(outFile, envFile string, args ...string) {
	h.t.Helper()
	fake := shellQuote(fmt.Sprintf("env > %s; pwd >> %s; sleep 300", envFile, envFile))
	cmd := fmt.Sprintf("%s spawn_subagent %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, strings.Join(args, " "), fake, outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
}

// waitFileNonEmpty waits until path exists and has at least one byte,
// then returns its contents.
func (h *harness) waitFileNonEmpty(path string) string {
	h.t.Helper()
	var content []byte
	h.waitFor(func() bool {
		b, err := os.ReadFile(path)
		if err != nil || len(b) == 0 {
			return false
		}
		content = b
		return true
	}, settle, msgf("%s to be written", path))
	return string(content)
}

// envLine returns the value of KEY=... in envOutput (the output of the
// `env` command), or "" if absent.
func envLine(envOutput, key string) string {
	prefix := key + "="
	for _, line := range strings.Split(envOutput, "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

// TestSpawnCreatesWindowInCallerSession drives `kido spawn_subagent` the way
// spawn_subagent (pi/kido-agents.ts) does, with a fake command standing in
// for pi, and checks everything that only exists because `kido spawn_subagent` is
// a testable command in its own right (docs/design.md, "Spawning"): the
// new window lands in the
// caller's own session, keeps the caller's own turn (-d), starts in the
// caller's own directory (-c), is named as asked, and the spawned process
// actually sees the KIDO_AGENT_* variables in its environment (-e) - not
// merely that kido spawn_subagent believes it passed them.
func TestSpawnCreatesWindowInCallerSession(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	taskFile := filepath.Join(h.dir, "task.txt")
	if err := os.WriteFile(taskFile, []byte("do the thing"), 0o644); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(h.dir, "spawn.out")
	envFile := filepath.Join(h.dir, "child.env")

	activeBefore := h.activeWindowID("alpha")

	h.liveParent("alpha", "parent-xyz")
	h.runSpawn(outFile, envFile,
		"--parent-pid", "424242",
		"--parent-instance", "parent-xyz",
		"--depth", "1",
		"--name", "kid-e2e",
		"--task-file", taskFile,
	)

	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		t.Fatalf("kido spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	windowID, paneID, runID := fields[0], fields[1], fields[2]

	if got := h.in("display-message", "-p", "-t", paneID, "#{session_name}"); got != "alpha" {
		t.Errorf("spawned pane's session = %q, want %q", got, "alpha")
	}
	if got := h.in("display-message", "-p", "-t", windowID, "#{window_name}"); got != "kid-e2e" {
		t.Errorf("spawned window's name = %q, want %q", got, "kid-e2e")
	}

	// -d: the caller's own client is not yanked to the new window.
	if got := h.activeWindowID("alpha"); got != activeBefore {
		t.Errorf("active window changed from %s to %s; kido spawn_subagent must pass -d", activeBefore, got)
	}

	env := h.waitFileNonEmpty(envFile)
	lines := strings.Split(strings.TrimRight(env, "\n"), "\n")
	cwd := lines[len(lines)-1]
	// EvalSymlinks: on macOS t.TempDir() lives under /var, a symlink to
	// /private/var that a real shell's pwd resolves away.
	wantCwd, err := filepath.EvalSymlinks(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	if cwd != wantCwd {
		t.Errorf("spawned process's cwd = %q, want %q (the caller's own, via -c)", cwd, wantCwd)
	}
	for k, want := range map[string]string{
		"KIDO_AGENT_PARENT_PID":      "424242",
		"KIDO_AGENT_PARENT_INSTANCE": "parent-xyz",
		"KIDO_AGENT_DEPTH":           "1",
	} {
		if got := envLine(env, k); got != want {
			t.Errorf("spawned process's %s = %q, want %q (kido spawn_subagent's -e must reach it, not just the caller's own environment)", k, got, want)
		}
	}

	// The task lives in the run's own directory: KIDO_AGENT_TASK_FILE does
	// not name the caller's --task-file, and its content is the task, not
	// the caller's file's path.
	relocated := envLine(env, "KIDO_AGENT_TASK_FILE")
	if relocated == "" || relocated == taskFile {
		t.Errorf("KIDO_AGENT_TASK_FILE = %q, want it relocated into run %s's own directory", relocated, runID)
	}
	got, err := os.ReadFile(relocated)
	if err != nil || string(got) != "do the thing" {
		t.Errorf("relocated task file contents = %q, %v, want %q, nil", got, err, "do the thing")
	}
}

// activeWindowID returns the window id of session's currently active
// window.
func (h *harness) activeWindowID(session string) string {
	h.t.Helper()
	for _, line := range strings.Split(h.in("list-windows", "-t", session, "-F", "#{window_active} #{window_id}"), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && f[0] == "1" {
			return f[1]
		}
	}
	h.t.Fatalf("no active window found in session %s", session)
	return ""
}

// TestSpawnRefusesDepthBeyondCeiling checks that a caller already at
// decision 5's ceiling (root 0, subagent 1, subagent 2) is refused, from
// inside a real tmux server rather than the fake-newWindow unit test
// (TestSpawnRefusedAtMaxDepth). The caller's depth is recorded first with
// a real `kido agent-status` call, exactly as pi's own status reporting
// would - kido spawn_subagent derives the child's depth from that record, not from
// --depth, so this also stands in for "a
// caller at the ceiling cannot escape by passing a smaller --depth": the
// spawn below claims --depth 1, which would be allowed if trusted.
func TestSpawnRefusesDepthBeyondCeiling(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	before := len(strings.Split(h.in("list-windows", "-t", "alpha", "-F", "#{window_id}"), "\n"))

	outFile := filepath.Join(h.dir, "spawn.out")
	taskFile := filepath.Join(h.dir, "task.txt")
	if err := os.WriteFile(taskFile, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := fmt.Sprintf(
		"%s agent-status --agent pi --session caller-e2e --status idle --depth %d && "+
			"%s spawn_subagent --parent-pid 1 --parent-instance p --depth 1 --name kid --task-file %s > %s 2>&1; echo rc=$? >> %s",
		kidoBin, maxDepthForTest, kidoBin, taskFile, outFile, outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")

	out := h.waitFileNonEmpty(outFile)
	if !strings.Contains(out, "maximum nesting") {
		t.Errorf("kido spawn_subagent output = %q, want a refusal naming the depth ceiling", out)
	}
	if !strings.Contains(out, "rc=1") {
		t.Errorf("kido spawn_subagent output = %q, want a non-zero exit", out)
	}

	after := len(strings.Split(h.in("list-windows", "-t", "alpha", "-F", "#{window_id}"), "\n"))
	if after != before {
		t.Errorf("window count changed from %d to %d; a refused spawn must create nothing", before, after)
	}
}

// maxDepthForTest mirrors cmd/kido/spawn.go's maxDepth; kept independent
// so the e2e binary (built fresh by `go build`, not linked against the
// cmd/kido package) does not need an import for one constant.
const maxDepthForTest = 2

// TestSpawnNoParentIsNotReaped is the parentless spawn end to end, which
// is the only way to see the claim the flag actually makes: the unit test
// hands reap.Sweep a fixture, while here a real sidebar sweeps every
// 100ms with the harness's one-second linger, and `kido reap` is run on
// top of it for the one-shot path. A human at a shell has no agent
// identity to hand over, and before --no-parent there was no way through
// this command at all - naming a real agent makes the child that agent's,
// and inventing one leaves an orphan the sweep closes within seconds.
//
// The child reports itself the way the absence of
// KIDO_AGENT_PARENT_INSTANCE leaves it: a live subagent record naming no
// parent. That is the record rule 2 reads, and its first clause is what
// exempts it.
func TestSpawnNoParentIsNotReaped(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	taskFile := filepath.Join(h.dir, "task.txt")
	if err := os.WriteFile(taskFile, []byte("stand alone"), 0o644); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(h.dir, "spawn.out")
	envFile := filepath.Join(h.dir, "child.env")

	h.runSpawn(outFile, envFile, "--no-parent", "--name", "loner-e2e", "--task-file", taskFile)

	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		t.Fatalf("kido spawn_subagent --no-parent printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	windowID, paneID := fields[0], fields[1]

	env := h.waitFileNonEmpty(envFile)
	for _, k := range []string{"KIDO_AGENT_PARENT_PID", "KIDO_AGENT_PARENT_INSTANCE"} {
		if got := envLine(env, k); got != "" {
			t.Errorf("spawned process's %s = %q, want it unset: the child is owned by nobody", k, got)
		}
	}

	h.agentStatus("loner-e2e", paneID, "pi", "idle", "--instance", "loner-e2e-inst")
	if out := h.runKido("alpha", "reap.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Errorf("kido reap output = %q, want a clean exit", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"a child spawned with --no-parent was closed as an orphan; an empty parent edge is exempt from rule 2")
}

// TestSpawnFabricatedParentIsRefusedUpFront is the other half of the pair
// above, and what makes rule 2's exemption a decision rather than an
// accident: the same record-less shell, the same command, one flag
// different. `--no-parent` makes a window the sweep declines to touch; an
// invented `--parent-instance` makes no window at all, because the child
// it would create is one the sweep collects within seconds - and the read
// that would explain that runs in another process, after this command has
// already exited successfully, so there was never going to be an error
// for anyone to see. Refusing before the window exists is what turns that
// silent, delayed close into something the caller is told about.
func TestSpawnFabricatedParentIsRefusedUpFront(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	out := h.runKido("alpha", "fabricated.out", "spawn_subagent",
		"--parent-pid", "1", // init, so the pid itself is alive and cannot be what refuses
		"--parent-instance", "nobody-is-this",
		"--name", "orphan-e2e", "--task-file", h.writeTaskFile("orphan-e2e"))

	if !strings.Contains(out, "rc=1") {
		t.Errorf("kido spawn_subagent with a fabricated parent = %q, want rc=1", out)
	}
	if !strings.Contains(out, "nobody-is-this") || !strings.Contains(out, "--no-parent") {
		t.Errorf("output = %q, want it to name the instance and point at --no-parent", out)
	}
	if got := h.in("list-windows", "-a", "-F", "#{window_name}"); strings.Contains(got, "orphan-e2e") {
		t.Errorf("windows = %q, want no window created for a refused spawn", got)
	}
}
