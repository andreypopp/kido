package main

import (
	"errors"
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
// it to the one agent pane in scope: over the agent's inbox socket when it
// reported one (see deliver and inbox.go), otherwise the way
// ~/.config/ink/plugged/cctools/bin/ccsend does: send-keys -l the text,
// then Enter a moment later.
//
// With no flag, the scope is the caller's window, widening to the whole
// session when the window has no Claude Code pane at all. --window (also
// -window) pins the scope to the caller's window only, never widening.
// The caller's own pane ($TMUX_PANE) is only ever a candidate when it is
// itself an agent pane, since candidates are picked by state.IsAgentPane
// and a plain shell pane never qualifies. An agent pane is any pane kido
// badges in the sidebar - Claude Code or pi alike - and the messages speak
// of "agent" rather than naming either one.
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
	// procs.Sweep() shells out to ps, so it is only worth the cost when it
	// could actually change the answer: some in-scope pane whose current
	// command could be pi and which has not already reported a state
	// record (needsSweep, mirroring internal/ui's take()). Otherwise pi
	// stays nil, which state.IsAgentPane treats as "nothing known".
	var pi map[int]bool
	if needsSweep(panes, states, self, false) {
		pi = procs.Sweep().Pi
	}
	candidates := agentPanesIn(panes, states, pi, self, false)
	if !window && len(candidates) == 0 {
		// Widen to the session only when the window has none at all.
		// Several panes in the window would also be several in the
		// session, so exit 5 (ambiguous) must not change by widening;
		// only the not-found case does.
		if pi == nil && needsSweep(panes, states, self, true) {
			pi = procs.Sweep().Pi
		}
		candidates = agentPanesIn(panes, states, pi, self, true)
	}

	switch len(candidates) {
	case 0:
		fmt.Fprintln(os.Stderr, "agent not found")
		return 4
	case 1:
		return deliver(states[candidates[0].PaneID].Inbox, candidates[0].PaneID, text)
	default:
		fmt.Fprintln(os.Stderr, "multiple agents found")
		return 5
	}
}

// deliver hands text to the chosen agent and returns prompt's exit code,
// printing any error itself. An agent that reported an inbox socket (pi,
// through its kido extension) gets the prompt as a real user message over
// that socket; everything else - Claude Code above all, which has no such
// socket - gets it typed into the pane with send-keys.
//
// One protocol, not a kind of address: inbox names a socket speaking
// kido's own line protocol (cmd/kido/inbox.go), and deliverInbox is the
// only thing that can be on the other end. A second agent whose socket
// frames messages differently - Claude Code's per-session socket, say -
// would need a kind recorded alongside the path in state.Session (say
// InboxKind, defaulting to kido's own for records written before it), and
// a switch on that kind right here choosing the client to run. Nothing
// needs that yet, so the field stays one protocol wide rather than
// pretending to be general.
//
// The two paths are not interchangeable once a connection is up: only a
// failure that proves the message was never sent (errInboxUnavailable: no
// socket, or a stale one a dead process left behind) falls back to
// send-keys. A later failure is reported as an error, because the agent
// may already have the prompt and typing it again would send it twice.
func deliver(inbox, pane, text string) int {
	if inbox != "" {
		err := deliverInbox(inbox, text)
		switch {
		case err == nil:
			return 0
		case errors.Is(err, errInboxUnavailable):
			// Nothing was sent; send-keys is still open.
		default:
			fmt.Fprintln(os.Stderr, "kido prompt:", err)
			return 1
		}
	}
	if err := tmux.SendPrompt(pane, text); err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	return 0
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

// inScope reports whether p is within the search scope: self's session,
// narrowed to self's window unless wholeSession.
func inScope(p tmux.Pane, self tmux.Pane, wholeSession bool) bool {
	if p.SessionName != self.SessionName {
		return false
	}
	return wholeSession || p.WindowIndex == self.WindowIndex
}

// agentPanesIn returns the agent panes (per state.IsAgentPane) in self's
// session, narrowed to self's window unless wholeSession.
func agentPanesIn(panes []tmux.Pane, states map[string]state.Session, pi map[int]bool, self tmux.Pane, wholeSession bool) []tmux.Pane {
	var out []tmux.Pane
	for _, p := range panes {
		if !inScope(p, self, wholeSession) {
			continue
		}
		if state.IsAgentPane(states, pi, p) {
			out = append(out, p)
		}
	}
	return out
}

// needsSweep reports whether some in-scope pane's current command could be
// pi and has not already reported a state record - i.e. whether
// procs.Sweep() could change what agentPanesIn returns for this scope. A
// pane already in states is decided without the process table; one that
// has reported nothing and is not running a pi-shaped command can't be pi
// either, by the same rule state.IsAgentPane and internal/ui's take() use.
func needsSweep(panes []tmux.Pane, states map[string]state.Session, self tmux.Pane, wholeSession bool) bool {
	for _, p := range panes {
		if !inScope(p, self, wholeSession) {
			continue
		}
		if _, reported := states[p.PaneID]; reported {
			continue
		}
		if procs.MaybePi(p.CurrentCommand) {
			return true
		}
	}
	return false
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
