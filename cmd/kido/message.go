package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"unicode/utf8"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/tmux"
)

// listPanes is tmux.ListPanes, indirected so tests can supply a fixed
// pane list instead of talking to a real tmux server - the same reason
// inboxTimeout is a variable rather than a constant.
var listPanes = tmux.ListPanes

// message implements `kido message [--reply-to ID] <to>`: it reads text
// from stdin (the whole input, with one trailing newline stripped) and
// delivers it to the agent to names, resolved by resolveTarget within the
// caller's own tmux session.
//
// An agent that has reported an inbox socket gets it as a real user
// message, in the v1 envelope (internal/msg) when it has advertised that
// protocol, else as v0 raw text - the same contract kido prompt relies
// on. An agent with no inbox at all (Claude Code, or any agent whose
// socket bind failed) gets it pasted into its pane instead, by the same
// deliverInboxOrPaste kido prompt uses.
//
// Returns the process exit code, printing any error to stderr itself.
func message(args []string, stdin io.Reader) int {
	fs := flag.NewFlagSet("message", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	replyTo := fs.String("reply-to", "", "id of an earlier ask this message answers")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: kido message [--reply-to ID] <to>")
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
	// The two delivery paths do not agree on what invalid UTF-8 means: the
	// inbox marshals the text into JSON, which substitutes U+FFFD, while a
	// paste writes the bytes through untouched. The same message would then
	// arrive differently depending on whether the target happened to have an
	// inbox, and silently, so it is refused rather than corrupted.
	if !utf8.ValidString(text) {
		fmt.Fprintln(os.Stderr, "kido message: message is not valid UTF-8")
		return 1
	}

	states, err := state.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	panes, err := listPanes()
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	self := os.Getenv("TMUX_PANE")
	target, err := resolveTarget(states, panes, self, to)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	// Delivering to the sender's own pane would hand an agent its own
	// message as a fresh user turn, which is a loop it cannot see it is in:
	// list_agents reports the caller alongside everyone else, so a model
	// that picks a name off that list can pick its own.
	if target.Pane == self {
		fmt.Fprintf(os.Stderr, "kido message: %s is this agent\n", targetLabel(target))
		return 1
	}

	payload := text
	if target.Protocol >= msg.V1 {
		env := msg.Envelope{
			V:       msg.V1,
			Kind:    msg.KindMessage,
			ID:      msg.NewID(),
			From:    senderOf(states),
			ReplyTo: *replyTo,
			Text:    text,
		}
		raw, err := json.Marshal(env)
		if err != nil {
			fmt.Fprintln(os.Stderr, "kido message:", err)
			return 1
		}
		payload = string(raw)
	}

	paste, err := deliverInboxOrPaste(target.Inbox, payload, target.Pane, text)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	if paste {
		fmt.Printf("pasted into %s's pane\n", targetLabel(target))
	} else {
		fmt.Printf("delivered to %s by inbox\n", targetLabel(target))
	}
	return 0
}

// targetLabel names a session for a human (or a model) reading message's
// output: its reported title when it has one, else its session id.
func targetLabel(s state.Session) string {
	if s.Title != "" {
		return s.Title
	}
	return s.ID
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

// sessionsInSession is every state.Session whose pane is currently in
// tmux session, per a fresh pane list - a record names a pane and nothing
// above it, since a pane can move to another window or session while its
// process keeps running, so the pane list rather than the record is what
// says which session an agent is in. Shared with buildAgents (agents.go),
// which scopes kido agents the same way.
func sessionsInSession(states map[string]state.Session, panes []tmux.Pane, session string) []state.Session {
	byPane := map[string]tmux.Pane{}
	for _, p := range panes {
		byPane[p.PaneID] = p
	}
	var out []state.Session
	for _, s := range states {
		if byPane[s.Pane].SessionID == session {
			out = append(out, s)
		}
	}
	return out
}

// resolveTarget finds the agent message should address, scoped to the
// caller's own tmux session - the same boundary kido agents uses. An
// agent in another session is not addressable, and the error says so
// rather than claiming nothing matches at all.
//
// Within scope, addressing rules run in order, each erroring on its own
// ambiguity rather than falling through to the next rule to guess with a
// different one (see matchTarget):
//
//	a. an exact, case-insensitive Session.Title match
//	b. an exact session id
//	c. a unique session-id prefix
func resolveTarget(states map[string]state.Session, panes []tmux.Pane, self, to string) (state.Session, error) {
	caller, ok := findPane(panes, self)
	if !ok {
		return state.Session{}, fmt.Errorf("pane %q not found", self)
	}
	scoped := sessionsInSession(states, panes, caller.SessionID)
	if s, found, err := matchTarget(scoped, to); err != nil {
		return state.Session{}, err
	} else if found {
		return s, nil
	}

	// Nothing in scope. Check the rest of the world so the error can say
	// why, rather than just "not found" when to is spelled right and
	// simply lives in a different tmux session. An ambiguity out there is
	// kept rather than discarded: matchTarget reports one with a zero
	// session, so naming its id would print an empty one and claim a
	// single match where there were several.
	var all []state.Session
	for _, s := range states {
		all = append(all, s)
	}
	switch s, found, ambiguous := matchTarget(all, to); {
	case found && ambiguous != nil:
		return state.Session{}, fmt.Errorf("%w, none in this tmux session", ambiguous)
	case found:
		return state.Session{}, fmt.Errorf("%s (%s) is in another tmux session, not this one", to, s.ID)
	}
	return state.Session{}, fmt.Errorf("no agent session matches %q", to)
}

// matchTarget applies message's addressing rules to a set of candidate
// sessions: an exact case-insensitive title, then an exact id, then a
// unique id prefix. found reports whether any rule matched at all, so
// resolveTarget can tell "ambiguous" from "look elsewhere". err is
// non-nil only when a rule's own candidates were ambiguous, naming them
// so the caller can disambiguate.
func matchTarget(sessions []state.Session, to string) (target state.Session, found bool, err error) {
	var byTitle []state.Session
	for _, s := range sessions {
		if s.Title != "" && strings.EqualFold(s.Title, to) {
			byTitle = append(byTitle, s)
		}
	}
	if s, found, err := decide(byTitle, to, "name"); found {
		return s, true, err
	}

	for _, s := range sessions {
		if s.ID == to {
			return s, true, nil
		}
	}

	var byPrefix []state.Session
	for _, s := range sessions {
		if strings.HasPrefix(s.ID, to) {
			byPrefix = append(byPrefix, s)
		}
	}
	return decide(byPrefix, to, "id")
}

// decide turns one rule's candidate set into matchTarget's verdict: no
// candidate means look further, one is the answer, and several are an
// ambiguity error naming them - by is the rule they matched on, the only
// thing that differs between the title and prefix rules.
func decide(candidates []state.Session, to, by string) (state.Session, bool, error) {
	switch len(candidates) {
	case 0:
		return state.Session{}, false, nil
	case 1:
		return candidates[0], true, nil
	default:
		return state.Session{}, true, fmt.Errorf("%q matches several agents by %s: %s", to, by, describeCandidates(candidates))
	}
}

// describeCandidates names each session in sessions as "id (name)",
// falling back to its pane when it has reported no title, sorted so the
// error text is deterministic.
func describeCandidates(sessions []state.Session) string {
	names := make([]string, len(sessions))
	for i, s := range sessions {
		name := s.Title
		if name == "" {
			name = s.Pane
		}
		names[i] = fmt.Sprintf("%s (%s)", s.ID, name)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}
