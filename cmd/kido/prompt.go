package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"kido/internal/msg"
	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
)

// The scope is the caller's window, widening to the session only when
// the window has no top-level agent pane at all; --window never widens.
// A candidate pane is any pane state.IsAgentPane accepts whose window has
// no run pane (tmux.RunPane) - a subagent is never a target, spawned by
// kido or not.
func prompt(args []string, stdin io.Reader) int {
	fs := flag.NewFlagSet("prompt", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	windowFlag := fs.Bool("window", false, "search only the caller's window, never widening to the session")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "kido prompt: unknown argument %q\n", fs.Arg(0))
		return 1
	}
	window := *windowFlag

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
		inbox := states[candidates[0].PaneID].Inbox
		if _, err := deliverInboxOrPaste(inbox, text, candidates[0].PaneID, text); err != nil {
			fmt.Fprintln(os.Stderr, "kido prompt:", err)
			return 1
		}
		return 0
	default:
		fmt.Fprintln(os.Stderr, "multiple agents found")
		return 5
	}
}

var sendPrompt = tmux.SendPrompt

// Falls back to a tmux paste of pasteText into pane only on
// msg.ErrInboxUnavailable: any other error means the message may already
// have been delivered (docs/design.md, "Delivery, and when a paste is
// allowed"). paste reports which path was used.
func deliverInboxOrPaste(inbox, inboxPayload, pane, pasteText string) (paste bool, err error) {
	if inbox != "" {
		err := msg.Deliver(inbox, inboxPayload)
		switch {
		case err == nil:
			return false, nil
		case errors.Is(err, msg.ErrInboxUnavailable):
		default:
			return false, err
		}
	}
	if err := sendPrompt(pane, pasteText); err != nil {
		return false, err
	}
	return true, nil
}

func inScope(p tmux.Pane, self tmux.Pane, wholeSession bool) bool {
	if p.SessionName != self.SessionName {
		return false
	}
	return wholeSession || p.WindowIndex == self.WindowIndex
}

func agentPanesIn(panes []tmux.Pane, states map[string]state.Session, pi map[int]bool, self tmux.Pane, wholeSession bool) []tmux.Pane {
	var out []tmux.Pane
	for _, p := range panes {
		if !inScope(p, self, wholeSession) {
			continue
		}
		if _, ok := tmux.RunPane(panes, p.WindowID); ok {
			continue
		}
		if state.IsAgentPane(states, pi, p) {
			out = append(out, p)
		}
	}
	return out
}

// Reports whether procs.Sweep() could change what agentPanesIn returns.
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

func findPane(panes []tmux.Pane, id string) (tmux.Pane, bool) {
	for _, p := range panes {
		if p.PaneID == id {
			return p, true
		}
	}
	return tmux.Pane{}, false
}
