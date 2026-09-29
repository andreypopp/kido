package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"kido/internal/msg"
	"kido/internal/reap"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

// Overridable via KIDO_STOP_ESCALATION_MS for the e2e suite.
var stopEscalation = msFromEnv("KIDO_STOP_ESCALATION_MS", 5*time.Second)

func msFromEnv(name string, def time.Duration) time.Duration {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n > 0 {
		return time.Duration(n) * time.Millisecond
	}
	return def
}

var stopPollInterval = 100 * time.Millisecond

var killPane = tmux.KillPane

func interruptUsage() string { return "usage: kido interrupt_subagent -- <agent>" }
func stopUsage() string      { return "usage: kido stop_subagent [--force] -- <agent>" }

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
	return send(cmd, sendSpec{kind: msg.KindSteer, to: descendant{fs.Arg(0)}}, stdin)
}

func interruptSubagentCmd(args []string) error {
	fs := flag.NewFlagSet("interrupt_subagent", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, interruptUsage())
	}
	if fs.NArg() != 1 {
		return errors.New(interruptUsage())
	}

	target, states, byPane, err := resolveRecipient(descendant{fs.Arg(0)})
	if err != nil {
		return err
	}
	if _, err := deliverEnvelope(target, states, byPane, sendSpec{kind: msg.KindInterrupt}, ""); err != nil {
		return err
	}
	fmt.Printf("interrupted %s\n", displayName(target, byPane))
	return nil
}

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

	// Before the agent lookup: a bash run has no state record, so resolveTarget
	// would answer "no agent session matches" for a build that is plainly running.
	if run, ok, err := liveBashRun(fs.Arg(0)); err != nil {
		return err
	} else if ok {
		return stopBashRun(run, *force)
	}

	target, states, byPane, err := resolveRecipient(descendant{fs.Arg(0)})
	if err != nil {
		return err
	}

	degrade := func() error {
		// recordStopped runs only once killRunPane's own guard has passed, so
		// a refusal (the session's last pane) leaves no outcome behind.
		killed, err := killRunPane(target.Pane, func() { recordStopped(target) })
		if err != nil {
			return fmt.Errorf("%s %w", displayName(target, byPane), err)
		}
		if killed {
			fmt.Printf("killed %s's pane\n", displayName(target, byPane))
		} else {
			fmt.Printf("%s's pane was already gone\n", displayName(target, byPane))
		}
		return nil
	}

	if target.Inbox == "" {
		if !*force {
			return fmt.Errorf("%s has no inbox to ask nicely over; pass --force to kill its window instead", displayName(target, byPane))
		}
		return degrade()
	}

	// A send error other than msg.ErrInboxUnavailable is a reason to
	// escalate, not to give up: a wedged agent answers late, wrongly, or
	// not at all.
	_, sendErr := deliverEnvelope(target, states, byPane, sendSpec{kind: msg.KindStop}, "")
	if errors.Is(sendErr, msg.ErrInboxUnavailable) {
		if !*force {
			return fmt.Errorf("%s could not be asked to stop (%v); pass --force to kill its window instead", displayName(target, byPane), sendErr)
		}
		return degrade()
	}

	// After every refusal (an outcome is O_EXCL and could never be
	// corrected) and before the wait (so it wins against the child's own
	// Completed a moment later).
	recordStopped(target)

	if waitFor(func() bool {
		s, ok, _ := state.Get(target.ID)
		return !ok || !state.Alive(s.PID)
	}) {
		fmt.Printf("stopped %s\n", displayName(target, byPane))
		return nil
	}

	why := fmt.Sprintf("did not stop within %s", stopEscalation)
	if sendErr != nil {
		why = fmt.Sprintf("did not accept the stop request (%v) and was still there after %s", sendErr, stopEscalation)
	}
	if _, err := killRunPane(target.Pane, nil); err != nil {
		return fmt.Errorf("%s %s, and its pane could not be killed: %w", displayName(target, byPane), why, err)
	}
	fmt.Printf("%s %s; killed its pane\n", displayName(target, byPane), why)
	return nil
}

// waitFor polls cond every stopPollInterval until it reports true or
// stopEscalation elapses since the call, reporting which happened.
func waitFor(cond func() bool) bool {
	deadline := time.Now().Add(stopEscalation)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(stopPollInterval)
	}
	return false
}

// killRunPane refuses a pane that is the only one in its session's only
// window, since killing it would end the session. A pane already gone is
// reported, not an error. beforeKill, if not nil, runs once the guard has
// passed but before the kill, so a caller can record an outcome after
// every refusal and before any kill.
func killRunPane(paneID string, beforeKill func()) (bool, error) {
	panes, err := listPanes()
	if err != nil {
		return false, err
	}
	pane, ok := findPane(panes, paneID)
	if !ok {
		return false, nil
	}
	if tmux.LastWindow(panes, pane.WindowID) && tmux.LastPane(panes, pane.WindowID) {
		return false, errors.New("it is its session's only pane; killing it would destroy the session")
	}
	if beforeKill != nil {
		beforeKill()
	}
	// The pane and not the window, even when it is the window's only one:
	// a stop kills what it was pointed at, and the refusal above is what
	// guards the session.
	if err := releaseOps().Release(reap.Close{WindowID: pane.WindowID, PaneID: pane.PaneID}); err != nil {
		return false, err
	}
	return true, nil
}

func recordStopped(target state.Session) {
	if id, err := subrun.ParseID(target.ID); err == nil {
		subrun.RecordOutcome(id, subrun.Outcome{Result: subrun.Stopped, At: time.Now()}) //nolint:errcheck // best effort
	}
}

const stoppedText = "stopped by kido stop_subagent; its wrapper did not report"

func liveBashRun(to string) (subrun.Meta, bool, error) {
	ids, err := subrun.List()
	if err != nil {
		return subrun.Meta{}, false, err
	}
	var matches []subrun.Meta
	for _, id := range ids {
		meta, err := subrun.ReadMeta(id)
		if err != nil || meta.Kind != subrun.KindBash {
			continue
		}
		if !strings.EqualFold(meta.Name, to) && string(meta.ID) != to {
			continue
		}
		if _, done, err := subrun.ReadOutcome(id); err != nil || done {
			continue
		}
		matches = append(matches, meta)
	}
	switch len(matches) {
	case 0:
		return subrun.Meta{}, false, nil
	case 1:
		if err := bashRunInScope(matches[0]); err != nil {
			return subrun.Meta{}, false, err
		}
		return matches[0], true, nil
	default:
		ids := make([]string, len(matches))
		for i, m := range matches {
			ids[i] = string(m.ID)
		}
		sort.Strings(ids)
		return subrun.Meta{}, false, fmt.Errorf("%q matches several running async runs: %s", to, strings.Join(ids, ", "))
	}
}

func runLabel(name string, id subrun.ID) string {
	if name == "" {
		return string(id)
	}
	return name
}

func bashRunInScope(meta subrun.Meta) error {
	states, err := state.Load()
	if err != nil {
		return err
	}
	self := os.Getenv("TMUX_PANE")
	caller, isAgent := states[self]
	if !isAgent {
		return nil
	}
	if meta.ParentSession == caller.ID {
		return nil
	}
	panes, err := listPanes()
	if err != nil {
		return err
	}
	ok, err := callerReaches(states, panes, self, meta.ParentSession)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("async run %q is not this agent's descendant", runLabel(meta.Name, meta.ID))
	}
	return nil
}

// stopBashRun ends a running `kido async_bash`: signal the wrapper,
// which forwards it to the command and reports the ending itself, and
// only speak for the run if it did not.
func stopBashRun(meta subrun.Meta, force bool) error {
	label := fmt.Sprintf("async run %q", runLabel(meta.Name, meta.ID))
	if !force {
		return fmt.Errorf("%s has no inbox to ask nicely over; pass --force to kill its window instead", label)
	}

	signalled := meta.PID > 0 && syscall.Kill(meta.PID, syscall.SIGTERM) == nil
	if signalled && waitFor(func() bool {
		_, done, _ := subrun.ReadOutcome(meta.ID)
		return done
	}) {
		fmt.Printf("stopped %s; its wrapper reported the ending\n", label)
		return nil
	}

	if n, won := reap.RecordEnding(meta, subrun.Outcome{Result: subrun.Stopped, Text: stoppedText, At: time.Now()}); won {
		if err := n.Send(); err != nil {
			fmt.Fprintln(os.Stderr, "kido stop_subagent:", err)
		}
	}
	killed, err := killRunPane(meta.Pane, nil)
	if err != nil {
		return fmt.Errorf("%s was recorded stopped, but its pane could not be killed: %w", label, err)
	}
	if killed {
		fmt.Printf("stopped %s; killed its pane\n", label)
	} else {
		fmt.Printf("stopped %s; its pane was already gone\n", label)
	}
	return nil
}

func descendantTarget(states map[string]state.Session, panes []tmux.Pane, self, to string) (state.Session, error) {
	target, err := resolveTarget(states, panes, self, to)
	if err != nil {
		return state.Session{}, err
	}
	byPane := paneIndex(panes)
	if target.Pane == self {
		return state.Session{}, fmt.Errorf("%s is this agent", displayName(target, byPane))
	}
	ok, err := callerReaches(states, panes, self, target.ID)
	if err != nil {
		return state.Session{}, err
	}
	if !ok {
		return state.Session{}, fmt.Errorf("%s is not this agent's descendant", displayName(target, byPane))
	}
	return target, nil
}

func callerReaches(states map[string]state.Session, panes []tmux.Pane, self, id string) (bool, error) {
	caller, isAgent := states[self]
	if !isAgent {
		return true, nil
	}
	callerPane, ok := findPane(panes, self)
	if !ok {
		return false, fmt.Errorf("pane %q not found", self)
	}
	parentOf := map[string]string{}
	for _, s := range sessionsInSession(states, panes, callerPane.SessionID) {
		if s.Parent != nil && s.Parent.Session != s.ID {
			parentOf[s.ID] = s.Parent.Session
		}
	}
	return isAncestor(parentOf, caller.ID, id), nil
}
