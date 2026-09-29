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
}

func listAgentsUsage() string {
	return "usage: kido list_agents [--session ID] [--json]"
}

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
	tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
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

func buildAgents(states map[string]state.Session, panes []tmux.Pane, session, self string) []AgentInfo {
	byPane := paneIndex(panes)
	scoped := sessionsInSession(states, panes, session)
	inScope := map[string]bool{}
	for _, s := range scoped {
		inScope[s.ID] = true
	}
	// TS is the proxy for spawn order (a Session records no start time);
	// the session id is a tiebreak, since scoped comes from ranging a map
	// and two agents reporting in the same clock tick would otherwise
	// reorder between calls that saw the same state.
	sorted := append([]state.Session(nil), scoped...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if sorted[i].TS.Equal(sorted[j].TS) {
			return sorted[i].ID < sorted[j].ID
		}
		return sorted[i].TS.Before(sorted[j].TS)
	})
	ordered := tree.Order(sorted,
		func(s state.Session) string { return s.ID },
		func(s state.Session) string { return parentID(s, inScope) })

	now := time.Now()
	wake := state.Wake()
	out := make([]AgentInfo, 0, len(ordered))
	for _, s := range ordered {
		p := byPane[s.Pane]
		canReply := false
		if s.Inbox != "" {
			id, err := subrun.ParseID(s.ID)
			var meta subrun.Meta
			if err == nil {
				meta, err = subrun.ReadMeta(id)
			}
			canReply = err != nil || len(meta.Tools) == 0 || slices.Contains(meta.Tools, "message_agent")
		}
		out = append(out, AgentInfo{
			ID:          s.ID,
			Name:        displayName(s, byPane),
			Agent:       string(s.Agent),
			Pane:        s.Pane,
			Window:      p.WindowID,
			Status:      string(s.Status),
			Activity:    s.Activity,
			Parent:      parentID(s, inScope),
			Depth:       s.Depth,
			Self:        s.Pane == self,
			Cwd:         p.CurrentPath,
			CanMessage:  s.Inbox != "",
			CanReply:    canReply,
			Model:       s.Model,
			SinceReport: int(now.Sub(s.TS).Seconds()),
			Stalled:     state.StalledSince(s, wake, now),
		})
	}
	return out
}

// pi/kido-agents.ts's isAncestor is the same walk and the two are kept in
// step. ancestorID == targetID is refused outright: a corrupt record
// naming itself as its parent would otherwise match on the first
// comparison and let a session stop itself.
func isAncestor(parentOf map[string]string, ancestorID, targetID string) bool {
	if ancestorID == targetID {
		return false
	}
	seen := map[string]bool{}
	cur := parentOf[targetID]
	for cur != "" && !seen[cur] {
		if cur == ancestorID {
			return true
		}
		seen[cur] = true
		cur = parentOf[cur]
	}
	return false
}

func paneIndex(panes []tmux.Pane) map[string]tmux.Pane {
	byPane := map[string]tmux.Pane{}
	for _, p := range panes {
		byPane[p.PaneID] = p
	}
	return byPane
}

// Falls back to its pane's title, stripped the way the sidebar strips it.
// message_agent's matchTarget resolves by the same name, so the two must
// not drift.
func displayName(s state.Session, byPane map[string]tmux.Pane) string {
	if s.Title != "" {
		return s.Title
	}
	return state.AgentTitle(byPane[s.Pane].Title)
}

// A self-edge is reported as a root.
func parentID(s state.Session, inScope map[string]bool) string {
	if s.Parent != nil && s.Parent.Session != s.ID && inScope[s.Parent.Session] {
		return s.Parent.Session
	}
	return ""
}
