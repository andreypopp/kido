package e2e

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// runSpawn runs `kido tool spawn_subagent` with a fake command, so KIDO_AGENT_*
// and the new window's cwd can be checked by reading a file the fake
// command writes on start rather than talking to a TypeScript pi
// extension the e2e suite cannot host. Its own stdout (window and pane
// ids) goes to outFile; the fake's env dumps every KIDO_AGENT_* variable
// and pwd proves -c put the child in the caller's own directory.
func (h *harness) runSpawn(outFile, envFile string, args ...string) {
	h.t.Helper()
	fake := shellQuote(fmt.Sprintf("env > %s; pwd >> %s; sleep 300", envFile, envFile))
	cmd := fmt.Sprintf("%s tool spawn_subagent %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, strings.Join(args, " "), fake, outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
}

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

func envLine(envOutput, key string) string {
	prefix := key + "="
	for _, line := range strings.Split(envOutput, "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

// The new window lands in the caller's own session, keeps the caller's
// own turn (-d), starts in the caller's own directory (-c), is named as
// asked, and the spawned process actually sees KIDO_AGENT_* in its
// environment (-e) - not merely that kido tool spawn_subagent believes it
// passed them.
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
		"--parent-session", "parent-xyz",
		"--name", "kid-e2e",
		"--task-file", taskFile,
	)

	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", out)
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
		t.Errorf("active window changed from %s to %s; kido tool spawn_subagent must pass -d", activeBefore, got)
	}

	env := h.waitFileNonEmpty(envFile)
	lines := strings.Split(strings.TrimRight(env, "\n"), "\n")
	cwd := lines[len(lines)-1]
	// On macOS t.TempDir() lives under /var, a symlink to /private/var
	// that a real shell's pwd resolves away.
	wantCwd, err := filepath.EvalSymlinks(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	if cwd != wantCwd {
		t.Errorf("spawned process's cwd = %q, want %q (the caller's own, via -c)", cwd, wantCwd)
	}
	for k, want := range map[string]string{
		"KIDO_AGENT_PARENT_PID":     "424242",
		"KIDO_AGENT_PARENT_SESSION": "parent-xyz",
		"KIDO_AGENT_DEPTH":          "1",
	} {
		if got := envLine(env, k); got != want {
			t.Errorf("spawned process's %s = %q, want %q (kido tool spawn_subagent's -e must reach it, not just the caller's own environment)", k, got, want)
		}
	}

	// The task lives in the run's own directory: KIDO_AGENT_TASK_FILE does
	// not name the caller's --task-file.
	relocated := envLine(env, "KIDO_AGENT_TASK_FILE")
	if relocated == "" || relocated == taskFile {
		t.Errorf("KIDO_AGENT_TASK_FILE = %q, want it relocated into run %s's own directory", relocated, runID)
	}
	got, err := os.ReadFile(relocated)
	if err != nil || string(got) != "do the thing" {
		t.Errorf("relocated task file contents = %q, %v, want %q, nil", got, err, "do the thing")
	}

	// The mark is what makes the window reapable, and the meta is what
	// `kido runs` and a later resume read back.
	if mark := h.in("show-options", "-p", "-v", "-t", paneID, "@kido_run"); mark != runID {
		t.Errorf("@kido_run on the spawned pane = %q, want run %s", mark, runID)
	}
	meta := h.runMeta("created", runID)
	metaCwd, _ := meta["cwd"].(string)
	if resolved, err := filepath.EvalSymlinks(metaCwd); err != nil || resolved != wantCwd {
		t.Errorf("run meta cwd = %q, want the caller's own %q", metaCwd, wantCwd)
	}
	for k, want := range map[string]any{"name": "kid-e2e", "parentSession": "parent-xyz", "depth": 1.0, "pane": paneID} {
		if meta[k] != want {
			t.Errorf("run meta %s = %v, want %v", k, meta[k], want)
		}
	}
}

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

// A caller already at the depth ceiling (root 0, subagent 1, subagent 2)
// is refused. The caller's depth is recorded first with a real
// `kido agent-status` call, as pi's own identity reporting would.
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
		"%s agent-status --agent pi --session caller-e2e --depth %d && "+
			"%s tool spawn_subagent --parent-pid 1 --parent-session p --name kid --task-file %s > %s 2>&1; echo rc=$? >> %s",
		kidoBin, maxDepthForTest, kidoBin, taskFile, outFile, outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")

	out := h.waitFileContains(outFile, "rc=")
	if !strings.Contains(out, "maximum nesting") {
		t.Errorf("kido tool spawn_subagent output = %q, want a refusal naming the depth ceiling", out)
	}
	if !strings.Contains(out, "rc=1") {
		t.Errorf("kido tool spawn_subagent output = %q, want a non-zero exit", out)
	}

	after := len(strings.Split(h.in("list-windows", "-t", "alpha", "-F", "#{window_id}"), "\n"))
	if after != before {
		t.Errorf("window count changed from %d to %d; a refused spawn must create nothing", before, after)
	}
}

// maxDepthForTest mirrors Spawn_subagent.max_depth; kept independent
// since the e2e binary is not linked against kido's OCaml library.
const maxDepthForTest = 2

// The positive half of the ceiling test above: a caller one below the
// ceiling still spawns, and its own record, not the parent it names, sets
// the child's depth.
func TestSpawnNestsOneBelowItsCallersOwnRecord(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("caller-e2e", pane, "pi", "--depth", strconv.Itoa(maxDepthForTest-1))
	outFile := filepath.Join(h.dir, "spawn.out")
	envFile := filepath.Join(h.dir, "child.env")
	h.runSpawn(outFile, envFile, "--parent-pid", "1", "--parent-session", "caller-e2e",
		"--name", "deep-e2e", "--task-file", h.writeTaskFile("deep-e2e"))

	if out := strings.TrimSpace(h.waitFileNonEmpty(outFile)); len(strings.Fields(out)) != 3 {
		t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	if got := envLine(h.waitFileNonEmpty(envFile), "KIDO_AGENT_DEPTH"); got != strconv.Itoa(maxDepthForTest) {
		t.Errorf("KIDO_AGENT_DEPTH = %q, want %d: one below the caller's own recorded depth", got, maxDepthForTest)
	}
}

// maxPromptBytes reads MAX_PROMPT_BYTES from share/pi/kido-status.ts: the
// extension delivers a session's first message under that cap, so kido's
// task cap must be the same number, not a copy of it.
func maxPromptBytes(t *testing.T) int {
	t.Helper()
	ts, err := os.ReadFile("../share/pi/kido-status.ts")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^const MAX_PROMPT_BYTES = ([0-9 *]+);$`).FindSubmatch(ts)
	if m == nil {
		t.Fatal("share/pi/kido-status.ts has no `const MAX_PROMPT_BYTES = <n> * <n>;` line")
	}
	n := 1
	for _, f := range strings.Split(string(m[1]), "*") {
		v, err := strconv.Atoi(strings.TrimSpace(f))
		if err != nil {
			t.Fatal(err)
		}
		n *= v
	}
	return n
}

// Refusals made from the flags and the task file alone: each comes before
// kido asks tmux anything, so none needs a server, and the first stderr
// line is the whole contract (a flag refusal appends the usage after it).
func TestSpawnRefusesBeforeAskingTmux(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	task := filepath.Join(dir, "task.txt")
	if err := os.WriteFile(task, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	limit := maxPromptBytes(t)
	big := filepath.Join(dir, "big.txt")
	if err := os.WriteFile(big, bytes.Repeat([]byte("x"), limit+1), 0o644); err != nil {
		t.Fatal(err)
	}
	parent := []string{"--parent-pid", "1", "--parent-session", "p"}
	fresh := func(extra ...string) []string {
		return append(append([]string{"tool", "spawn_subagent", "--name", "kid", "--task-file", task}, parent...), extra...)
	}
	named := func(name string) []string {
		return append([]string{"tool", "spawn_subagent", "--name", name, "--task-file", task}, parent...)
	}
	tasked := func(file string) []string {
		return append([]string{"tool", "spawn_subagent", "--name", "kid", "--task-file", file}, parent...)
	}
	const tmuxWords = ", which cannot survive tmux's own command-line parsing"
	for _, c := range []struct {
		args []string
		line string
	}{
		{named(`kid"s`), `refusing window name "kid\"s": it contains "\""` + tmuxWords},
		{named("kid$x"), `refusing window name "kid$x": it contains "$"` + tmuxWords},
		{named("kid#x"), `refusing window name "kid#x": it contains "#"` + tmuxWords},
		{named("kid`x"), "refusing window name \"kid`x\": it contains \"`\"" + tmuxWords},
		{named(`kid\x`), `refusing window name "kid\\x": it contains "\\"` + tmuxWords},
		{named("kid'x"), `refusing window name "kid'x": it contains "'"` + tmuxWords},
		{named("kid\nx"), `refusing window name "kid\nx": it contains "\n"` + tmuxWords},
		{named("kid\rx"), `refusing window name "kid\rx": it contains "\r"` + tmuxWords},
		{named(strings.Repeat("x", 65)), `refusing window name "` + strings.Repeat("x", 65) + `": 65 bytes is over the 64 byte limit`},
		{tasked("/nonexistent/task.txt"), `--task-file "/nonexistent/task.txt": No such file or directory`},
		{tasked(dir), fmt.Sprintf("--task-file %q is a directory, not a task file", dir)},
		{tasked(big), fmt.Sprintf("--task-file %q is %d bytes, over the %d byte task limit", big, limit+1, limit)},
		{fresh("--fork", "sess$(id)"), `refusing --fork "sess$(id)": it contains "$"` + tmuxWords},
		{fresh("--no-parent"), "--no-parent contradicts --parent-pid/--parent-session; pass one or the other"},
		{[]string{"tool", "spawn_subagent", "--parent-pid", "1", "--name", "kid", "--task-file", task},
			"--parent-pid and --parent-session name one parent and are given together"},
		{[]string{"tool", "spawn_subagent", "--name", "kid", "--task-file", task},
			"--parent-pid and --parent-session are required (or --no-parent for a child owned by nobody)"},
		{[]string{"tool", "spawn_subagent", "--resume", "run-1", "--fork", "sess-1"},
			"--resume continues a run's own session; --fork starts a new one from somebody else's, and the two cannot both be asked for"},
		{[]string{"tool", "spawn_subagent", "--resume", "run-1", "--name", "kid"},
			"--resume keeps the run's original window name; --name is refused alongside it"},
		{[]string{"tool", "spawn_subagent", "--resume", "run-1", "--task-file", task},
			"--resume keeps the run's original task; --task-file is refused alongside it"},
		{[]string{"tool", "spawn_subagent", "--resume", "run-1", "--parent-pid", "1"},
			"--parent-pid and --parent-session name one parent and are given together"},
		{[]string{"tool", "async_bash", "--"}, "no command given"},
		{[]string{"tool", "async_bash", "--name", "kid$x", "--", "true"}, `refusing window name "kid$x": it contains "$"` + tmuxWords},
	} {
		cmd := exec.Command(kidoBin, c.args...)
		cmd.Env = cleanEnv("KIDO_STATE_DIR="+filepath.Join(dir, "state"), "TMUX_PANE=%1", "TMUX=")
		var stderr strings.Builder
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		code := 0
		if exit := (*exec.ExitError)(nil); errors.As(err, &exit) {
			code = exit.ExitCode()
		} else if err != nil {
			t.Fatalf("kido %q: %v", c.args, err)
		}
		want := "kido " + strings.Join(c.args[:2], " ") + ": " + c.line
		if got := strings.SplitN(stderr.String(), "\n", 2)[0]; got != want || code != 1 || len(out) != 0 {
			t.Errorf("kido %q: exit %d, stderr %q, stdout %q; want exit 1, stderr starting %q", c.args, code, stderr.String(), out, want)
		}
	}
	if entries, _ := os.ReadDir(filepath.Join(dir, "state", "runs")); len(entries) != 0 {
		t.Errorf("refused spawns left %d run directories behind", len(entries))
	}
}

// The other half of the cap: a task of exactly MAX_PROMPT_BYTES is
// taken, under a window name with a space in it, which tmux carries.
func TestSpawnTakesATaskAtTheCap(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	task := filepath.Join(h.dir, "cap.txt")
	if err := os.WriteFile(task, bytes.Repeat([]byte("x"), maxPromptBytes(t)), 0o644); err != nil {
		t.Fatal(err)
	}
	h.liveParent("alpha", "p")
	outFile := filepath.Join(h.dir, "spawn.out")
	h.runSpawn(outFile, filepath.Join(h.dir, "child.env"), "--parent-pid", "1", "--parent-session", "p",
		"--name", shellQuote("kid one"), "--task-file", task)
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	if got := h.in("display-message", "-p", "-t", fields[0], "#{window_name}"); got != "kid one" {
		t.Errorf("window name = %q, want %q", got, "kid one")
	}
}

// A window gone before kido could mark it (here a hook kills every new
// window the moment it exists) leaves nothing that will ever report an
// agent run, so that run fails and the spawn says so. A bash run's own
// wrapper records and reports its ending, so for it the same loss is the
// ordinary ending it is: the negative control, same hook, one kind apart.
func TestSpawnWhoseWindowIsGoneBeforeItsMark(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.liveParent("alpha", "p")

	h.in("set-hook", "-t", "alpha", "after-new-window", "kill-window")
	agentOut := filepath.Join(h.dir, "agent.out")
	h.sendLiteral(fmt.Sprintf("%s tool spawn_subagent --parent-pid 1 --parent-session p --name gone-e2e --task-file %s -- /bin/sh -c 'exec sleep 300' > %s 2>&1; echo rc=$? >> %s",
		kidoBin, h.writeTaskFile("gone-e2e"), agentOut, agentOut))
	h.sendKeys("Enter")
	agent := h.waitFileContains(agentOut, "rc=")
	bashOut := filepath.Join(h.dir, "bash.out")
	h.sendLiteral(fmt.Sprintf("%s tool async_bash --name gone-bash-e2e -- 'sleep 300' > %s 2>&1; echo rc=$? >> %s",
		kidoBin, bashOut, bashOut))
	h.sendKeys("Enter")
	bash := h.waitFileContains(bashOut, "rc=")
	h.in("set-hook", "-u", "-t", "alpha", "after-new-window")

	if !strings.HasPrefix(agent, "kido tool spawn_subagent: ") || !strings.Contains(agent, "rc=1") {
		t.Errorf("agent spawn = %q, want the failed mark reported and rc=1", agent)
	}
	if fields := strings.Fields(bash); len(fields) != 5 || !strings.Contains(bash, "rc=0") {
		t.Fatalf("async_bash = %q, want \"<window> <pane> <run> <output>\" and rc=0", bash)
	}
	bashRun := strings.Fields(bash)[2]

	var runs []struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		Outcome *struct {
			Result string `json:"result"`
			Text   string `json:"text"`
		} `json:"outcome"`
	}
	out := h.runKido("alpha", "runs.out", "runs", "--json")
	if err := json.Unmarshal([]byte(strings.SplitN(out, "\n", 2)[0]), &runs); err != nil {
		t.Fatalf("kido runs --json: %v (%q)", err, out)
	}
	found := false
	for _, r := range runs {
		if r.Name != "gone-e2e" {
			continue
		}
		found = true
		if r.Outcome == nil || r.Outcome.Result != "failed" || r.Outcome.Text == "" || !strings.Contains(agent, r.Outcome.Text) {
			t.Errorf("agent run %s outcome = %+v, want failed with the error the spawn printed", r.ID, r.Outcome)
		}
	}
	if !found {
		t.Errorf("kido runs --json = %q, want the agent run gone-e2e recorded", out)
	}
	if _, err := os.Stat(filepath.Join(h.stateDir, "runs", bashRun, "outcome")); !os.IsNotExist(err) {
		t.Errorf("bash run %s has a recorded outcome (%v); its window's loss is its wrapper's to report", bashRun, err)
	}
}

// A human at a shell has no agent identity to hand over: naming a real
// agent makes the child that agent's, and inventing one leaves an orphan
// the sweep closes within seconds. --no-parent's child must survive both
// the real sidebar's 100ms sweep and an explicit `kido reap` - the
// record rule 2 reads has no parent, and its first clause exempts it.
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
		t.Fatalf("kido tool spawn_subagent --no-parent printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	windowID, paneID := fields[0], fields[1]

	env := h.waitFileNonEmpty(envFile)
	for _, k := range []string{"KIDO_AGENT_PARENT_PID", "KIDO_AGENT_PARENT_SESSION"} {
		if got := envLine(env, k); got != "" {
			t.Errorf("spawned process's %s = %q, want it unset: the child is owned by nobody", k, got)
		}
	}
	// The shell typing the command has no record of its own: depth 0, its child 1.
	if got := envLine(env, "KIDO_AGENT_DEPTH"); got != "1" {
		t.Errorf("spawned process's KIDO_AGENT_DEPTH = %q, want 1 below a caller with no record", got)
	}

	h.programStatus(paneID, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", paneID, "#{pane_title}"), "π - "))
	h.agentStatus("loner-e2e", paneID, "pi")
	if out := h.runKido("alpha", "reap.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Errorf("kido reap output = %q, want a clean exit", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"a child spawned with --no-parent was closed as an orphan; an empty parent edge is exempt from rule 2")
}

// The other half of the pair above, what makes rule 2's exemption a
// decision, not an accident: same record-less shell, same command, one
// flag different. An invented --parent-session makes no window at all,
// since the child it would create is one the sweep collects within
// seconds, in another process, after this command has already exited
// successfully - refusing up front turns a silent, delayed close into
// something the caller is told about.
func TestSpawnFabricatedParentIsRefusedUpFront(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	out := h.runKido("alpha", "fabricated.out", "tool", "spawn_subagent",
		"--parent-pid", "1", // init, so the pid itself is alive and cannot be what refuses
		"--parent-session", "nobody-is-this",
		"--name", "orphan-e2e", "--task-file", h.writeTaskFile("orphan-e2e"))

	if !strings.Contains(out, "rc=1") {
		t.Errorf("kido tool spawn_subagent with a fabricated parent = %q, want rc=1", out)
	}
	if !strings.Contains(out, "nobody-is-this") || !strings.Contains(out, "--no-parent") {
		t.Errorf("output = %q, want it to name the session and point at --no-parent", out)
	}
	if got := h.in("list-windows", "-a", "-F", "#{window_name}"); strings.Contains(got, "orphan-e2e") {
		t.Errorf("windows = %q, want no window created for a refused spawn", got)
	}
}
