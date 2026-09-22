package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"kido/internal/state"
	"kido/internal/tmux"
)

// maxDepth is decision 5 in docs/subagents-plan.md: root 0 -> subagent 1
// -> subagent 2. A child's derived depth (see callerDepth) exceeding this
// is refused, which in practice means an agent already at maxDepth may not
// spawn another one.
const maxDepth = 2

// maxTaskBytes caps --task-file the same way the inbox caps a v0/v1
// prompt (MAX_PROMPT_BYTES in pi/kido-status.ts): the two paths both end
// up delivered as a session's first user message, so accepting more here
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
	return "usage: kido spawn --parent-pid PID --parent-instance ID --name NAME --task-file FILE [--depth N] [-- COMMAND...]"
}

// spawnCmd implements `kido spawn`: it creates a detached window in the
// caller's own tmux session (found from $TMUX_PANE) running COMMAND,
// defaulting to `pi` when none is given, with KIDO_AGENT_* set in its
// environment so the child can report its place in the spawn tree and
// read its task. It prints the new window and pane ids, space-separated,
// on success. See docs/subagents-plan.md's Spawning section.
//
// The task text is never a command-line argument: it is model-authored,
// arbitrary in shape, and the tmux command line nests three parsers (tmux,
// sh, and tmux again for the eventual command) that no escape survives
// (see AGENTS.md). --task-file names a file the child reads instead and
// unlinks once delivered. The window name is model-authored too, but does
// go on that command line, so it is checked with the same rule setup-tmux
// applies to a path it writes into ~/.tmux.conf (tmuxConfUnsafe).
func spawnCmd(args []string) error {
	fs := flag.NewFlagSet("spawn", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	parentPID := fs.Int("parent-pid", 0, "pid of the agent spawning this one")
	parentInstance := fs.String("parent-instance", "", "Instance of the agent spawning this one")
	// --depth is accepted for backward compatibility (pi/kido-status.ts
	// still sends it, to give a model an early refusal without a round
	// trip through kido - see the plan's Spawning section) but is no
	// longer authoritative: see callerDepth below. It is parsed only so a
	// negative value can be rejected as a wrong value rather than silently
	// ignored like an omitted one (D6).
	claimedDepth := fs.Int("depth", -1, "the caller's own claimed depth; accepted but not trusted, see callerDepth")
	name := fs.String("name", "", "window name, and (by convention) the child's own --name")
	taskFile := fs.String("task-file", "", "file holding the task text to deliver as the child's first message")
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

	// D12: a typo in --task-file would otherwise create the window anyway,
	// leaving a child that reads nothing and starts with no task and no
	// sign anything was lost.
	fi, err := os.Stat(*taskFile)
	if err != nil {
		return fmt.Errorf("--task-file %q: %w", *taskFile, err)
	}
	if fi.IsDir() {
		return fmt.Errorf("--task-file %q is a directory, not a task file", *taskFile)
	}
	if fi.Size() > maxTaskBytes {
		return fmt.Errorf("--task-file %q is %d bytes, over the %d byte task limit", *taskFile, fi.Size(), maxTaskBytes)
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

	env := []string{
		"KIDO_AGENT_PARENT_PID=" + strconv.Itoa(*parentPID),
		"KIDO_AGENT_PARENT_INSTANCE=" + *parentInstance,
		"KIDO_AGENT_DEPTH=" + strconv.Itoa(depth),
		"KIDO_AGENT_TASK_FILE=" + *taskFile,
	}
	windowID, paneID, err := newWindow(pane.SessionID, *name, pane.CurrentPath, env, command)
	if err != nil {
		return err
	}
	// The mark is what makes this window reapable, and the only thing that
	// does (internal/reap): it is how a sweep tells a window kido created
	// from one the user did, long after every trace of the child is gone
	// from kido's own state. A spawn whose mark failed is reported as a
	// failure even though the window is up, because the alternative is a
	// window nothing will ever collect.
	if err := markSubagent(windowID, fmt.Sprintf("parent=%s depth=%d", *parentInstance, depth)); err != nil {
		return err
	}
	fmt.Printf("%s %s\n", windowID, paneID)
	return nil
}
