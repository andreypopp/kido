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
// pane list instead of talking to a tmux server.
var listPanes = tmux.ListPanes

// message implements `kido message [--kind K] [--reply-to ID] [--id ID]
// <to>`: it reads text from stdin (one trailing newline stripped) and
// delivers it to the agent to names, resolved within the caller's own
// tmux session. A reply must carry --reply-to and an ask must not; --id
// lets pi's ask_agent assign the id it registers a waiter under before
// sending. Delivery, the v0/v1 choice and when a paste is allowed are in
// docs/design.md.
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
	// The inbox marshals into JSON (which substitutes U+FFFD) while a paste
	// writes the bytes through, so the same message would arrive
	// differently by path.
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
	// list_agents reports the caller alongside everyone else, so a model
	// can pick its own name and hand itself its message as a fresh turn.
	if target.Pane == self {
		fmt.Fprintf(os.Stderr, "kido message: %s is this agent\n", targetLabel(target))
		return 1
	}

	// v0 text has nowhere to carry a kind or an id.
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

	// A non-message kind never pastes: the protocol check above reads a
	// record written while the target was alive, and a dead target's pane
	// is a shell that would run the pasted text as a command line.
	var paste bool
	if kind != msg.KindMessage {
		if err := deliverInbox(target.Inbox, payload); err != nil {
			// "ask refused" keeps its wording: pi's ask_agent reads it back
			// off stderr to tell a cycle refusal from an absent target.
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
// found by its pane ($TMUX_PANE); a pane with no record sends only Pane.
func senderOf(states map[string]state.Session) msg.From {
	pane := os.Getenv("TMUX_PANE")
	self, ok := states[pane]
	if !ok {
		return msg.From{Pane: pane}
	}
	return msg.From{Session: self.ID, Name: self.Title, Pane: pane}
}

// sessionsInSession is every state.Session whose pane is currently in
// tmux session, per a fresh pane list: a record names a pane and nothing
// above it, since a pane can move between sessions while its process
// runs.
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

// resolveTarget finds the agent to names, scoped to the caller's own tmux
// session. An agent in another session is reported as such rather than
// as not found. The addressing rules are matchTarget's.
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

	// Nothing in scope: check the rest of the world so the error can say
	// why. An ambiguity out there is reported as one: matchTarget returns
	// a zero session for it, so naming its id would print an empty one.
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

// matchTarget applies the addressing rules to a set of candidate
// sessions, in order, each erroring on its own ambiguity rather than
// falling through: an exact case-insensitive name (displayName, so a name
// shown by kido agents always resolves back), then an exact id, then a
// unique id prefix. found reports whether any rule matched at all, so
// resolveTarget can tell "ambiguous" from "look elsewhere".
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
// ambiguity error naming them. by is the rule they matched on.
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
