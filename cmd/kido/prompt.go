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
// reported one (see deliver and inbox.go), otherwise pasted into the pane
// with Enter a moment later (see tmux.SendPrompt).
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
	// could actually change the answer (needsSweep). Otherwise pi stays
	// nil, which state.IsAgentPane treats as "nothing known".
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
// printing any error itself. See deliverInboxOrPaste for the actual
// inbox-or-paste rule, shared with kido message.
func deliver(inbox, pane, text string) int {
	if _, err := deliverInboxOrPaste(inbox, text, pane, text); err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	return 0
}

// sendPrompt is tmux.SendPrompt, indirected so tests can check the paste
// fallback fires without talking to a real tmux server - the same reason
// listPanes is a variable.
var sendPrompt = tmux.SendPrompt

// deliverInboxOrPaste hands a message to the agent listening on inbox,
// falling back to a tmux paste of pasteText into pane only when the inbox
// turns out unavailable (errInboxUnavailable) - never on any other error,
// since the message may already have been delivered and resending would
// double-send (see AGENTS.md). Each destination is followed by what it
// receives, because the two payloads differ for kido message: the inbox
// gets a v1 envelope when the target advertises one, but a paste always
// types the raw text, since nothing on the receiving end of send-keys
// parses JSON.
//
// paste reports which path was actually used, for a caller that wants to
// say so (kido message's stdout).
func deliverInboxOrPaste(inbox, inboxPayload, pane, pasteText string) (paste bool, err error) {
	if inbox != "" {
		err := deliverInbox(inbox, inboxPayload)
		switch {
		case err == nil:
			return false, nil
		case errors.Is(err, errInboxUnavailable):
			// Nothing was sent; send-keys is still open.
		default:
			return false, err
		}
	}
	if err := sendPrompt(pane, pasteText); err != nil {
		return false, err
	}
	return true, nil
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
