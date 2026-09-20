package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
)

// prompt implements `kido prompt [--window]`: it reads a prompt from
// stdin (the whole input, with one trailing newline stripped) and sends
// it to the one Claude Code pane in scope, the way
// ~/.config/ink/plugged/cctools/bin/ccsend does: send-keys -l the text,
// then Enter a moment later.
//
// With no flag, the scope is the caller's window, widening to the whole
// session when the window has no Claude Code pane at all. --window (also
// -window) pins the scope to the caller's window only, never widening.
// The caller's own pane ($TMUX_PANE) is only ever a candidate when it is
// itself a Claude Code pane, since candidates are picked by
// state.IsAgentPane and a plain shell pane never qualifies. An agent pane
// is any pane kido badges in the sidebar, so a pi pane counts too; the
// messages still speak of claude code, which is what users of this command
// have always read.
//
// Returns the process exit code, printing any error to stderr itself.
func prompt(args []string, stdin io.Reader) int {
	window, err := parsePromptArgs(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}

	b, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	text := strings.TrimSuffix(string(b), "\n")
	if text == "" {
		fmt.Fprintln(os.Stderr, "no prompt given")
		return 1
	}

	caller := os.Getenv("TMUX_PANE")
	panes, err := tmux.ListPanes()
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	self, ok := findPane(panes, caller)
	if !ok {
		fmt.Fprintf(os.Stderr, "kido prompt: pane %q not found\n", caller)
		return 1
	}

	states, _ := state.Load()
	pi := procs.Sweep().Pi
	candidates := agentPanesIn(panes, states, pi, self, false)
	if !window && len(candidates) == 0 {
		// Widen to the session only when the window has none at all.
		// Several panes in the window would also be several in the
		// session, so exit 5 (ambiguous) must not change by widening;
		// only the not-found case does.
		candidates = agentPanesIn(panes, states, pi, self, true)
	}

	switch len(candidates) {
	case 0:
		fmt.Fprintln(os.Stderr, "claude code not found")
		return 4
	case 1:
		if err := tmux.SendPrompt(candidates[0].PaneID, text); err != nil {
			fmt.Fprintln(os.Stderr, "kido prompt:", err)
			return 1
		}
		return 0
	default:
		fmt.Fprintln(os.Stderr, "multiple claude code found")
		return 5
	}
}

// parsePromptArgs parses prompt's flags: --window/-window, rejecting any
// stray positional argument.
func parsePromptArgs(args []string) (window bool, err error) {
	fs := flag.NewFlagSet("prompt", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	windowFlag := fs.Bool("window", false, "search only the caller's window, never widening to the session")
	if err := fs.Parse(args); err != nil {
		return false, err
	}
	if fs.NArg() > 0 {
		return false, fmt.Errorf("unknown argument %q", fs.Arg(0))
	}
	return *windowFlag, nil
}

// agentPanesIn returns the agent panes (per state.IsAgentPane) in self's
// session, narrowed to self's window unless wholeSession.
func agentPanesIn(panes []tmux.Pane, states map[string]state.Session, pi map[int]bool, self tmux.Pane, wholeSession bool) []tmux.Pane {
	var out []tmux.Pane
	for _, p := range panes {
		if p.SessionName != self.SessionName {
			continue
		}
		if !wholeSession && p.WindowIndex != self.WindowIndex {
			continue
		}
		if state.IsAgentPane(states, pi, p) {
			out = append(out, p)
		}
	}
	return out
}

// findPane returns the pane with the given id.
func findPane(panes []tmux.Pane, id string) (tmux.Pane, bool) {
	for _, p := range panes {
		if p.PaneID == id {
			return p, true
		}
	}
	return tmux.Pane{}, false
}
