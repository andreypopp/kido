package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"sort"
	"text/tabwriter"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
	"kido/internal/tree"
)

// AgentInfo is one row of `kido list_agents`, and what pi's list_agents
// tool reports verbatim as JSON.
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
	// CanReply is whether ask_agent may wait on this agent: it has an
	// inbox, and its run record - if any - does not narrow its tools
	// away from message_agent. A target spawned without message_agent can
	// never send the reply an ask waits for.
	CanReply bool   `json:"canReply"`
	Model    string `json:"model"`
	// SinceReport is seconds since the session's last report. It measures
	// staleness, not idle time: a session reporting Running has one too.
	SinceReport int `json:"sinceReport"`
	// Stalled is state.Stalled(s, now).
	Stalled bool `json:"stalled"`
	// Instance is s.Instance, the id `kido agent-alive` matches on. Empty
	// for an agent that never reported one (a Claude Code session tracked
	// only by hooks), which is never true of anything with CanMessage.
	Instance string `json:"instance,omitempty"`
}

func listAgentsUsage() string {
	return "usage: kido list_agents [--session ID] [--json]"
}

// listAgentsCmd implements `kido list_agents [--session ID] [--json]`:
// every agent in a tmux session, defaulting to the session holding the
// caller's own pane ($TMUX_PANE).
func listAgentsCmd(args []string) error {
	fs := flag.NewFlagSet("list_agents", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	session := fs.String("session", "", "tmux session id to list; defaults to the caller's own session")
	asJSON := fs.Bool("json", false, "print JSON instead of a table")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, listAgentsUsage())
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unknown argument %q\n%s", fs.Arg(0), listAgentsUsage())
	}

	panes, err := listPanes()
	if err != nil {
		return err
	}
	states, err := state.Load()
	if err != nil {
		return err
	}
	// --session is answered even from outside tmux, where there is no
	// caller pane to default from; only the defaulting needs one.
	self := os.Getenv("TMUX_PANE")
	target := *session
	if target == "" {
		p, ok := findPane(panes, self)
		if !ok {
			return fmt.Errorf("no tmux session for pane %q; pass --session\n%s", self, listAgentsUsage())
		}
		target = p.SessionID
	}
	agents := buildAgents(states, panes, target, self)

	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(agents)
	}
	return printAgents(os.Stdout, agents)
}

// buildAgents assembles the AgentInfo rows for kido list_agents and pi's
// list_agents tool: every live state.Session whose pane is currently in
// session, decorated with its tmux.Pane.
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
			CanReply:    s.Inbox != "" && canReplyTools(s.ID),
			Model:       s.Model,
			SinceReport: int(now.Sub(s.TS).Seconds()),
			Stalled:     state.Stalled(s, now),
			Instance:    s.Instance,
		})
	}
	return out
}

// orderTree sorts scoped parent-first, siblings oldest report first (a
// Session records no start time, so TS is the proxy for spawn order).
// tree.Order keeps the order it receives, so the sort comes first.
func orderTree(scoped []state.Session, byInstance map[string]string) []state.Session {
	sorted := append([]state.Session(nil), scoped...)
	sort.SliceStable(sorted, func(i, j int) bool { return olderFirst(sorted[i], sorted[j]) })
	return tree.Order(sorted,
		func(s state.Session) string { return s.ID },
		func(s state.Session) string { return parentID(s, byInstance) })
}

// canReplyTools reports whether id's run record, if any, still allows
// message_agent: no record (a root agent, or a pi/kido too old to write
// one) and an empty tools list both mean unrestricted.
func canReplyTools(id string) bool {
	meta, err := subrun.ReadMeta(id)
	if err != nil || len(meta.Tools) == 0 {
		return true
	}
	return slices.Contains(meta.Tools, "message_agent")
}

// isAncestor reports whether ancestorID is an ancestor of targetID within
// agents, walking each agent's Parent edge; pi/kido-agents.ts's
// isAncestor is the same walk and the two are kept in step. seen guards
// a cyclic parent chain. ancestorID == targetID is refused outright: a
// corrupt record naming itself as its parent would otherwise match on the
// first comparison and let a session stop itself.
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

// paneIndex is panes indexed by PaneID.
func paneIndex(panes []tmux.Pane) map[string]tmux.Pane {
	byPane := map[string]tmux.Pane{}
	for _, p := range panes {
		byPane[p.PaneID] = p
	}
	return byPane
}

// displayName is the name a session shows in kido list_agents:
// its reported Title, falling back to its pane's title stripped the way
// the sidebar strips it. matchTarget
// (message_agent.go) resolves by the same name, so the two must not drift.
func displayName(s state.Session, byPane map[string]tmux.Pane) string {
	if s.Title != "" {
		return s.Title
	}
	return state.AgentTitle(byPane[s.Pane].Title)
}

// parentID resolves s's parent to an agent id, "" for a root, by
// ParentInstance looked up among the agents in scope. A self-edge is
// reported as a root.
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

// olderFirst orders two records by when they last reported, with the
// session id as a tiebreak: records come from ranging a map, so without
// it two agents reporting in the same clock tick would reorder between
// two calls that saw the same state.
func olderFirst(a, b state.Session) bool {
	if a.TS.Equal(b.TS) {
		return a.ID < b.ID
	}
	return a.TS.Before(b.TS)
}
