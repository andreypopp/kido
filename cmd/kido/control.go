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
	"kido/internal/subrun"
	"kido/internal/tmux"
)

// stopEscalation is how long kido stop_subagent waits, after asking a session to
// stop over its inbox, for it to actually go before killing its pane.
// Overridable via KIDO_STOP_ESCALATION_MS for the e2e suite.
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

// killPane is tmux.KillPane, indirected so a test can fake it.
var killPane = tmux.KillPane

func interruptUsage() string { return "usage: kido interrupt_subagent -- <agent>" }
func stopUsage() string      { return "usage: kido stop_subagent [--force] -- <agent>" }

// steerSubagentCmd implements `kido steer_subagent -- <agent>`: it reads
// text from stdin and delivers it to a descendant as a v1 "steer"
// envelope, which the receiving extension hands its model inside the
// running turn rather than queueing for the end of it (docs/design.md,
// "Steer and followUp").
//
// It lives here, beside interrupt and stop, rather than beside the
// message-sending commands whose body it shares: what decides which
// three commands are spelled _subagent is this file's rule, that a
// caller may only act on its own descendants. Steering is the same axis
// as interrupting with less force - it redirects work already underway -
// and a steer anyone could send while an interrupt is a descendant's
// alone would be incoherent.
//
// Unlike its neighbours it returns an exit code rather than an error:
// it carries text, so it goes through send (message_agent.go), which
// reports for itself the way every other stdin-reading command does.
func steerSubagentCmd(args []string, stdin io.Reader) int {
	const cmd = "steer_subagent"
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		fmt.Fprintf(os.Stderr, "kido %s: %v\n", cmd, err)
		return 1
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: kido steer_subagent -- <agent>")
		return 1
	}
	return send(cmd, sendSpec{kind: msg.KindSteer, to: fs.Arg(0), descendantsOnly: true}, stdin)
}

// interruptSubagentCmd implements `kido interrupt_subagent -- <agent>`: abort the target's
// current turn without ending its session, as a v1 "interrupt" envelope
// over its inbox. Unlike stop it has no escalation: there is no
// destructive fallback that means "redirect this, do not kill it".
func interruptSubagentCmd(args []string) error {
	fs := flag.NewFlagSet("interrupt_subagent", flag.ContinueOnError)
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

// stopSubagentCmd implements `kido stop_subagent [--force] -- <agent>`: ask over the inbox,
// wait up to stopEscalation for the session's record to go, and kill its
// pane if it has not. A target that cannot be asked at all degrades
// straight to the kill, which needs --force. docs/design.md, "Interrupt
// and stop".
func stopSubagentCmd(args []string) error {
	fs := flag.NewFlagSet("stop_subagent", flag.ContinueOnError)
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

	// killTargetPane records the run's outcome itself.
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

	// A send error other than errInboxUnavailable is a reason to escalate,
	// not to give up: a wedged agent answers late, wrongly, or not at all.
	sendErr := sendControl(target, states, msg.KindStop)
	if errors.Is(sendErr, errInboxUnavailable) {
		if !*force {
			return fmt.Errorf("%s could not be asked to stop (%v); pass --force to kill its window instead", targetLabel(target), sendErr)
		}
		return degrade()
	}

	// After every refusal (an outcome is O_EXCL and could never be
	// corrected) and before the wait (so it wins against the child's own
	// Completed a moment later).
	recordStopped(target)

	deadline := time.Now().Add(stopEscalation)
	for time.Now().Before(deadline) {
		if s, ok, _ := state.Get(target.ID); !ok || !state.Alive(s.PID) {
			fmt.Printf("stopped %s\n", targetLabel(target))
			return nil
		}
		time.Sleep(stopPollInterval)
	}

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

// killTargetPane kills target's own pane, not its window, so a bystander
// pane sharing the window survives. It refuses a pane that is the only
// one in its session's only window, since killing it would end the
// session; it deliberately does not refuse a focused window, because a
// stop was asked for by name. The caller says which path got here.
func killTargetPane(target state.Session) error {
	panes, err := listPanes()
	if err != nil {
		return err
	}
	pane, ok := findPane(panes, target.Pane)
	if !ok {
		return fmt.Errorf("no pane found for %s", targetLabel(target))
	}
	// This guard cannot fire through kido stop_subagent today: controlTarget keeps
	// the caller's own pane in the target's session, so one of the two is
	// always false. It stays as defence for a future caller that reaches a
	// target without a live caller pane in the same session.
	if tmux.LastWindow(panes, pane.WindowID) && tmux.LastPane(panes, pane.WindowID) {
		return fmt.Errorf("%s is its session's only pane; killing it would destroy the session", targetLabel(target))
	}
	// After the refusal, before the kill (see stopCmd).
	recordStopped(target)
	return killPane(pane.PaneID)
}

// recordStopped marks target's run stopped, if it has one: target.ID is
// a run id exactly when kido spawn_subagent created the target. Best-effort, since
// the common case is a target with no run record at all.
func recordStopped(target state.Session) {
	subrun.RecordOutcome(target.ID, subrun.Outcome{Result: subrun.Stopped, At: time.Now()}) //nolint:errcheck // best effort
}

// controlTarget resolves interrupt/stop's argument, reading the state
// the rule is applied to. steer_subagent shares the rule but not this
// read: it has both views in hand already (send, message_agent.go).
func controlTarget(to string) (target state.Session, states map[string]state.Session, err error) {
	states, err = state.Load()
	if err != nil {
		return state.Session{}, nil, err
	}
	panes, err := listPanes()
	if err != nil {
		return state.Session{}, nil, err
	}
	target, err = descendantTarget(states, panes, os.Getenv("TMUX_PANE"), to)
	if err != nil {
		return state.Session{}, nil, err
	}
	return target, states, nil
}

// descendantTarget resolves to the way kido message_agent does and then
// enforces the scope rule every _subagent command shares: a caller with a
// state record of its own may only reach its descendants; a human at the
// CLI, who has none, may act on anything. It is one predicate for the
// three commands named after it, so "descendant" cannot come to mean
// three slightly different things.
//
// Descendant, not child: nesting goes two deep, so a grandchild is
// reachable and isAncestor (list_agents.go) is the walk that says so.
//
// This is a semantic boundary and not a safeguard. Trust is uid-scoped
// (docs/design.md, the inbox): any process that can reach the socket can
// write an envelope claiming to be anyone, so what this buys is a
// coherent vocabulary, not protection.
func descendantTarget(states map[string]state.Session, panes []tmux.Pane, self, to string) (state.Session, error) {
	target, err := resolveTarget(states, panes, self, to)
	if err != nil {
		return state.Session{}, err
	}
	if target.Pane == self {
		return state.Session{}, fmt.Errorf("%s is this agent", targetLabel(target))
	}

	callerRecord, isAgent := states[self]
	if !isAgent {
		return target, nil
	}
	callerPane, ok := findPane(panes, self)
	if !ok {
		return state.Session{}, fmt.Errorf("pane %q not found", self)
	}
	agents := buildAgents(states, panes, callerPane.SessionID, self)
	if !isAncestor(agents, callerRecord.ID, target.ID) {
		return state.Session{}, fmt.Errorf("%s is not this agent's descendant", targetLabel(target))
	}
	return target, nil
}

// sendControl delivers a control-kind envelope (interrupt or stop) to
// target's inbox, gated on the same v1 advertisement message_agent
// requires for any non-message kind. There is deliberately no version
// gate beyond that (docs/design.md, "v0 and v1").
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
	// "refused" for a control kind is the receiver's scope check saying
	// no, not the ask-cycle rule errAskRefused's text describes.
	if err := deliverInbox(target.Inbox, string(raw)); err != nil {
		if errors.Is(err, errAskRefused) {
			return fmt.Errorf("%s refused the %s", targetLabel(target), kind)
		}
		return err
	}
	return nil
}
