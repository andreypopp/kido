package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func (h *harness) waitOutcome(runID string) runInfo {
	h.t.Helper()
	var info runInfo
	h.waitFor(func() bool {
		info = h.runInfo(runID)
		return info.Outcome != "running"
	}, settle, msgf("run %s to record an outcome (is %q)", runID, info.Outcome))
	return info
}

func (h *harness) runInfo(runID string) runInfo {
	h.t.Helper()
	out := h.runKido("alpha", runID+"-show.out", "runs", "--json", runID)
	var info runInfo
	// runKido's script appends its own "rc=0" line after the JSON.
	if err := json.Unmarshal([]byte(strings.SplitN(out, "\n", 2)[0]), &info); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return info
}

// A run whose parent pane is gone is collected by the sweep even while its
// command runs, and recorded as failed because its parent ended.
func TestRunChildEndsWhenItsParentPaneQuits(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	childPIDFile := filepath.Join(h.dir, "orphan-command.pid")
	parent := h.newWindow("alpha", "orphan-parent", "sh", "-c", "exec sleep 300")
	h.programStatus(parent, "state=idle:app=pi")
	r := h.startRun(caller, "run-child", parent, "--name", "orphan-bash", "--", "sh", "-c",
		"echo $$ > "+shellQuote(childPIDFile)+"; exec sleep 300")
	childPID, err := strconv.Atoi(strings.TrimSpace(h.waitFileContains(childPIDFile, "")))
	if err != nil {
		t.Fatal(err)
	}
	if info := h.runInfo(r.ID); info.Outcome != "running" {
		t.Fatalf("run before parent quit = %q, want running", info.Outcome)
	}
	h.killPane(parent)
	h.waitFor(func() bool {
		return syscall.Kill(childPID, 0) == syscall.ESRCH && !h.paneExists(r.paneID())
	}, settle, msgf("the orphan command to exit after its parent quits"))
	info := h.waitOutcome(r.ID)
	if info.Outcome != "failed" || info.OutcomeText != "its parent ended" {
		t.Errorf("orphan outcome = %q/%q, want failed/its parent ended", info.Outcome, info.OutcomeText)
	}
}

// What a run is made of: a meta naming the run's own pane, the name given,
// the command kept as an argv, and the environment the caller's pipeline
// needs. Several words are an argv, not a command line joined back
// together: `sh -c 'exit 3' ignored` joined would run `sh -c exit` and
// succeed.
func TestRunRecordsItsRunAndItsCommand(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// The run exits at once, and tmux's whole-second dead time lets the
	// sweep close its window before startCommand reads it.
	h.hideSidebar()
	caller := h.firstPane("alpha")
	r := h.startRun(caller, "run", "--name", "env", "--", "bash", "-o", "pipefail", "-c",
		"echo run-output; exit 3 | tee \"$KIDO_RUN_OUTPUT\"")
	meta := h.runMeta("env", r.ID)
	for k, want := range map[string]any{
		"name": "env", "pane": r.paneID(),
	} {
		if fmt.Sprint(meta[k]) != fmt.Sprint(want) {
			t.Errorf("run meta %s = %v, want %v", k, meta[k], want)
		}
	}
	if _, ok := meta["parent"]; ok {
		t.Errorf("a parentless run has a parent: %v", meta["parent"])
	}
	var command []string
	raw, err := os.ReadFile(filepath.Join(h.stateDir, "runs", r.ID, "command"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &command); err != nil {
		t.Fatal(err)
	}
	if len(command) != 5 || command[0] != "bash" || command[4] != "echo run-output; exit 3 | tee \"$KIDO_RUN_OUTPUT\"" {
		t.Errorf("run command = %q, want the argv as given", command)
	}
	windowID := r.Window
	started := h.startCommand(windowID)
	if !strings.Contains(started, "bash -o pipefail -c") || !strings.Contains(started, "tee") {
		t.Errorf("run window's command = %q, want the run's own bash pipeline", started)
	}
	argv := h.startRun(caller, "run", "--name", "argv", "--", "sh", "-c", "exit 3", "ignored")
	if info := h.waitOutcome(argv.ID); info.Outcome != "failed" || info.OutcomeText != "exit 3" {
		t.Errorf("argv run = %q/%q, want failed/\"exit 3\" from the words run as an argv", info.Outcome, info.OutcomeText)
	}
}

// A running bash run's row counts its seconds up in place of a tail, and
// once the run has ended shows its outcome instead. The run's window is
// made the client's current one so the reap leaves its dead pane to read.
func TestRunRowShowsElapsedThenOutcome(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	finish := filepath.Join(h.dir, "tick-finish")
	r := h.startRun(caller, "run", "--name", "tick-e2e", "--", "sh", "-c",
		fmt.Sprintf("while [ ! -f %s ]; do sleep 0.1; done", finish))
	windowID := r.Window
	h.in("select-window", "-t", windowID)

	elapsed := regexp.MustCompile(`◼tick-e2e (\d+)s$`)
	seconds := func() int {
		if m := elapsed.FindStringSubmatch(h.rowFor("tick-e2e")); m != nil {
			n, _ := strconv.Atoi(m[1])
			return n
		}
		return -1
	}
	first := -1
	h.waitFor(func() bool { first = seconds(); return first >= 1 }, settle,
		func() string { return fmt.Sprintf("an elapsed time of 1s or more, row is %q", h.rowFor("tick-e2e")) })
	h.waitFor(func() bool { return seconds() > first }, settle,
		func() string {
			return fmt.Sprintf("the elapsed time to pass %ds, row is %q", first, h.rowFor("tick-e2e"))
		})

	if err := os.WriteFile(finish, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { return h.rowFor("tick-e2e") == "╶✓tick-e2e completed" }, settle,
		func() string { return fmt.Sprintf("the ended run's outcome, row is %q", h.rowFor("tick-e2e")) })
}
