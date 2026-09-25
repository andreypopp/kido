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
// stdin (one trailing newline stripped) and sends it to the one
// top-level agent pane in scope, over its inbox when it reported one and
// pasted into the pane otherwise. The scope is the caller's window,
// widening to the session only when the window has no top-level agent
// pane at all; --window never widens. A candidate pane is any pane
// state.IsAgentPane accepts whose window carries no @kido_subagent mark
// (tmux.Pane.Subagent) - a subagent is never a target, spawned by kido
// or not.
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

	self, panes, err := callerPane()
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}

	states, _ := state.Load()
	// procs.Sweep() shells out to ps, so only when it could change the
	// answer; a nil map is "nothing known" to state.IsAgentPane.
	var pi map[int]bool
	if needsSweep(panes, states, self, false) {
		pi = procs.Sweep().Pi
	}
	candidates := agentPanesIn(panes, states, pi, self, false)
	if !window && len(candidates) == 0 {
		// Only the not-found case widens: several in the window would
		// also be several in the session, so exit 5 never changes.
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
// printing any error itself.
func deliver(inbox, pane, text string) int {
	if _, err := deliverInboxOrPaste(inbox, text, pane, text); err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	return 0
}

// sendPrompt is tmux.SendPrompt, indirected so tests can check the paste
// fallback fires without a tmux server.
var sendPrompt = tmux.SendPrompt

// deliverInboxOrPaste hands a message to the agent listening on inbox,
// falling back to a tmux paste of pasteText into pane only on
// errInboxUnavailable: any other error means the message may already
// have been delivered (docs/design.md, "Delivery, and when a paste is
// allowed"). The two payloads differ for kido message_agent: the inbox may get
// a v1 envelope, a paste always types the raw text. paste reports which
// path was used.
func deliverInboxOrPaste(inbox, inboxPayload, pane, pasteText string) (paste bool, err error) {
	if inbox != "" {
		err := deliverInbox(inbox, inboxPayload)
		switch {
		case err == nil:
			return false, nil
		case errors.Is(err, errInboxUnavailable):
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

// agentPanesIn returns the top-level agent panes (per state.IsAgentPane,
// excluding any pane whose window carries the @kido_subagent mark) in
// self's session, narrowed to self's window unless wholeSession.
func agentPanesIn(panes []tmux.Pane, states map[string]state.Session, pi map[int]bool, self tmux.Pane, wholeSession bool) []tmux.Pane {
	var out []tmux.Pane
	for _, p := range panes {
		if !inScope(p, self, wholeSession) {
			continue
		}
		if p.Subagent != "" {
			continue
		}
		if state.IsAgentPane(states, pi, p) {
			out = append(out, p)
		}
	}
	return out
}

// needsSweep reports whether some in-scope pane's current command could
// be pi and has not already reported a state record, i.e. whether
// procs.Sweep() could change what agentPanesIn returns.
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
