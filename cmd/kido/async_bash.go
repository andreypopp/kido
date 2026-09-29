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
	// KIDO_STATE_DIR rides along with the KIDO_AGENT_* channel because
	// new-window gives the wrapper the tmux server's environment, not this
	// process's, and it must find the same run directory this command just
	// wrote.
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

// A single word after "--" is a shell command line, run under bash -c
// ("make -j8 && ./run"); several words are an argv, exec'd as given.
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
