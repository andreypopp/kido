package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

const asyncBashUsage = "usage: kido async_bash [--name NAME] [--stream] -- COMMAND [ARG...]"

// asyncBashCmd implements `kido async_bash`: it creates a detached window
// in the caller's own tmux session running COMMAND under `kido
// async-run`, records the run with Kind bash and prints the window id,
// pane id and run id the way `kido spawn_subagent` does.
//
// The parent edge is the caller's own state record, not a flag: unlike a
// spawn, whose tool always names the session spawning, this command is
// run by whoever is at the pane - an agent's tool or a human's shell -
// and the record for that pane is the only honest answer to who should
// be told when the command ends. A caller with no record simply has no
// parent, and the run still records its outcome; see docs/design-
// subagents.md, "An async bash run".
func asyncBashCmd(args []string) error {
	fs := flag.NewFlagSet("async_bash", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	name := fs.String("name", "", "window name; derived from the command when omitted")
	stream := fs.Bool("stream", false, "send the command's output to this caller in batches as it runs")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, asyncBashUsage)
	}
	argv := commandArgv(fs.Args())
	if len(argv) == 0 {
		return fmt.Errorf("no command given\n%s", asyncBashUsage)
	}

	windowName := *name
	if windowName == "" {
		windowName = derivedName(fs.Args())
	}
	if err := checkWindowName(windowName); err != nil {
		return err
	}

	self, err := tmux.InvokedPath(os.Args[0])
	if err != nil {
		return err
	}

	pane, _, err := callerPane()
	if err != nil {
		return err
	}
	live, err := state.LoadLive()
	if err != nil {
		return err
	}
	caller := state.ByPane(live)[pane.PaneID]

	runID := subrun.NewID()
	// The task text is the command as a human reads it, which is what
	// `kido runs <id>` prints; the command file is what the wrapper execs.
	if err := subrun.Create(runID, strings.Join(fs.Args(), " ")); err != nil {
		return err
	}
	if err := subrun.WriteCommand(runID, argv); err != nil {
		return err
	}

	meta := subrun.Meta{
		ID: runID, Name: windowName, Kind: subrun.KindBash,
		ParentSession: caller.ID, Depth: caller.Depth + 1,
		Cwd: pane.CurrentPath, StartedAt: time.Now(),
	}
	if err := subrun.WriteMeta(meta); err != nil {
		return err
	}
	// The depth ceiling a spawn is held to is not applied: nesting is what
	// it bounds, and a bash run starts no agents. An agent already at the
	// ceiling may still run a build.
	//
	// KIDO_STATE_DIR rides along with the KIDO_AGENT_* channel because the
	// wrapper is kido itself: it must find the same run directory this
	// command just wrote, and new-window otherwise gives it the tmux
	// server's environment rather than this process's.
	var parent *parentEdge
	if caller.ID != "" {
		parent = &parentEdge{pid: caller.PID, session: caller.ID}
	}
	env := append(runEnv(runID, parent, meta.Depth, false), "KIDO_STATE_DIR="+state.Dir())
	command := []string{self, "async-run", "--run-id", string(runID)}
	if *stream {
		command = append(command, "--stream")
	}
	return createRunWindow(meta, pane.SessionID, env, command)
}

// commandArgv is what the window will actually exec, from the words after
// "--". A single word is a shell command line and is run under bash -c,
// which is the shape a model writes ("make -j8 && ./run"); several words
// are an argv and are exec'd as given. It is tmux's own convention for a
// pane's command, for the same reason: one word that is a whole command
// line has nowhere else to be parsed.
func commandArgv(args []string) []string {
	switch len(args) {
	case 0:
		return nil
	case 1:
		return []string{"bash", "-c", args[0]}
	default:
		return args
	}
}

// derivedName is a window name for a command nobody named: the first word
// of it, cut to what tmux and a sidebar row can carry.
func derivedName(args []string) string {
	first := ""
	if len(args) > 0 {
		if words := strings.Fields(args[0]); len(words) > 0 {
			first = filepath.Base(words[0])
		}
	}
	name := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == '-', r == '_', r == '.':
			return r
		}
		return -1
	}, first)
	if name == "" {
		return "bash"
	}
	if len(name) > maxWindowNameLen {
		name = name[:maxWindowNameLen]
	}
	return name
}
