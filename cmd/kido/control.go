package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/tmux"
)

// stopEscalation is how long kido stop waits, after asking a session to
// stop over its inbox, for it to actually go before killing its window
// instead. A wedged child will not answer - a real pi has sat alive and
// blocked for hours after a laptop slept and its provider connection
// died - so stop is only reliable when it does not just trust a request
// was received. Read from the environment, the same reason
// internal/reap.Grace is: a unit test can reassign the package variable
// directly, but the e2e suite drives kido as a separately built binary,
// and only the environment reaches that.
var stopEscalation = escalationFromEnv(5 * time.Second)

func escalationFromEnv(def time.Duration) time.Duration {
	if n, err := strconv.Atoi(os.Getenv("KIDO_STOP_ESCALATION_MS")); err == nil && n > 0 {
		return time.Duration(n) * time.Millisecond
	}
	return def
}

// stopPollInterval is how often stopCmd checks whether the target has
// gone, while waiting out stopEscalation.
var stopPollInterval = 100 * time.Millisecond

// killPane is tmux.KillPane, indirected the same way killWindow
// (closewindow.go) is, so a test can fake it instead of talking to a
// real tmux server.
var killPane = tmux.KillPane

func interruptUsage() string { return "usage: kido interrupt <agent>" }
func stopUsage() string      { return "usage: kido stop <agent> [--force]" }

// interruptCmd implements `kido interrupt <agent>`: abort the target's
// current turn without ending its session, so it stays alive and idle,
// ready for a corrected instruction. Delivered as a v1 "interrupt"
// envelope over the target's inbox; pi's extension answers it with
// ctx.abort() (see docs/subagents-plan.md and pi's "ctx.isIdle() /
// ctx.abort() / ctx.hasPendingMessages()" section).
//
// Unlike kido stop, an interrupt has no escalation: aborting a turn is
// meaningless to anything that cannot receive it, and there is no
// destructive fallback that makes sense for "redirect this, do not kill
// it" the way there is for "end this session".
func interruptCmd(args []string) error {
	fs := flag.NewFlagSet("interrupt", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, interruptUsage())
	}
	if fs.NArg() != 1 {
		return errors.New(interruptUsage())
	}

	target, states, err := controlTarget(fs.Arg(0))
	if err != nil {
		return err
	}
	if err := sendControl(target, states, msg.KindInterrupt); err != nil {
		return err
	}
	fmt.Printf("interrupted %s\n", targetLabel(target))
	return nil
}

// stopCmd implements `kido stop <agent> [--force]`: end the target's
// session outright. It asks over the inbox first, exactly like interrupt,
// then waits up to stopEscalation for the session's own record to go
// (pi's session_shutdown handler removes it, the same teardown phase 6
// built for a normal exit - see docs/subagents-plan.md's Lifecycle
// section) and kills its window if it has not.
//
// An agent with no inbox at all cannot be asked anything, so stopping one
// degrades straight to killing its pane - destructive and irreversible,
// the opposite of kido message's paste fallback, where degrading silently
// was the whole point (an agent that cannot speak the inbox protocol
// still gets its prompt some other way). Here there is no gentler "some
// other way": killing the window ends the session outright with no
// chance for the agent to clean up, so it is refused unless --force says
// the caller means it.
func stopCmd(args []string) error {
	fs := flag.NewFlagSet("stop", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	force := fs.Bool("force", false, "kill the target's window directly when it has no inbox to ask nicely over")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, stopUsage())
	}
	if fs.NArg() != 1 {
		return errors.New(stopUsage())
	}

	target, states, err := controlTarget(fs.Arg(0))
	if err != nil {
		return err
	}

	// Both --force degrades below are the same act, and neither is an
	// escalation: nothing was asked, so the pane is all there is.
	degrade := func() error {
		if err := killTargetPane(target); err != nil {
			return err
		}
		fmt.Printf("killed %s's pane\n", targetLabel(target))
		return nil
	}

	if target.Inbox == "" {
		if !*force {
			return fmt.Errorf("%s has no inbox to ask nicely over; pass --force to kill its window instead", targetLabel(target))
		}
		return degrade()
	}

	// sendErr is carried past this switch rather than returned, because
	// "the target did not agree to stop" is the escalation's whole reason
	// for existing, not a reason to give up: a wedged agent answers late,
	// wrongly, or not at all, and an earlier draft that returned here left
	// stop failing outright in exactly the case it was written for. Only
	// errInboxUnavailable is different - nothing was asked and nothing
	// ever could be, which is the same position as having no inbox at all
	// and carries the same --force requirement.
	sendErr := sendControl(target, states, msg.KindStop)
	if errors.Is(sendErr, errInboxUnavailable) {
		if !*force {
			return fmt.Errorf("%s could not be asked to stop (%v); pass --force to kill its window instead", targetLabel(target), sendErr)
		}
		// Same degrade as the no-inbox case above: a recorded socket that
		// turns out to be stale is functionally no inbox at all.
		return degrade()
	}

	deadline := time.Now().Add(stopEscalation)
	for time.Now().Before(deadline) {
		if s, ok, _ := state.Get(target.ID); !ok || !state.Alive(s.PID) {
			fmt.Printf("stopped %s\n", targetLabel(target))
			return nil
		}
		time.Sleep(stopPollInterval)
	}

	// why says what the wait was waiting on, so a kill that followed a
	// refused or unanswered request does not read as though the target had
	// simply taken too long over one it accepted.
	why := fmt.Sprintf("did not stop within %s", stopEscalation)
	if sendErr != nil {
		why = fmt.Sprintf("did not accept the stop request (%v) and was still there after %s", sendErr, stopEscalation)
	}
	if err := killTargetPane(target); err != nil {
		return fmt.Errorf("%s %s, and its pane could not be killed: %w", targetLabel(target), why, err)
	}
	fmt.Printf("%s %s; killed its pane\n", targetLabel(target), why)
	return nil
}

// killTargetPane kills target's own pane, not its window - the escalation
// stopCmd falls back to, and the forced degrade for an inbox-less or
// unreachable target. Killing the window, as an earlier draft did, would
// take every bystander pane sharing it down too; a stop was asked against
// one agent, not against whatever else happens to share its window. It
// reports what happened through its error alone; the caller says which of
// the two paths it was, since "killed" and "did not stop in time, so
// killed" are different things to tell a human.
//
// Killing a window's last pane closes the window as tmux's own
// consequence, so the guard closeWindowCmd applies to a whole window
// still has to apply here: a target whose pane is the only one in its
// session's only window is refused, for the same reason - kill-window (or
// this pane kill's equivalent effect) on the last window ends the session
// itself and every client attached to it, which is never what stopping
// one agent asked for. A pane sharing its window with another is never
// refused on this basis, whatever else is true of the window: killing it
// leaves the window, and the session, standing. The focused-window
// refusal close-window and the reap sweep share is deliberately not
// repeated here - those two act on their own initiative and must not take
// a screen away from a user who may be reading it, while a stop was asked
// for by name and against a pane that is still alive.
func killTargetPane(target state.Session) error {
	panes, err := listPanes()
	if err != nil {
		return err
	}
	pane, ok := findPane(panes, target.Pane)
	if !ok {
		return fmt.Errorf("no pane found for %s", targetLabel(target))
	}
	if tmux.LastWindow(panes, pane.WindowID) && tmux.LastPane(panes, pane.WindowID) {
		return fmt.Errorf("%s is its session's only pane; killing it would destroy the session", targetLabel(target))
	}
	return killPane(pane.PaneID)
}

// controlTarget resolves interrupt/stop's argument the same way kido
// message's resolveTarget does, and enforces their shared scope rule: a
// caller that is itself an agent (one with its own state record) may only
// reach its own descendants, so a confused peer cannot interrupt or stop
// something unrelated to it; a human at the CLI, who has no such record,
// may act on anything. This is not a security boundary - trust is
// uid-scoped and `from` is advisory, as AGENTS.md records - it exists
// only to keep an agent inside the part of the tree it owns.
func controlTarget(to string) (target state.Session, states map[string]state.Session, err error) {
	states, err = state.Load()
	if err != nil {
		return state.Session{}, nil, err
	}
	panes, err := listPanes()
	if err != nil {
		return state.Session{}, nil, err
	}
	self := os.Getenv("TMUX_PANE")
	target, err = resolveTarget(states, panes, self, to)
	if err != nil {
		return state.Session{}, nil, err
	}
	if target.Pane == self {
		return state.Session{}, nil, fmt.Errorf("%s is this agent", targetLabel(target))
	}

	callerRecord, isAgent := states[self]
	if !isAgent {
		return target, states, nil // a human at the CLI may act on anything
	}
	callerPane, ok := findPane(panes, self)
	if !ok {
		return state.Session{}, nil, fmt.Errorf("pane %q not found", self)
	}
	agents := buildAgents(states, panes, callerPane.SessionID, self)
	if !isAncestor(agents, callerRecord.ID, target.ID) {
		return state.Session{}, nil, fmt.Errorf("%s is not this agent's descendant", targetLabel(target))
	}
	return target, states, nil
}

// sendControl delivers a control-kind envelope (interrupt or stop) to
// target's inbox, gated on the same v1 advertisement kido message
// requires for any non-message kind: a target that has not advertised
// protocol 1 only ever speaks v0 raw text, which has nowhere to carry a
// kind, and a receiver that has not been upgraded past v0 would show the
// model the envelope's literal JSON as its next prompt.
//
// There is deliberately no protocol 2 or version gate specific to
// interrupt/stop: kido runs on one machine with the binary and the
// extension upgraded together, so a version negotiation here would be
// ceremony over a risk that does not exist for stop (a stale extension
// that does not recognise the kind still leaves the session alive, and
// stopCmd's escalation kills its window regardless) and that this v1
// gate already covers for interrupt (a target that has never spoken v1 is
// refused outright, the same as for ask/reply/notice).
func sendControl(target state.Session, states map[string]state.Session, kind msg.Kind) error {
	if target.Inbox == "" {
		return fmt.Errorf("%w: %s has no inbox", errInboxUnavailable, targetLabel(target))
	}
	if target.Protocol < msg.V1 {
		return fmt.Errorf("%s has not advertised kido's v1 inbox protocol", targetLabel(target))
	}
	env := msg.Envelope{V: msg.V1, Kind: kind, ID: msg.NewID(), From: senderOf(states)}
	raw, err := json.Marshal(env)
	if err != nil {
		return err
	}
	// "refused" on the wire means "read, and deliberately declined", which
	// for a control kind is the receiver's own scope check saying no - not
	// the ask-cycle rule errAskRefused's text describes. Reported as what
	// it actually is, or a refused interrupt explains itself with a
	// sentence about outstanding asks.
	if err := deliverInbox(target.Inbox, string(raw)); err != nil {
		if errors.Is(err, errAskRefused) {
			return fmt.Errorf("%s refused the %s", targetLabel(target), kind)
		}
		return err
	}
	return nil
}
