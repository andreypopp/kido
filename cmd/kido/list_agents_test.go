package main

import (
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

// TestDisplayNameStripsPisMarker checks that list_agents' name fallback
// goes through the same pi-marker stripping as the sidebar, so a name
// list_agents prints is always the one the sidebar shows and can be typed
// back as an @ mention or a message_agent target.
func TestDisplayNameStripsPisMarker(t *testing.T) {
	byPane := map[string]tmux.Pane{
		"%1": {PaneID: "%1", Title: "π - kido"},
		"%2": {PaneID: "%2", Title: "π - review - kido"},
		"%3": {PaneID: "%3", Title: "π - kido"},
	}
	for _, c := range []struct {
		name string
		s    state.Session
		want string
	}{
		{"no title, unnamed pi session", state.Session{Pane: "%1"}, "kido"},
		{"no title, named pi session", state.Session{Pane: "%2"}, "review - kido"},
		{"reported title wins verbatim", state.Session{Pane: "%3", Title: "π - kido"}, "π - kido"},
	} {
		if got := displayName(c.s, byPane); got != c.want {
			t.Errorf("%s: displayName = %q, want %q", c.name, got, c.want)
		}
	}
}

// TestAgentsCmdDefaultsToTheCallersSession drives the command itself,
// not buildAgents: the scoping it applies is chosen here, from $TMUX_PANE
// against tmux's pane list, and an agent in another tmux session is one
// nothing in this one can reach.
func TestAgentsCmdDefaultsToTheCallersSession(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%9", SessionID: "$2", WindowID: "@9"},
	})
	for _, s := range []state.Session{
		{ID: "here", Pane: "%1", PID: os.Getpid(), Agent: state.AgentPi, Status: state.Idle},
		{ID: "elsewhere", Pane: "%9", PID: os.Getpid(), Agent: state.AgentPi, Status: state.Idle},
	} {
		if err := state.Record(s.ID, s); err != nil {
			t.Fatal(err)
		}
	}

	var err error
	out := captureStdout(t, func() { err = listAgentsCmd([]string{"--json"}) })
	if err != nil {
		t.Fatal(err)
	}
	var got []AgentInfo
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("agents --json: %v (%q)", err, out)
	}
	if len(got) != 1 || got[0].ID != "here" || !got[0].Self {
		t.Fatalf("agents --json = %+v, want only the caller's own session's agent, marked self", got)
	}

	// An explicit --session reaches the other one, so the filtering above
	// is the default rather than the only answer available.
	out = captureStdout(t, func() { err = listAgentsCmd([]string{"--json", "--session", "$2"}) })
	if err != nil {
		t.Fatal(err)
	}
	got = nil
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("agents --json --session $2: %v (%q)", err, out)
	}
	if len(got) != 1 || got[0].ID != "elsewhere" || got[0].Self {
		t.Fatalf("agents --json --session $2 = %+v, want only the other session's agent", got)
	}
}

// TestAgentsCmdWithNoCallerPane: run from outside tmux, or from a pane
// tmux no longer knows, there is no session to default to. It says so
// rather than guessing at one, and --session is still answered.
func TestAgentsCmdWithNoCallerPane(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "")
	withPanes(t, []tmux.Pane{{PaneID: "%1", SessionID: "$1", WindowID: "@1"}})

	err := listAgentsCmd([]string{"--json"})
	if err == nil {
		t.Fatal("agents with no caller pane = nil error, want a refusal")
	}
	if !strings.Contains(err.Error(), "pass --session") {
		t.Errorf("error = %q, want it to point at --session", err)
	}
	out := captureStdout(t, func() { err = listAgentsCmd([]string{"--json", "--session", "$1"}) })
	if err != nil {
		t.Fatalf("agents --session from outside tmux = %v, want it answered", err)
	}
	if strings.TrimSpace(out) == "" {
		t.Error("agents --json --session $1 printed nothing, want a JSON list")
	}
}

// TestIsAncestorRefusesSelfEdge pins the explicit refusal at the top of
// isAncestor: without it, a corrupted record whose own Parent field named
// itself would make isAncestor(agents, X, X) true, and control.go's
// descendant-only check would let a session's stop/interrupt of itself
// through on that basis.
func TestIsAncestorRefusesSelfEdge(t *testing.T) {
	agents := []AgentInfo{
		{ID: "x", Parent: "x"}, // corrupted: names itself as its own parent
	}
	if isAncestor(agents, "x", "x") {
		t.Error("isAncestor(agents, X, X) = true, want false even with a self-parent record")
	}
}

// TestBuildAgentsScopesToSession checks that buildAgents includes only
// agents whose pane is in the target session, excluding a live agent in
// a different one.
func TestBuildAgentsScopesToSession(t *testing.T) {
	states := map[string]state.Session{
		"%1": {ID: "a", Pane: "%1", PID: 100, Agent: state.AgentPi, Status: state.Running},
		"%2": {ID: "b", Pane: "%2", PID: 200, Agent: state.AgentClaude, Status: state.Idle},
	}
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1", CurrentPath: "/work"},
		{PaneID: "%2", SessionID: "$2", WindowID: "@2", CurrentPath: "/other"},
	}

	got := buildAgents(states, panes, "$1", "%1")
	if len(got) != 1 || got[0].ID != "a" {
		t.Fatalf("got %+v, want only agent a, from session $1", got)
	}
	if !got[0].Self {
		t.Error("agent a's own pane should be Self")
	}
	if got[0].Window != "@1" || got[0].Cwd != "/work" {
		t.Errorf("got %+v, window/cwd not decorated from panes", got[0])
	}

	got = buildAgents(states, panes, "$2", "%1")
	if len(got) != 1 || got[0].ID != "b" {
		t.Fatalf("got %+v, want only agent b, from session $2", got)
	}
	if got[0].Self {
		t.Error("agent b is not the caller's own pane")
	}
	if got[0].CanMessage {
		t.Error("a Claude Code record has no inbox and must not be messageable")
	}
}

// TestBuildAgentsListsEveryAgentInACycle pins the one thing orderTree
// owes its caller: an agent in the session is in the list. A bogus
// ParentInstance can make a record name one of its own descendants - or
// itself - as its parent, and a walk that starts at the roots reaches
// neither. list_agents is the only way to discover an agent at all, so a
// ring that drops out of it is an agent nothing can address; it comes out
// as a root instead.
func TestBuildAgentsListsEveryAgentInACycle(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"}, {PaneID: "%2", SessionID: "$1"}, {PaneID: "%3", SessionID: "$1"},
	}
	states := map[string]state.Session{
		"%1": {ID: "a", Pane: "%1", PID: 100, Instance: "a-inst", ParentInstance: "b-inst"},
		"%2": {ID: "b", Pane: "%2", PID: 200, Instance: "b-inst", ParentInstance: "a-inst"},
		"%3": {ID: "root", Pane: "%3", PID: 300},
	}
	got := buildAgents(states, panes, "$1", "%3")
	seen := map[string]int{}
	for _, a := range got {
		seen[a.ID]++
	}
	for _, id := range []string{"a", "b", "root"} {
		if seen[id] != 1 {
			t.Errorf("agent %s appears %d times in %d rows, want exactly once", id, seen[id], len(got))
		}
	}

	// A record that is its own parent is a root, not a child of itself.
	self := map[string]state.Session{
		"%1": {ID: "a", Pane: "%1", PID: 100, Instance: "a-inst", ParentInstance: "a-inst"},
	}
	got = buildAgents(self, panes, "$1", "%1")
	if len(got) != 1 || got[0].Parent != "" {
		t.Errorf("got %+v, want one agent with no parent", got)
	}
}

// TestBuildAgentsParentTree checks that a subagent is ordered right after
// its parent (matched by ParentInstance against the parent's own
// Instance), and that siblings come out oldest first.
func TestBuildAgentsParentTree(t *testing.T) {
	t0 := time.Unix(1000, 0)
	states := map[string]state.Session{
		"%1": {ID: "root", Pane: "%1", PID: 100, Instance: "root-inst", Status: state.Running, TS: t0},
		"%2": {ID: "child2", Pane: "%2", PID: 201, ParentInstance: "root-inst", Depth: 1, Status: state.Running, TS: t0.Add(2 * time.Second)},
		"%3": {ID: "child1", Pane: "%3", PID: 202, ParentInstance: "root-inst", Depth: 1, Status: state.Running, TS: t0.Add(1 * time.Second)},
	}
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"}, {PaneID: "%2", SessionID: "$1"}, {PaneID: "%3", SessionID: "$1"},
	}

	got := buildAgents(states, panes, "$1", "%1")
	if len(got) != 3 {
		t.Fatalf("got %d agents, want 3", len(got))
	}
	var ids []string
	for _, a := range got {
		ids = append(ids, a.ID)
	}
	if want := []string{"root", "child1", "child2"}; ids[0] != want[0] || ids[1] != want[1] || ids[2] != want[2] {
		t.Errorf("order = %v, want %v (parent first, then oldest sibling first)", ids, want)
	}
	for _, a := range got {
		if a.ID != "root" && a.Parent != "root" {
			t.Errorf("agent %s: parent = %q, want root", a.ID, a.Parent)
		}
	}
}

// TestBuildAgentsRecycledPIDNoEdge checks that a parent edge is matched on
// ParentInstance, not ParentPID: a pid can be recycled by an unrelated
// process, and alive() cannot tell the difference (it reports EPERM as
// alive), so a pid-keyed edge could wrongly attach a child to a process
// that merely reused its parent's old pid.
func TestBuildAgentsRecycledPIDNoEdge(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"}, {PaneID: "%2", SessionID: "$1"},
	}
	states := map[string]state.Session{
		"%1": {ID: "root", Pane: "%1", PID: 100, Instance: "root-inst"},
		// child's ParentPID (100) matches root's PID, but its ParentInstance
		// names some other, unrelated process's instance.
		"%2": {ID: "child", Pane: "%2", PID: 200, ParentPID: 100, ParentInstance: "someone-else"},
	}
	got := buildAgents(states, panes, "$1", "%1")
	for _, a := range got {
		if a.ID == "child" && a.Parent != "" {
			t.Errorf("child's parent = %q, want none: ParentPID matching root's PID must not create an edge", a.Parent)
		}
	}
}

// TestBuildAgentsStableOrderOnTie pins the id tiebreak in olderFirst.
// Records are gathered by ranging a map, so two agents that last
// reported inside the same clock tick would otherwise come back in a
// different order on each call against identical state - and the
// sidebar tree is built from this list.
func TestBuildAgentsStableOrderOnTie(t *testing.T) {
	ts := time.Now().UTC()
	states := map[string]state.Session{}
	for _, id := range []string{"ccc", "aaa", "bbb"} {
		states[id] = state.Session{ID: id, Pane: "%" + id, TS: ts}
	}
	panes := []tmux.Pane{
		{PaneID: "%ccc", SessionID: "$1"},
		{PaneID: "%aaa", SessionID: "$1"},
		{PaneID: "%bbb", SessionID: "$1"},
	}
	want := []string{"aaa", "bbb", "ccc"}
	for i := 0; i < 20; i++ {
		var got []string
		for _, a := range buildAgents(states, panes, "$1", "%aaa") {
			got = append(got, a.ID)
		}
		if !slices.Equal(got, want) {
			t.Fatalf("run %d: order = %v, want %v", i, got, want)
		}
	}
}

// TestBuildAgentsCanReply pins the three run-record shapes that decide
// whether a target can answer an ask_agent: no record, an empty tools
// list, and a tools list that excludes message_agent - each keeps
// CanReply false despite having an inbox; a tools list including
// message_agent, and no record at all, both leave it true.
func TestBuildAgentsCanReply(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	states := map[string]state.Session{
		"%1": {ID: "no-record", Pane: "%1", PID: 100, Agent: state.AgentPi, Status: state.Idle, Inbox: "sock"},
		"%2": {ID: "empty-tools", Pane: "%2", PID: 200, Agent: state.AgentPi, Status: state.Idle, Inbox: "sock"},
		"%3": {ID: "no-message-tool", Pane: "%3", PID: 300, Agent: state.AgentPi, Status: state.Idle, Inbox: "sock"},
		"%4": {ID: "has-message-tool", Pane: "%4", PID: 400, Agent: state.AgentPi, Status: state.Idle, Inbox: "sock"},
	}
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
		{PaneID: "%3", SessionID: "$1", WindowID: "@3"},
		{PaneID: "%4", SessionID: "$1", WindowID: "@4"},
	}
	for id, tools := range map[string][]string{
		"empty-tools":      {},
		"no-message-tool":  {"read", "bash"},
		"has-message-tool": {"read", "message_agent"},
	} {
		if err := subrun.Create(id, "task"); err != nil {
			t.Fatal(err)
		}
		if err := subrun.WriteMeta(subrun.Meta{ID: id, Tools: tools}); err != nil {
			t.Fatal(err)
		}
	}

	got := buildAgents(states, panes, "$1", "%1")
	want := map[string]bool{
		"no-record":        true,
		"empty-tools":      true,
		"no-message-tool":  false,
		"has-message-tool": true,
	}
	for _, a := range got {
		if a.CanReply != want[a.ID] {
			t.Errorf("%s: CanReply = %v, want %v", a.ID, a.CanReply, want[a.ID])
		}
	}
}
