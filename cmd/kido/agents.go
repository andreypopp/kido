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
	// IdleFor is seconds since the session's last report (state.Session.TS),
	// derived at list time rather than stored: it is only ever meaningful
	// as of now.
	IdleFor int `json:"idleFor"`
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
	byPane := map[string]tmux.Pane{}
	for _, p := range panes {
		byPane[p.PaneID] = p
	}
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
		name := s.Title
		if name == "" {
			name = p.Title
		}
		out = append(out, AgentInfo{
			ID:         s.ID,
			Name:       name,
			Agent:      s.Agent,
			Pane:       s.Pane,
			Window:     p.WindowID,
			Status:     string(s.Status),
			Activity:   s.Activity,
			Parent:     parentID(s, byInstance),
			Depth:      s.Depth,
			Self:       s.Pane == self,
			Cwd:        p.CurrentPath,
			CanMessage: s.Inbox != "",
			Model:      s.Model,
			IdleFor:    int(now.Sub(s.TS).Seconds()),
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
// Every agent comes out exactly once, tree or no tree. A walk from the
// roots alone reaches no record whose parent chain closes a cycle, and a
// cycle is reachable: a bug in a reporting agent (or a bare-metal replay
// of an old state file) could report a ParentInstance that names one of
// its own descendants, or itself. Anything the walk missed is therefore
// emitted afterwards as a root, oldest first, keeping the invariant that
// list_agents shows every agent in the session even when the tree it
// draws them in is nonsense.
func orderTree(scoped []state.Session, byInstance map[string]string) []state.Session {
	children := map[string][]state.Session{} // parent id ("" for a root) -> children
	for _, s := range scoped {
		parent := parentID(s, byInstance)
		children[parent] = append(children[parent], s)
	}
	for _, c := range children {
		sort.SliceStable(c, func(i, j int) bool { return olderFirst(c[i], c[j]) })
	}
	out := make([]state.Session, 0, len(scoped))
	seen := map[string]bool{}
	var walk func(parent string)
	walk = func(parent string) {
		for _, s := range children[parent] {
			if seen[s.ID] {
				continue
			}
			seen[s.ID] = true
			out = append(out, s)
			walk(s.ID)
		}
	}
	walk("")
	var orphans []state.Session
	for _, s := range scoped {
		if !seen[s.ID] {
			orphans = append(orphans, s)
		}
	}
	sort.SliceStable(orphans, func(i, j int) bool { return olderFirst(orphans[i], orphans[j]) })
	for _, s := range orphans {
		if seen[s.ID] {
			continue // the ring's first member already pulled this one in
		}
		seen[s.ID] = true
		out = append(out, s)
		walk(s.ID)
	}
	return out
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
	fmt.Fprintln(tw, "ID\tNAME\tAGENT\tMODEL\tPANE\tWINDOW\tSTATUS\tACTIVITY\tIDLEFOR\tPARENT\tDEPTH\tSELF\tCWD")
	for _, a := range agents {
		self := ""
		if a.Self {
			self = "*"
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%d\t%s\t%s\n",
			a.ID, a.Name, a.Agent, a.Model, a.Pane, a.Window, a.Status, a.Activity, a.IdleFor, a.Parent, a.Depth, self, a.Cwd)
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
