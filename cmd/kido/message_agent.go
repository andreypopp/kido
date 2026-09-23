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

// messageAgentCmd implements `kido message_agent [--reply-to ID] -- <to>`:
// it reads text from stdin (one trailing newline stripped) and delivers
// it to the agent to names, resolved within the caller's own tmux
// session. Delivery, the v0/v1 choice and when a paste is allowed are in
// docs/design.md.
//
// Returns the process exit code, printing any error to stderr itself.
func messageAgentCmd(args []string, stdin io.Reader) int {
	const cmd = "message_agent"
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	replyTo := fs.String("reply-to", "", "id of an earlier ask this message answers")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "kido %s: %v\n", cmd, err)
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: kido message_agent [--reply-to ID] -- <to>")
		return 1
	}
	// --reply-to alone picks the kind. The wire still correlates a reply on
	// kind "reply" (internal/msg), but there is nothing else --reply-to
	// could mean, and asking a caller to spell both was exactly the
	// redundancy this command surface exists to remove.
	kind := msg.KindMessage
	if *replyTo != "" {
		kind = msg.KindReply
	}
	return send(cmd, sendSpec{kind: kind, to: fs.Arg(0), replyTo: *replyTo}, stdin)
}

// askAgentCmd implements `kido ask_agent [--id ID] -- <to>`: the same
// delivery as message_agent, as an "ask" envelope. --id lets pi's
// ask_agent assign the id it registers a waiter under before sending;
// nothing here waits for the answer, which arrives on the asker's own
// inbox and so only reaches a long-lived process (docs/design.md, "Ask
// and reply").
func askAgentCmd(args []string, stdin io.Reader) int {
	const cmd = "ask_agent"
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	idFlag := fs.String("id", "", "id to assign this envelope; a fresh one is generated if omitted")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "kido %s: %v\n", cmd, err)
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: kido ask_agent [--id ID] -- <to>")
		return 1
	}
	return send(cmd, sendSpec{kind: msg.KindAsk, to: fs.Arg(0), id: *idFlag}, stdin)
}

// notifyParentCmd implements `kido notify_parent`: it sends stdin to the
// agent that spawned this one as a "notice" envelope, and takes no
// target. The parent comes from KIDO_AGENT_PARENT_INSTANCE, the parent
// edge kido spawn_subagent itself put in the child's environment
// (docs/design.md, "Identity"), so a child reporting home names nobody -
// and cannot name anybody else. pi's notify_parent tool used to list the
// agents, find its own row and read `parent` off it to hand back to kido;
// that round trip asked a display for a fact kido had already given the
// process.
//
// A session with no such variable is a root session with nobody to tell,
// which is a clear refusal rather than a silent success.
func notifyParentCmd(args []string, stdin io.Reader) int {
	const cmd = "notify_parent"
	if len(args) > 0 {
		fmt.Fprintln(os.Stderr, "usage: kido notify_parent (the parent comes from $KIDO_AGENT_PARENT_INSTANCE, not from an argument)")
		return 1
	}
	instance := os.Getenv("KIDO_AGENT_PARENT_INSTANCE")
	if instance == "" {
		fmt.Fprintf(os.Stderr, "kido %s: this session has no parent ($KIDO_AGENT_PARENT_INSTANCE is not set); nothing sent\n", cmd)
		return 1
	}
	return send(cmd, sendSpec{kind: msg.KindNotice, parentInstance: instance}, stdin)
}

// sendSpec is one outbound envelope as its command described it: the
// kind, who it goes to - an address to resolve (to) or the parent's
// instance id (parentInstance), never both - and the correlation ids that
// kind allows.
type sendSpec struct {
	kind           msg.Kind
	to             string
	parentInstance string
	replyTo        string
	id             string
}

// send is the body every message-sending command shares: read the text,
// resolve the target, deliver. cmd names the calling subcommand, for the
// errors it prints to stderr. It returns the process exit code.
func send(cmd string, spec sendSpec, stdin io.Reader) int {
	fail := func(what any) int {
		fmt.Fprintf(os.Stderr, "kido %s: %v\n", cmd, what)
		return 1
	}

	b, err := io.ReadAll(stdin)
	if err != nil {
		return fail(err)
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
		return fail("message is not valid UTF-8")
	}

	// One read, two views of it: the per-pane map for the sender's own
	// record and for resolving an address, and the whole live slice for
	// finding a parent by instance - the question `kido agent-alive` asks
	// of the same registry, and for its reason, since a pane collision
	// drops a record from the per-pane view and a parent's is exactly the
	// record that gets dropped.
	live, err := state.LoadLive()
	if err != nil {
		return fail(err)
	}
	states := state.ByPane(live)
	panes, err := listPanes()
	if err != nil {
		return fail(err)
	}
	self := os.Getenv("TMUX_PANE")

	var target state.Session
	if spec.parentInstance != "" {
		found := false
		for _, s := range live {
			if s.Instance == spec.parentInstance {
				target, found = s, true
				break
			}
		}
		if !found {
			return fail(fmt.Sprintf("no live agent reports instance %q; the parent is gone, nothing sent", spec.parentInstance))
		}
	} else if target, err = resolveTarget(states, panes, self, spec.to); err != nil {
		return fail(err)
	}
	// list_agents reports the caller alongside everyone else, so a model
	// can pick its own name and hand itself its message as a fresh turn.
	if target.Pane == self {
		return fail(fmt.Sprintf("%s is this agent", targetLabel(target)))
	}

	// v0 text has nowhere to carry a kind or an id.
	if spec.kind != msg.KindMessage && target.Protocol < msg.V1 {
		return fail(fmt.Sprintf("%s has not advertised kido's v1 inbox protocol, only a plain message can be sent as v0 text", targetLabel(target)))
	}

	envID := spec.id
	if envID == "" {
		envID = msg.NewID()
	}
	payload := text
	if target.Protocol >= msg.V1 {
		env := msg.Envelope{
			V:       msg.V1,
			Kind:    spec.kind,
			ID:      envID,
			From:    senderOf(states),
			ReplyTo: spec.replyTo,
			Text:    text,
		}
		raw, err := json.Marshal(env)
		if err != nil {
			return fail(err)
		}
		payload = string(raw)
	}

	// A non-message kind never pastes: the protocol check above reads a
	// record written while the target was alive, and a dead target's pane
	// is a shell that would run the pasted text as a command line.
	var paste bool
	if spec.kind != msg.KindMessage {
		if err := deliverInbox(target.Inbox, payload); err != nil {
			// "ask refused" keeps its wording: pi's ask_agent reads it back
			// off stderr to tell a cycle refusal from an absent target.
			if errors.Is(err, errInboxUnavailable) {
				return fail(fmt.Sprintf("%s is not listening on its inbox; a %s cannot fall back to a paste", targetLabel(target), spec.kind))
			}
			return fail(err)
		}
	} else if paste, err = deliverInboxOrPaste(target.Inbox, payload, target.Pane, text); err != nil {
		return fail(err)
	}
	if paste {
		fmt.Printf("pasted into %s's pane\n", targetLabel(target))
	} else {
		fmt.Printf("delivered to %s by inbox\n", targetLabel(target))
	}
	return 0
}

// targetLabel names a session for a human (or a model) reading a send's
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
// as not found. The addressing rules are matchTarget's. notify_parent
// does not come through here: it holds an instance id rather than an
// address, and resolves it against the whole live registry (see send).
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
// shown by kido list_agents always resolves back), then an exact id, then a
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
