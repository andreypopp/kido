package main

import (
	"encoding/json"
	"errors"
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

// message implements `kido message [--kind K] [--reply-to ID] [--id ID]
// <to>`: it reads text from stdin (the whole input, with one trailing
// newline stripped) and delivers it to the agent to names, resolved by
// resolveTarget within the caller's own tmux session.
//
// --kind is one of message (the default), ask, reply or notice - see
// msg.Kind. A reply must carry --reply-to, naming the ask it answers; an
// ask must not, since it starts a new correlation rather than answering
// one. --id lets the caller assign the envelope's own id instead of
// having one generated: pi's ask_agent tool (pi/kido-agents.ts) needs to
// know an ask's id before sending it, to register what it is waiting for,
// so it generates the id itself and passes it through here. There is no
// `kido ask` CLI twin: a short-lived CLI process has no inbox of its own
// to receive the reply on, only a long-lived extension does, which is why
// ask_agent lives entirely in pi/kido-agents.ts and calls this command
// just to send the question.
//
// An agent that has reported an inbox socket gets it as a real user
// message, in the v1 envelope (internal/msg) when it has advertised that
// protocol, else as v0 raw text - the same contract kido prompt relies
// on. An agent with no inbox at all (Claude Code, or any agent whose
// socket bind failed) gets it pasted into its pane instead, by the same
// deliverInboxOrPaste kido prompt uses; this is refused for any --kind
// other than message, since a paste cannot carry the kind or id an
// ask/reply/notice needs and would otherwise silently arrive as a plain
// prompt.
//
// Returns the process exit code, printing any error to stderr itself.
func message(args []string, stdin io.Reader) int {
	fs := flag.NewFlagSet("message", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	kindFlag := fs.String("kind", string(msg.KindMessage), "kind of envelope: message, ask, reply, or notice")
	replyTo := fs.String("reply-to", "", "id of an earlier ask this message answers")
	idFlag := fs.String("id", "", "id to assign this envelope; a fresh one is generated if omitted")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "kido message:", err)
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: kido message [--kind K] [--reply-to ID] [--id ID] <to>")
		return 1
	}
	to := fs.Arg(0)

	// One dispatch on kind, so what each kind does and does not accept is
	// read off in one place rather than from a chain of conditions that
	// each test it again.
	kind := msg.Kind(*kindFlag)
	switch kind {
	case msg.KindMessage, msg.KindNotice:
	case msg.KindAsk:
		if *replyTo != "" {
			fmt.Fprintln(os.Stderr, "kido message: --kind ask must not have --reply-to; it starts a new correlation, not an answer to one")
			return 1
		}
	case msg.KindReply:
		if *replyTo == "" {
			fmt.Fprintln(os.Stderr, "kido message: --kind reply requires --reply-to")
			return 1
		}
	default:
		fmt.Fprintf(os.Stderr, "kido message: invalid --kind %q, want message, ask, reply, or notice\n", *kindFlag)
		return 1
	}

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

	// A target that has not advertised protocol 1 only ever gets v0 raw
	// text (see the comment above), which has nowhere to carry kind or id;
	// silently downgrading an ask or reply to a plain prompt would strip
	// the very thing that made it one, so it is refused instead.
	if kind != msg.KindMessage && target.Protocol < msg.V1 {
		fmt.Fprintf(os.Stderr, "kido message: %s has not advertised kido's v1 inbox protocol, only message can be sent as v0 text\n", targetLabel(target))
		return 1
	}

	envID := *idFlag
	if envID == "" {
		envID = msg.NewID()
	}
	payload := text
	if target.Protocol >= msg.V1 {
		env := msg.Envelope{
			V:       msg.V1,
			Kind:    kind,
			ID:      envID,
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

	// The advertised-protocol check above is not enough on its own: it
	// reads a record written when the target was alive, and a target that
	// advertised v1 and has since died still passes it. Only the delivery
	// attempt finds the socket gone - and deliverInboxOrPaste answers that
	// by pasting into the pane, which for an agent that is no longer there
	// means typing the text at whatever shell the pane fell back to and
	// pressing Enter. An ask, reply or notice must never take that path: it
	// carries no kind and no id, and for a notice (the completion notice a
	// subagent sends its parent, docs/subagents-plan.md's Lifecycle section)
	// the text is model-authored, so the paste is a command line the model
	// wrote. The plan's rule for that case is that there is nobody to tell,
	// so say so and stop.
	var paste bool
	if kind != msg.KindMessage {
		if err := deliverInbox(target.Inbox, payload); err != nil {
			// errAskRefused and every post-connection failure keep their own
			// wording: "ask refused" in particular is what pi's ask_agent
			// reads back off stderr to tell a cycle refusal from a target
			// that simply is not there.
			if errors.Is(err, errInboxUnavailable) {
				fmt.Fprintf(os.Stderr, "kido message: %s is not listening on its inbox; a %s cannot fall back to a paste\n", targetLabel(target), kind)
			} else {
				fmt.Fprintln(os.Stderr, "kido message:", err)
			}
			return 1
		}
	} else if paste, err = deliverInboxOrPaste(target.Inbox, payload, target.Pane, text); err != nil {
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
	byPane := paneIndex(panes)
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
	byPane := paneIndex(panes)
	scoped := sessionsInSession(states, panes, caller.SessionID)
	if s, found, err := matchTarget(scoped, byPane, to); err != nil {
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
	switch s, found, ambiguous := matchTarget(all, byPane, to); {
	case found && ambiguous != nil:
		return state.Session{}, fmt.Errorf("%w, none in this tmux session", ambiguous)
	case found:
		return state.Session{}, fmt.Errorf("%s (%s) is in another tmux session, not this one", to, s.ID)
	}
	return state.Session{}, fmt.Errorf("no agent session matches %q", to)
}

// matchTarget applies message's addressing rules to a set of candidate
// sessions: an exact case-insensitive name match (Title, falling back to
// the pane's title exactly as displayName/buildAgents in agents.go does -
// otherwise a name shown by kido agents for a session with no reported
// Title would be refused here), then an exact id, then a unique id prefix.
// found reports whether any rule matched at all, so resolveTarget can tell
// "ambiguous" from "look elsewhere". err is non-nil only when a rule's own
// candidates were ambiguous, naming them so the caller can disambiguate.
func matchTarget(sessions []state.Session, byPane map[string]tmux.Pane, to string) (target state.Session, found bool, err error) {
	var byName []state.Session
	for _, s := range sessions {
		if name := displayName(s, byPane); name != "" && strings.EqualFold(name, to) {
			byName = append(byName, s)
		}
	}
	if s, found, err := decide(byName, to, "name"); found {
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
