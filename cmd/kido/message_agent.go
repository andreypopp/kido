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
	"kido/internal/subrun"
	"kido/internal/tmux"
)

var listPanes = tmux.ListPanes

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
	kind := msg.KindMessage
	if *replyTo != "" {
		kind = msg.KindReply
	}
	return send(cmd, sendSpec{kind: kind, to: named{fs.Arg(0)}, replyTo: *replyTo}, stdin)
}

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
	return send(cmd, sendSpec{kind: msg.KindAsk, to: named{fs.Arg(0)}, id: *idFlag}, stdin)
}

func notifyParentCmd(args []string, stdin io.Reader) int {
	const cmd = "notify_parent"
	if len(args) > 0 {
		fmt.Fprintln(os.Stderr, "usage: kido notify_parent (the parent comes from $KIDO_AGENT_PARENT_SESSION, not from an argument)")
		return 1
	}
	parent := os.Getenv("KIDO_AGENT_PARENT_SESSION")
	if parent == "" {
		fmt.Fprintf(os.Stderr, "kido %s: this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent\n", cmd)
		return 1
	}
	b, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kido %s: %v\n", cmd, err)
		return 1
	}
	runID, _ := subrun.ParseID(os.Getenv("KIDO_AGENT_RUN_ID"))
	notice, _, err := reportNotice(strings.TrimSuffix(string(b), "\n"), runID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kido %s: keeping the whole report failed (%v); sending a truncated one\n", cmd, err)
	}
	return send(cmd, sendSpec{kind: msg.KindNotice, to: parentRecipient{parent}}, strings.NewReader(notice))
}

type recipient interface {
	resolve(live []state.Session, panes []tmux.Pane, self string) (state.Session, error)
}

type named struct{ to string }

func (n named) resolve(live []state.Session, panes []tmux.Pane, self string) (state.Session, error) {
	return resolveTarget(state.ByPane(live), panes, self, n.to)
}

type descendant struct{ to string }

func (d descendant) resolve(live []state.Session, panes []tmux.Pane, self string) (state.Session, error) {
	return descendantTarget(state.ByPane(live), panes, self, d.to)
}

type parentRecipient struct{ session string }

func (p parentRecipient) resolve(live []state.Session, _ []tmux.Pane, _ string) (state.Session, error) {
	target, ok := state.Find(live, p.session)
	if !ok {
		return state.Session{}, fmt.Errorf("no live process holds session %q; the parent is gone, nothing sent", p.session)
	}
	return target, nil
}

type sendSpec struct {
	kind     msg.Kind
	to       recipient
	replyTo  string
	id       string
	fromName string
}

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
	// writes the bytes through, so invalid UTF-8 would arrive differently by path.
	if !utf8.ValidString(text) {
		return fail("message is not valid UTF-8")
	}

	live, err := state.LoadLive()
	if err != nil {
		return fail(err)
	}
	states := state.ByPane(live)
	panes, err := listPanes()
	if err != nil {
		return fail(err)
	}
	byPane := paneIndex(panes)
	self := os.Getenv("TMUX_PANE")

	// An ask whose caller cannot be answered is refused rather than delivered:
	// the target would spend a turn on a question with nowhere to send the answer.
	if spec.kind == msg.KindAsk {
		const alternative = "use kido message_agent instead, which is one-way and needs no reply"
		caller, ok := states[self]
		if !ok {
			return fail(fmt.Sprintf("no live agent session on this pane (%s), so an answer could not be addressed back here; nothing sent - %s", self, alternative))
		}
		if caller.Inbox == "" {
			return fail(fmt.Sprintf("%s has no inbox for an answer to arrive on, and only a long-lived process has one; nothing sent - %s", displayName(caller, byPane), alternative))
		}
	}

	target, err := spec.to.resolve(live, panes, self)
	if err != nil {
		return fail(err)
	}
	if target.Pane == self {
		return fail(fmt.Sprintf("%s is this agent", displayName(target, byPane)))
	}

	paste, err := deliverEnvelope(target, states, byPane, spec, text)
	if err != nil {
		return fail(err)
	}
	if paste {
		fmt.Printf("pasted into %s's pane\n", displayName(target, byPane))
	} else {
		fmt.Printf("delivered to %s by inbox\n", displayName(target, byPane))
	}
	return 0
}

func resolveRecipient(to recipient) (state.Session, map[string]state.Session, map[string]tmux.Pane, error) {
	live, err := state.LoadLive()
	if err != nil {
		return state.Session{}, nil, nil, err
	}
	states := state.ByPane(live)
	panes, err := listPanes()
	if err != nil {
		return state.Session{}, nil, nil, err
	}
	target, err := to.resolve(live, panes, os.Getenv("TMUX_PANE"))
	return target, states, paneIndex(panes), err
}

func deliverEnvelope(target state.Session, states map[string]state.Session, byPane map[string]tmux.Pane, spec sendSpec, text string) (bool, error) {
	if spec.kind != msg.KindMessage && target.Inbox == "" {
		return false, fmt.Errorf("%s has no inbox to send a %s to; only a plain message can be sent as v0 text", displayName(target, byPane), spec.kind)
	}

	envID := spec.id
	if envID == "" {
		envID = msg.NewID()
	}
	from := senderOf(states)
	if spec.fromName != "" {
		from = msg.From{Name: spec.fromName}
	}
	payload := text
	if target.Inbox != "" {
		env := msg.Envelope{
			V:       msg.V1,
			Kind:    spec.kind,
			ID:      envID,
			From:    from,
			ReplyTo: spec.replyTo,
			Text:    text,
		}
		raw, err := json.Marshal(env)
		if err != nil {
			return false, err
		}
		payload = string(raw)
	}

	if spec.kind != msg.KindMessage {
		if err := msg.Deliver(target.Inbox, payload); err != nil {
			if errors.Is(err, msg.ErrAskRefused) {
				return false, fmt.Errorf("%s refused the %s", displayName(target, byPane), spec.kind)
			}
			// "ask refused" keeps its wording above: pi's ask_agent reads it
			// back off stderr to tell a cycle refusal from an absent target.
			if errors.Is(err, msg.ErrInboxUnavailable) {
				return false, fmt.Errorf("%s is not listening on its inbox; a %s cannot fall back to a paste: %w", displayName(target, byPane), spec.kind, err)
			}
			return false, err
		}
		return false, nil
	}
	return deliverInboxOrPaste(target.Inbox, payload, target.Pane, text)
}

func senderOf(states map[string]state.Session) msg.From {
	pane := os.Getenv("TMUX_PANE")
	self, ok := states[pane]
	if !ok {
		return msg.From{Pane: pane}
	}
	return msg.From{Session: self.ID, Name: self.Title, Pane: pane}
}

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

func matchTarget(sessions []state.Session, byPane map[string]tmux.Pane, to string) (target state.Session, found bool, err error) {
	var byName []state.Session
	for _, s := range sessions {
		if name := displayName(s, byPane); name != "" && strings.EqualFold(name, to) {
			byName = append(byName, s)
		}
	}
	if s, found, err := decide(byName, byPane, to, "name"); found {
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
	return decide(byPrefix, byPane, to, "id")
}

func decide(candidates []state.Session, byPane map[string]tmux.Pane, to, by string) (state.Session, bool, error) {
	switch len(candidates) {
	case 0:
		return state.Session{}, false, nil
	case 1:
		return candidates[0], true, nil
	default:
		return state.Session{}, true, fmt.Errorf("%q matches several agents by %s: %s", to, by, describeCandidates(candidates, byPane))
	}
}

func describeCandidates(sessions []state.Session, byPane map[string]tmux.Pane) string {
	names := make([]string, len(sessions))
	for i, s := range sessions {
		names[i] = fmt.Sprintf("%s (%s)", s.ID, displayName(s, byPane))
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}
