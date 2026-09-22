package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"text/tabwriter"
	"time"

	"kido/internal/state"
	"kido/internal/tmux"
	"kido/internal/tree"
)

// AgentInfo is one row of `kido agents`, and what pi's list_agents tool
// reports verbatim as JSON.
type AgentInfo struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Agent      string `json:"agent"`
	Pane       string `json:"pane"`
	Window     string `json:"window"`
	Status     string `json:"status"`
	Activity   string `json:"activity"`
	Parent     string `json:"parent"`
	Depth      int    `json:"depth"`
	Self       bool   `json:"self"`
	Cwd        string `json:"cwd"`
	CanMessage bool   `json:"canMessage"`
	Model      string `json:"model"`
	// SinceReport is seconds since the session's last report
	// (state.Session.TS), derived at list time rather than stored: it is
	// only ever meaningful as of now. It measures staleness, not idle time -
	// a session reporting Running has a SinceReport too, and that is exactly
	// what Stalled is derived from.
	SinceReport int `json:"sinceReport"`
	// Stalled is state.Stalled(s, now): the session claims to be running
	// but has gone quiet for longer than state.StallThreshold, kido's own
	// guess that it is wedged rather than merely busy. ask_agent refuses a
	// stalled target immediately instead of waiting out its own timeout.
	Stalled bool `json:"stalled"`
}

func agentsUsage() string {
	return "usage: kido agents [--session ID] [--json]"
}

// agentsCmd implements `kido agents [--session ID] [--json]`: every agent
// in a tmux session, defaulting to the session holding the caller's own
// pane ($TMUX_PANE).
func agentsCmd(args []string) error {
	fs := flag.NewFlagSet("agents", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	session := fs.String("session", "", "tmux session id to list; defaults to the caller's own session")
	asJSON := fs.Bool("json", false, "print JSON instead of a table")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, agentsUsage())
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unknown argument %q\n%s", fs.Arg(0), agentsUsage())
	}

	panes, err := tmux.ListPanes()
	if err != nil {
		return err
	}
	states, err := state.Load()
	if err != nil {
		return err
	}
	self := os.Getenv("TMUX_PANE")
	target := *session
	if target == "" {
		for _, p := range panes {
			if p.PaneID == self {
				target = p.SessionID
			}
		}
		if target == "" {
			return fmt.Errorf("no tmux session for pane %q; pass --session\n%s", self, agentsUsage())
		}
	}
	agents := buildAgents(states, panes, target, self)

	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(agents)
	}
	return printAgents(os.Stdout, agents)
}

// buildAgents assembles the AgentInfo rows for kido agents and pi's
// list_agents tool: every live state.Session whose pane is currently in
// session (sessionsInSession, which explains why the pane list rather
// than the record decides that), decorated with the tmux.Pane a fresh
// ListPanes gave it.
func buildAgents(states map[string]state.Session, panes []tmux.Pane, session, self string) []AgentInfo {
	byPane := paneIndex(panes)
	scoped := sessionsInSession(states, panes, session)
	byInstance := map[string]string{} // instance -> agent id, for resolving Parent
	for _, s := range scoped {
		if s.Instance != "" {
			byInstance[s.Instance] = s.ID
		}
	}
	ordered := orderTree(scoped, byInstance)

	now := time.Now()
	out := make([]AgentInfo, 0, len(ordered))
	for _, s := range ordered {
		p := byPane[s.Pane]
		out = append(out, AgentInfo{
			ID:          s.ID,
			Name:        displayName(s, byPane),
			Agent:       s.Agent,
			Pane:        s.Pane,
			Window:      p.WindowID,
			Status:      string(s.Status),
			Activity:    s.Activity,
			Parent:      parentID(s, byInstance),
			Depth:       s.Depth,
			Self:        s.Pane == self,
			Cwd:         p.CurrentPath,
			CanMessage:  s.Inbox != "",
			Model:       s.Model,
			SinceReport: int(now.Sub(s.TS).Seconds()),
			Stalled:     state.Stalled(s, now),
		})
	}
	return out
}

// orderTree sorts scoped parent-first, then by report time within each
// parent (state.Session records no start time of its own, so TS - the
// time of its last report - is the best available proxy for spawn order),
// so the result reads as a tree: every subagent follows its parent, and
// siblings appear oldest first.
//
// Sorting the whole list before the walk is what puts siblings oldest
// first: tree.Order buckets children in the order it receives them, and
// emits whatever the walk missed - a cycle - in that same order, which is
// the invariant that list_agents shows every agent in the session even
// when the tree it draws them in is nonsense.
func orderTree(scoped []state.Session, byInstance map[string]string) []state.Session {
	sorted := append([]state.Session(nil), scoped...)
	sort.SliceStable(sorted, func(i, j int) bool { return olderFirst(sorted[i], sorted[j]) })
	return tree.Order(sorted,
		func(s state.Session) string { return s.ID },
		func(s state.Session) string { return parentID(s, byInstance) })
}

// isAncestor reports whether ancestorID is an ancestor of targetID within
// agents, walking each agent's Parent edge - the same walk
// pi/kido-status.ts's own isAncestor does on the extension side, kept in
// step because both enforce the same rule: ask_agent refuses to ask an
// ancestor, and kido interrupt/stop refuse to act on anything but a
// descendant, so the parent stays free to orchestrate and a confused
// descendant or peer cannot reach past or around it. seen guards a
// corrupt or cyclic parent chain from looping forever, the same concern
// orderTree has on the reporting side.
//
// Refuses ancestorID == targetID outright rather than walking for it: a
// record whose own Parent field named itself would otherwise make this
// true (the walk starts at that record's Parent, which is itself, and the
// first comparison matches). Nothing writes such a record today - a
// session's Parent always names a different process, the one that
// spawned it - so this is a belt-and-braces refusal for corrupted state
// rather than a case kido produces, and the worst outcome it prevents is
// a session stopping itself.
func isAncestor(agents []AgentInfo, ancestorID, targetID string) bool {
	if ancestorID == targetID {
		return false
	}
	byID := map[string]AgentInfo{}
	for _, a := range agents {
		byID[a.ID] = a
	}
	seen := map[string]bool{}
	cur := byID[targetID].Parent
	for cur != "" && !seen[cur] {
		if cur == ancestorID {
			return true
		}
		seen[cur] = true
		cur = byID[cur].Parent
	}
	return false
}

// paneIndex is panes indexed by PaneID, the lookup buildAgents,
// sessionsInSession and matchTarget all need to turn a state.Session's
// pane into the tmux.Pane it currently lives in.
func paneIndex(panes []tmux.Pane) map[string]tmux.Pane {
	byPane := map[string]tmux.Pane{}
	for _, p := range panes {
		byPane[p.PaneID] = p
	}
	return byPane
}

// displayName is the name a session shows in kido agents and list_agents:
// its reported Title, falling back to its pane's title when it has not set
// one. matchTarget (message.go) applies the exact same fallback, so a name
// this function produces is always one matchTarget can resolve back - the
// two must not drift, or a name read off list_agents would be refused by
// kido message.
func displayName(s state.Session, byPane map[string]tmux.Pane) string {
	if s.Title != "" {
		return s.Title
	}
	return byPane[s.Pane].Title
}

// parentID resolves s's parent to an agent id, "" for a root: the
// instance it reported as ParentInstance, looked up among the agents in
// scope. Matched on Instance rather than ParentPID: a pid can be reused
// by an unrelated process, and alive() cannot tell the difference, so a
// pid-keyed edge could name a live agent that is not actually the parent.
// An instance string is generated once per process and never reused, so
// it cannot collide that way (see state.Session.Instance).
//
// An agent that came out as its own parent - a bogus ParentInstance
// naming the record that now holds it - is reported as a root instead,
// since a self-edge is the one answer that is certainly wrong.
func parentID(s state.Session, byInstance map[string]string) string {
	if id := byInstance[s.ParentInstance]; id != s.ID {
		return id
	}
	return ""
}

// printAgents writes agents as a plain aligned table.
func printAgents(w io.Writer, agents []AgentInfo) error {
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tNAME\tAGENT\tMODEL\tPANE\tWINDOW\tSTATUS\tSTALLED\tACTIVITY\tSINCE\tPARENT\tDEPTH\tSELF\tCWD")
	for _, a := range agents {
		self := ""
		if a.Self {
			self = "*"
		}
		stalled := ""
		if a.Stalled {
			stalled = "stalled"
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%d\t%s\t%s\n",
			a.ID, a.Name, a.Agent, a.Model, a.Pane, a.Window, a.Status, stalled, a.Activity, a.SinceReport, a.Parent, a.Depth, self, a.Cwd)
	}
	return tw.Flush()
}

// olderFirst orders two records by when they last reported, falling back
// to the session id. The ids only ever break a tie, but records are
// gathered by ranging a map and two agents reporting inside the same
// clock tick are not rare, so without the tiebreak the list - and the
// sidebar tree built from it - would reorder between two calls that saw
// exactly the same state.
func olderFirst(a, b state.Session) bool {
	if a.TS.Equal(b.TS) {
		return a.ID < b.ID
	}
	return a.TS.Before(b.TS)
}
