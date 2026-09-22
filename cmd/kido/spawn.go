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

// maxDepth is decision 5 in docs/subagents-plan.md: root 0 -> subagent 1
// -> subagent 2. A child's derived depth (see callerDepth) exceeding this
// is refused, which in practice means an agent already at maxDepth may not
// spawn another one.
const maxDepth = 2

// maxTaskBytes caps the task the same way the inbox caps a v0/v1 prompt
// (MAX_PROMPT_BYTES in pi/kido-status.ts): the two paths both end up
// delivered as a session's first user message, so accepting more here
// than the inbox would ever accept is not generosity, it is a second
// answer to "how big can a prompt be". The literal can't be shared across
// Go and TypeScript, so it is restated, not imported.
const maxTaskBytes = 1024 * 1024

// maxWindowNameLen caps the model-authored --name. The sidebar column
// (field() in internal/ui) is the only consumer that renders it, and
// truncates its whole line to the terminal width regardless - but a name
// long enough to matter is already useless as a name, and rejecting it
// outright (like tmuxConfUnsafe below) keeps the failure visible to the
// model instead of quietly mangling something it authored.
const maxWindowNameLen = 64

// newWindow and markSubagent are tmux.NewWindow and tmux.MarkSubagent,
// indirected so tests can check what kido spawn hands to tmux without a
// real server - the same reason listPanes (message.go) and sendPrompt
// (prompt.go) are variables.
var (
	newWindow    = tmux.NewWindow
	markSubagent = tmux.MarkSubagent
)

func spawnUsage() string {
	return "usage: kido spawn --parent-pid PID --parent-instance ID --name NAME --task-file FILE|- [--depth N] [--model M] [--tools T,...] [-- COMMAND...]"
}

// spawnCmd implements `kido spawn`: it creates a detached window in the
// caller's own tmux session (found from $TMUX_PANE) running COMMAND,
// defaulting to `pi` when none is given, with KIDO_AGENT_* set in its
// environment so the child can report its place in the spawn tree and
// read its task. It prints the new window id, pane id and run id,
// space-separated, on success. See docs/subagents-plan.md's Spawning and
// Phase 8 sections.
//
// The task text is never a command-line argument: it is model-authored,
// arbitrary in shape, and the tmux command line nests three parsers (tmux,
// sh, and tmux again for the eventual command) that no escape survives
// (see AGENTS.md). --task-file names a file to read it from, or "-" to
// read it from stdin - kido, not the caller, decides it becomes a file on
// disk (see docs/subagents-plan.md's "Deferred: subagents off this
// machine" section), and that file lives inside the run's own directory
// from the start rather than a temp file the caller manages. The window
// name is model-authored too, but does go on that command line, so it is
// checked with the same rule setup-tmux applies to a path it writes into
// ~/.tmux.conf (tmuxConfUnsafe).
//
// The run id is generated here and doubles as the child's own pi session
// id (--session-id is added to a "pi" command automatically, see below):
// restarting a finished run is exactly `pi --session <run-id>`, and
// forking it is `pi --fork <run-id>`, with no separate bookkeeping to
// look either up.
func spawnCmd(args []string) error {
	fs := flag.NewFlagSet("spawn", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	parentPID := fs.Int("parent-pid", 0, "pid of the agent spawning this one")
	parentInstance := fs.String("parent-instance", "", "Instance of the agent spawning this one")
	// --depth is accepted for backward compatibility (pi/kido-agents.ts
	// still sends it, to give a model an early refusal without a round
	// trip through kido - see the plan's Spawning section) but is no
	// longer authoritative: see callerDepth below. It is parsed only so a
	// negative value can be rejected as a wrong value rather than silently
	// ignored like an omitted one (D6).
	claimedDepth := fs.Int("depth", -1, "the caller's own claimed depth; accepted but not trusted, see callerDepth")
	name := fs.String("name", "", "window name, and (by convention) the child's own --name")
	taskFile := fs.String("task-file", "", `file holding the task text to deliver as the child's first message, or "-" for stdin`)
	model := fs.String("model", "", "model the child will run, recorded in the run's meta for kido runs")
	toolsFlag := fs.String("tools", "", "comma-separated tool allowlist the child will run, recorded in the run's meta for kido runs")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, spawnUsage())
	}
	// fs.Visit, not the value, is what tells an omitted --depth (fine: it
	// is only a cross-check) apart from an explicit negative one (a wrong
	// value, not an omission - same distinction agentStatus's --inbox and
	// --protocol handling makes).
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

	// D5: the caller's --depth is a claim about itself, and a subagent
	// already at maxDepth could pass --depth 1 and spawn without limit -
	// that defeats decision 5 entirely, since the ceiling would only ever
	// be as real as the caller chose to make it. kido derives the child's
	// depth itself instead, from the caller's own last-reported state
	// record (state.Session.Depth), which the caller cannot pick.
	//
	// A caller with no record at all - a human running `kido spawn` by
	// hand, or an agent that has not reported yet - is treated as depth 0.
	// That is the same trust decision Load already makes for every other
	// unauthenticated same-uid record (see docs/subagents-plan.md's Trust
	// section): kido has nothing better to go on, and treating an unknown
	// caller as root is the conservative reading, not a hole - it can only
	// ever make the ceiling for that spawn stricter than it would be with
	// a real record showing a shallower depth, never looser.
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

	// A "pi" command gets --session-id inserted right after it, which is
	// what ties the run id to the child's own session from birth (see the
	// doc comment above) - a caller-overridden COMMAND (the e2e suite's
	// fake binaries, mainly) is left exactly as given, since it has no pi
	// session of its own to name.
	if command[0] == "pi" {
		command = append([]string{command[0], "--session-id", runID}, command[1:]...)
	}

	env := []string{
		"KIDO_AGENT_PARENT_PID=" + strconv.Itoa(*parentPID),
		"KIDO_AGENT_PARENT_INSTANCE=" + *parentInstance,
		"KIDO_AGENT_DEPTH=" + strconv.Itoa(depth),
		"KIDO_AGENT_TASK_FILE=" + subrun.TaskPath(runID),
		// Set unconditionally, not just for a "pi" command: --session-id
		// above already gives a spawned pi its run id as its own session id,
		// but a child that is not pi (every e2e fake command, and any future
		// non-tmux-local backend per the plan's "Deferred" section) has no
		// other way to learn it, and self-reporting via `kido run-outcome`
		// needs it.
		"KIDO_AGENT_RUN_ID=" + runID,
	}
	windowID, paneID, panePID, err := newWindow(pane.SessionID, *name, pane.CurrentPath, env, command)
	if err != nil {
		// Nothing to restart or fork ever existed, so say why rather than
		// leave a caller of `kido runs` to guess at a run with no window and
		// no outcome. The meta this would otherwise have skipped is written
		// first: `kido runs` passes over a directory with no meta file, and
		// would pass over this outcome with it.
		subrun.WriteMeta(meta)                                                                                //nolint:errcheck // best effort
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	meta.Window, meta.Pane, meta.PID = windowID, paneID, panePID
	if err := subrun.WriteMeta(meta); err != nil {
		return err
	}
	// The mark is what makes this window reapable, and the only thing that
	// does (internal/reap): it is how a sweep tells a window kido created
	// from one the user did, long after every trace of the child is gone
	// from kido's own state. The run id embedded in it is what lets that
	// same sweep record a run's outcome as Died without needing anything
	// else kido knows about the child.
	//
	// D5: a failed mark used to return the error with the window left up,
	// unmarked - and unmarked means uncollectable, forever: internal/reap's
	// own rule (see docs/subagents-plan.md's Lifecycle section) is that a
	// sweep only ever touches a window carrying @kido_subagent, precisely
	// so it never closes one it did not create. No sweep, no `kido stop`,
	// no human glancing at `kido agents` would ever connect that window
	// back to this failed spawn - `kido runs` would show a run with no
	// window and no outcome, and the window itself would sit there
	// unexplained. The sibling failure just above (newWindow itself
	// failing) already treats "could not get to a clean, recorded state"
	// as a hard failure rather than something to leave for a human to
	// puzzle over later, and a window nothing can ever find again is worse
	// than no window at all, so this path matches it: kill the window
	// rather than strand it, and record the run as failed the same way.
	if err := markSubagent(windowID, tmux.SubagentMark(runID, *parentInstance, depth)); err != nil {
		killWindow(windowID)                                                                                  //nolint:errcheck // best effort cleanup; the mark error is what matters
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	fmt.Printf("%s %s %s\n", windowID, paneID, runID)
	return nil
}

// readTask reads the task text from path, or from stdin when path is "-".
// D12/D9 apply either way: a missing or oversized task is refused before
// any window is ever created, since the alternative is a child that reads
// nothing and starts with no task and no sign anything was lost.
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
