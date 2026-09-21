package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"kido/internal/msg"
	"kido/internal/state"
)

// message implements `kido message <to>`: it reads text from stdin (the
// whole input, with one trailing newline stripped) and delivers it to the
// agent whose session id to names exactly, or whose session id it
// uniquely prefixes - the exercise for the v1 inbox envelope (see
// internal/msg and AGENTS.md's note on the protocol). Full name-based
// addressing is a later phase; this is deliberately just enough to prove
// the wire shape.
//
// Unlike kido prompt, message never falls back to send-keys: it only
// targets an agent that has reported an inbox socket. If the target has
// not advertised an envelope version (state.Session.Protocol is zero), the
// envelope would arrive at an unupgraded receiver as the user's literal
// prompt, so the message is sent as v0 raw text instead - the same
// contract kido prompt already relies on.
//
// Returns the process exit code, printing any error to stderr itself.
func message(args []string, stdin io.Reader) int {
	fs := flag.NewFlagSet("message", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: kido message <to>")
		return 1
	}
	to := fs.Arg(0)

	b, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	text := strings.TrimSuffix(string(b), "\n")
	if text == "" {
		fmt.Fprintln(os.Stderr, "no message given")
		return 1
	}

	states, err := state.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	target, err := resolveTarget(states, to)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	if target.Inbox == "" {
		fmt.Fprintf(os.Stderr, "kido message: %s has no inbox\n", target.ID)
		return 1
	}

	payload := text
	if target.Protocol >= msg.V1 {
		env := msg.Envelope{
			V:    msg.V1,
			Kind: msg.KindMessage,
			ID:   msg.NewID(),
			From: senderOf(states),
			Text: text,
		}
		raw, err := json.Marshal(env)
		if err != nil {
			fmt.Fprintln(os.Stderr, "kido message:", err)
			return 1
		}
		payload = string(raw)
	}

	if err := deliverInbox(target.Inbox, payload); err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	return 0
}

// senderOf fills an envelope's From from the caller's own state record,
// found by its pane ($TMUX_PANE) - best effort, since kido message may run
// from a pane that has not reported one at all, in which case only Pane is
// known.
func senderOf(states map[string]state.Session) msg.From {
	pane := os.Getenv("TMUX_PANE")
	self, ok := states[pane]
	if !ok {
		return msg.From{Pane: pane}
	}
	return msg.From{Session: self.ID, Name: self.Title, Pane: pane}
}

// resolveTarget finds the live session to address as to: an exact session
// id match wins outright, and otherwise to must uniquely prefix one live
// session id. Ambiguity is an error rather than a guess, the same policy
// kido prompt uses for its exit 5.
func resolveTarget(states map[string]state.Session, to string) (state.Session, error) {
	for _, s := range states {
		if s.ID == to {
			return s, nil
		}
	}
	var matches []state.Session
	for _, s := range states {
		if strings.HasPrefix(s.ID, to) {
			matches = append(matches, s)
		}
	}
	switch len(matches) {
	case 0:
		return state.Session{}, fmt.Errorf("no agent session matches %q", to)
	case 1:
		return matches[0], nil
	default:
		return state.Session{}, fmt.Errorf("%q matches multiple sessions", to)
	}
}
