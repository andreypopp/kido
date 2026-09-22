package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

// maxDepth is the nesting ceiling: root 0 -> subagent 1 -> subagent 2.
const maxDepth = 2

// maxTaskBytes matches MAX_PROMPT_BYTES in pi/kido-status.ts: both paths
// deliver a session's first user message, and there should be one answer
// to how big a prompt can be. Restated because the literal cannot be
// shared across Go and TypeScript.
const maxTaskBytes = 1024 * 1024

// maxWindowNameLen caps the model-authored --name. Refusing keeps the
// failure visible to the model instead of quietly mangling the name.
const maxWindowNameLen = 64

// newWindow and markSubagent are tmux.NewWindow and tmux.MarkSubagent,
// indirected so tests can run spawnCmd without a tmux server.
var (
	newWindow    = tmux.NewWindow
	markSubagent = tmux.MarkSubagent
)

func spawnUsage() string {
	return "usage: kido spawn --parent-pid PID --parent-instance ID --name NAME --task-file FILE|- [--depth N] [--model M] [--tools T,...] [-- COMMAND...]"
}

// spawnCmd implements `kido spawn`: it creates a detached window in the
// caller's own tmux session (found from $TMUX_PANE) running COMMAND,
// defaulting to `pi`, with KIDO_AGENT_* set in its environment, and
// prints the new window id, pane id and run id, space-separated. The
// task goes in a file in the run's directory, never on the command line;
// the window name does go on the command line and is checked with
// tmuxConfUnsafe. See docs/design.md, "Spawning".
func spawnCmd(args []string) error {
	fs := flag.NewFlagSet("spawn", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	parentPID := fs.Int("parent-pid", 0, "pid of the agent spawning this one")
	parentInstance := fs.String("parent-instance", "", "Instance of the agent spawning this one")
	// --depth is accepted (pi/kido-agents.ts sends it for its own early
	// refusal) but never consulted for the child's depth: see callerDepth
	// below. It is parsed only so a negative value can be rejected.
	claimedDepth := fs.Int("depth", -1, "the caller's own claimed depth; accepted but not trusted, see callerDepth")
	name := fs.String("name", "", "window name, and (by convention) the child's own --name")
	taskFile := fs.String("task-file", "", `file holding the task text to deliver as the child's first message, or "-" for stdin`)
	model := fs.String("model", "", "model the child will run, recorded in the run's meta for kido runs")
	toolsFlag := fs.String("tools", "", "comma-separated tool allowlist the child will run, recorded in the run's meta for kido runs")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, spawnUsage())
	}
	depthGiven := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "depth" {
			depthGiven = true
		}
	})

	switch {
	case *parentPID <= 0:
		return fmt.Errorf("--parent-pid is required\n%s", spawnUsage())
	case *parentInstance == "":
		return fmt.Errorf("--parent-instance is required\n%s", spawnUsage())
	case depthGiven && *claimedDepth < 0:
		return fmt.Errorf("--depth must not be negative\n%s", spawnUsage())
	case *name == "":
		return fmt.Errorf("--name is required\n%s", spawnUsage())
	case *taskFile == "":
		return fmt.Errorf("--task-file is required\n%s", spawnUsage())
	}
	if i := strings.IndexAny(*name, tmuxConfUnsafe); i >= 0 {
		return fmt.Errorf("refusing window name %q: it contains %q, which cannot survive tmux's own command-line parsing", *name, (*name)[i:i+1])
	}
	if len(*name) > maxWindowNameLen {
		return fmt.Errorf("refusing window name %q: %d bytes is over the %d byte limit", *name, len(*name), maxWindowNameLen)
	}

	task, err := readTask(*taskFile)
	if err != nil {
		return err
	}

	var tools []string
	if *toolsFlag != "" {
		tools = strings.Split(*toolsFlag, ",")
	}

	command := fs.Args()
	if len(command) == 0 {
		command = []string{"pi"}
	}

	caller := os.Getenv("TMUX_PANE")
	panes, err := listPanes()
	if err != nil {
		return err
	}
	pane, ok := findPane(panes, caller)
	if !ok {
		return fmt.Errorf("pane %q not found", caller)
	}

	// The child's depth is derived from the caller's own state record, not
	// from --depth, which a caller at the ceiling could understate. A
	// caller with no record is depth 0, which can only make the ceiling
	// stricter (docs/design.md, "The depth ceiling is derived").
	states, err := state.Load()
	if err != nil {
		return err
	}
	callerDepth := states[caller].Depth
	depth := callerDepth + 1
	if depth > maxDepth {
		return fmt.Errorf("refusing to spawn at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)", depth, maxDepth)
	}

	runID := subrun.NewID()
	if err := subrun.Create(runID, task); err != nil {
		return err
	}
	meta := subrun.Meta{
		ID: runID, Name: *name, ParentInstance: *parentInstance, Depth: depth,
		Cwd: pane.CurrentPath, Model: *model, Tools: tools, StartedAt: time.Now(),
	}

	// The run id is the child's own pi session id; any other command has
	// no session to name and is left as given.
	if command[0] == "pi" {
		command = append([]string{command[0], "--session-id", runID}, command[1:]...)
	}

	env := []string{
		"KIDO_AGENT_PARENT_PID=" + strconv.Itoa(*parentPID),
		"KIDO_AGENT_PARENT_INSTANCE=" + *parentInstance,
		"KIDO_AGENT_DEPTH=" + strconv.Itoa(depth),
		"KIDO_AGENT_TASK_FILE=" + subrun.TaskPath(runID),
		// Unconditional: a child that is not pi has no --session-id to learn
		// the run id from, and `kido run-outcome` needs it.
		"KIDO_AGENT_RUN_ID=" + runID,
	}
	windowID, paneID, panePID, err := newWindow(pane.SessionID, *name, pane.CurrentPath, env, command)
	if err != nil {
		// The meta is written first: `kido runs` passes over a directory
		// with no meta file, and would pass over this outcome with it.
		subrun.WriteMeta(meta)                                                                                //nolint:errcheck // best effort
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	meta.Window, meta.Pane, meta.PID = windowID, paneID, panePID
	if err := subrun.WriteMeta(meta); err != nil {
		return err
	}
	// The mark is the only thing that makes this window reapable. An
	// unmarked window would be uncollectable forever, so a failed mark
	// kills the window rather than strand it.
	if err := markSubagent(windowID, tmux.SubagentMark(runID, *parentInstance, depth)); err != nil {
		killWindow(windowID)                                                                                  //nolint:errcheck // best effort cleanup; the mark error is what matters
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	fmt.Printf("%s %s %s\n", windowID, paneID, runID)
	return nil
}

// readTask reads the task text from path, or from stdin when path is "-".
// A missing or oversized task is refused before any window is created;
// the alternative is a child that starts with no task and no sign
// anything was lost.
func readTask(path string) (string, error) {
	if path == "-" {
		b, err := io.ReadAll(io.LimitReader(os.Stdin, maxTaskBytes+1))
		if err != nil {
			return "", fmt.Errorf("reading task from stdin: %w", err)
		}
		if len(b) > maxTaskBytes {
			return "", fmt.Errorf("task on stdin is over the %d byte task limit", maxTaskBytes)
		}
		return string(b), nil
	}
	fi, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("--task-file %q: %w", path, err)
	}
	if fi.IsDir() {
		return "", fmt.Errorf("--task-file %q is a directory, not a task file", path)
	}
	if fi.Size() > maxTaskBytes {
		return "", fmt.Errorf("--task-file %q is %d bytes, over the %d byte task limit", path, fi.Size(), maxTaskBytes)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("--task-file %q: %w", path, err)
	}
	return string(b), nil
}
