package ui

import (
	"reflect"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"

	"kido/internal/state"
	"kido/internal/tmux"
)

func windowIDs(placements []windowPlacement) []string {
	var ids []string
	for _, pl := range placements {
		ids = append(ids, pl.panes[0].WindowID)
	}
	return ids
}

// depths is the window -> depth view the sidebar used to be handed
// directly, kept here because it is what these tests assert about.
func depths(placements []windowPlacement) map[string]int {
	d := map[string]int{}
	for _, pl := range placements {
		d[pl.panes[0].WindowID] = pl.depth
	}
	return d
}

func sameIDs(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range want {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

// renderRows builds the sidebar over panes and states and returns the
// rows it drew, unstyled. The rendered rows are what these tests assert
// on: the ordering alone reads the same whether a child's window follows
// its parent's window or its parent's pane, so an ordering-only test
// cannot tell the two layouts apart.
func renderRows(panes []tmux.Pane, states map[string]state.Session) []string {
	at := time.Unix(1700000000, 0)
	m := model{
		started: at,
		seen:    map[string]time.Time{},
		phases:  map[string]shellPhase{},
		now:     func() time.Time { return at },
		at:      at,
		snap:    snapshot{current: "sess", panes: panes, states: states},
	}
	m.rebuild()
	out := make([]string, 0, len(m.rows))
	for _, r := range m.rows {
		out = append(out, ansi.Strip(r.text))
	}
	return out
}

// agentPane is a reported agent pane in window w of session "sess".
func agentPane(w, pane, title string) tmux.Pane {
	return tmux.Pane{SessionName: "sess", WindowID: w, PaneID: pane, Title: title}
}

// shellPane is an ordinary pane: no record, no OSC 133 integration, so
// its row is its command and nothing else.
func shellPane(w, pane string) tmux.Pane {
	return tmux.Pane{SessionName: "sess", WindowID: w, PaneID: pane, CurrentCommand: "zsh"}
}

func agentState(inst, parent, title string) state.Session {
	return state.Session{
		Agent: state.AgentPi, Status: state.Running, Title: title,
		Instance: inst, ParentInstance: parent,
	}
}

func wantRows(t *testing.T, got, want []string) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Errorf("rows =\n\t%q\nwant\n\t%q", got, want)
	}
}

// TestRenderNestsUnderTheParentPane is the layout this whole walk exists
// to produce: the subagent's window sits under the row of the pane its
// parent runs in, inside the parent window's bracket, not after the
// parent window's last pane.
func TestRenderNestsUnderTheParentPane(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@13", "%22", "orchestrator"),
		shellPane("@13", "%47"),
		agentPane("@20", "%30", "subagent"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
		"%30": agentState("kid-inst", "root-inst", "subagent"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"┌ ▌ orchestrator",
		"│ · ▌ subagent",
		"└ zsh",
	})
}

// TestRenderKeepsTheColumnAcrossANestedChild is the case the glyphs make
// awkward: a three-pane window with a subagent hanging off its middle
// pane. The parent's column is carried down the left of the child's rows
// with a stem, so the bracket still reads as one window with a block
// nested inside it.
func TestRenderKeepsTheColumnAcrossANestedChild(t *testing.T) {
	panes := []tmux.Pane{
		shellPane("@13", "%10"),
		agentPane("@13", "%22", "orchestrator"),
		shellPane("@13", "%47"),
		agentPane("@20", "%30", "subagent"),
		shellPane("@20", "%31"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
		"%30": agentState("kid-inst", "root-inst", "subagent"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"┌ zsh",
		"├ ▌ orchestrator",
		"│ ┌ ▌ subagent",
		"│ └ zsh",
		"└ zsh",
	})
}

// TestRenderStopsTheStemAtTheLastPane is the other half of the rule: a
// child of a window's last pane has nothing of the parent below it, so
// the stem stops rather than dangling into empty space.
func TestRenderStopsTheStemAtTheLastPane(t *testing.T) {
	panes := []tmux.Pane{
		shellPane("@13", "%10"),
		agentPane("@13", "%22", "orchestrator"),
		agentPane("@20", "%30", "subagent"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
		"%30": agentState("kid-inst", "root-inst", "subagent"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"┌ zsh",
		"└ ▌ orchestrator",
		"  · ▌ subagent",
	})
}

// TestRenderNestsRecursively checks that the nesting is the walk's, not
// the reported Depth's: the grandchild below claims depth 1 and is still
// drawn under its own parent's pane, two levels in.
func TestRenderNestsRecursively(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@1", "%1", "root"),
		agentPane("@2", "%2", "kid"),
		agentPane("@3", "%3", "grandkid"),
	}
	states := map[string]state.Session{
		"%1": agentState("root-inst", "", "root"),
		"%2": {Agent: state.AgentPi, Status: state.Running, Title: "kid",
			Instance: "kid-inst", ParentInstance: "root-inst", Depth: 1},
		"%3": {Agent: state.AgentPi, Status: state.Running, Title: "grandkid",
			Instance: "gk-inst", ParentInstance: "kid-inst", Depth: 1},
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"· ▌ root",
		"  · ▌ kid",
		"    · ▌ grandkid",
	})
}

// TestRenderDrawsAnOrphanAsARoot is the rendered counterpart of
// TestOrderWindowsByTreeIndentsOnlyRealChildren: a subagent whose parent
// is in another session reports depth 1 all the same, and must be drawn
// flush left rather than under whatever row precedes it.
func TestRenderDrawsAnOrphanAsARoot(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@1", "%1", "unrelated"),
		agentPane("@2", "%2", "orphan"),
	}
	states := map[string]state.Session{
		"%1": agentState("other-inst", "", "unrelated"),
		"%2": {Agent: state.AgentPi, Status: state.Running, Title: "orphan",
			Instance: "orphan-inst", ParentInstance: "elsewhere-inst", Depth: 1},
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"· ▌ unrelated",
		"· ▌ orphan",
	})
}

// TestRenderDropsNobodyInACycle: two agents each naming the other as
// parent. Whatever the walk makes of the edges, both rows are on screen.
func TestRenderDropsNobodyInACycle(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@1", "%a", "a"),
		agentPane("@2", "%b", "b"),
	}
	states := map[string]state.Session{
		"%a": agentState("a-inst", "b-inst", "a"),
		"%b": agentState("b-inst", "a-inst", "b"),
	}
	rows := renderRows(panes, states)
	if len(rows) != 3 {
		t.Fatalf("rows = %q, want the session and both agents", rows)
	}
	if rows[1] != "· ▌ a" {
		t.Errorf("rows[1] = %q, want the first member of the ring drawn as a root", rows[1])
	}
	if rows[2] != "  · ▌ b" && rows[2] != "· ▌ b" {
		t.Errorf("rows[2] = %q, want the other member drawn somewhere", rows[2])
	}
}

// TestRenderIsDeterministic: the same state must not shuffle between two
// builds. Map iteration is where that would leak in, and a sidebar
// rebuilds on every tick.
func TestRenderIsDeterministic(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@1", "%1", "root"),
		shellPane("@1", "%2"),
		agentPane("@2", "%3", "kid-a"),
		agentPane("@3", "%4", "kid-b"),
		agentPane("@4", "%5", "grandkid"),
	}
	states := map[string]state.Session{
		"%1": agentState("root-inst", "", "root"),
		"%3": agentState("a-inst", "root-inst", "kid-a"),
		"%4": agentState("b-inst", "root-inst", "kid-b"),
		"%5": agentState("g-inst", "b-inst", "grandkid"),
	}
	want := renderRows(panes, states)
	for range 20 {
		if got := renderRows(panes, states); !reflect.DeepEqual(got, want) {
			t.Fatalf("rows =\n\t%q\nwant\n\t%q", got, want)
		}
	}
	wantRows(t, want, []string{
		"sess",
		"┌ ▌ root",
		"│ · ▌ kid-a",
		"│ · ▌ kid-b",
		"│   · ▌ grandkid",
		"└ zsh",
	})
}

// TestOrderWindowsByTreePutsChildRightAfterParent checks the ordering the
// sidebar tree depends on: a subagent's window follows its parent's,
// wherever tmux happened to put it, and an unrelated window (no agent
// pane at all) keeps its own place.
func TestOrderWindowsByTreePutsChildRightAfterParent(t *testing.T) {
	windows := [][]tmux.Pane{
		{{PaneID: "%shell", WindowID: "@shell"}},   // an ordinary shell window
		{{PaneID: "%root", WindowID: "@root"}},     // the root agent
		{{PaneID: "%child2", WindowID: "@child2"}}, // spawned second
		{{PaneID: "%child1", WindowID: "@child1"}}, // spawned first, but tmux put it after child2
	}
	states := map[string]state.Session{
		"%root":   {Instance: "root-inst"},
		"%child2": {ParentInstance: "root-inst", Depth: 1},
		"%child1": {ParentInstance: "root-inst", Depth: 1},
	}
	got := orderWindowsByTree(windows, states)
	want := []string{"@shell", "@root", "@child2", "@child1"}
	if !sameIDs(windowIDs(got), want) {
		t.Fatalf("order = %v, want %v", windowIDs(got), want)
	}
	depth := depths(got)
	for id, wantDepth := range map[string]int{"@shell": 0, "@root": 0, "@child2": 1, "@child1": 1} {
		if depth[id] != wantDepth {
			t.Errorf("depth[%s] = %d, want %d", id, depth[id], wantDepth)
		}
	}
	for _, pl := range got {
		want := ""
		if pl.depth > 0 {
			want = "%root" // the pane the parent agent runs in, not its window
		}
		if pl.anchor != want {
			t.Errorf("anchor[%s] = %q, want %q", pl.panes[0].WindowID, pl.anchor, want)
		}
	}
}

// TestOrderWindowsByTreeIndentsOnlyRealChildren is the reason the indent
// is derived here rather than read from state.Session.Depth. Depth is
// what a record says about itself: a subagent whose parent is not in this
// session at all - moved away with move-window, or simply gone - reports
// depth 1 regardless, and indenting on that word alone drew it as a child
// of whatever row happened to precede it.
func TestOrderWindowsByTreeIndentsOnlyRealChildren(t *testing.T) {
	windows := [][]tmux.Pane{
		{{PaneID: "%shell", WindowID: "@shell"}},
		{{PaneID: "%orphan", WindowID: "@orphan"}},
	}
	states := map[string]state.Session{
		"%orphan": {Instance: "orphan-inst", ParentInstance: "elsewhere-inst", Depth: 1},
	}
	got := orderWindowsByTree(windows, states)
	if !sameIDs(windowIDs(got), []string{"@shell", "@orphan"}) {
		t.Fatalf("order = %v, want tmux's own order kept", windowIDs(got))
	}
	if depths(got)["@orphan"] != 0 {
		t.Errorf("depth[@orphan] = %d, want 0: its parent is in no window of this session", depths(got)["@orphan"])
	}
	for _, pl := range got {
		if pl.anchor != "" {
			t.Errorf("anchor[%s] = %q, want none: there is no edge to hang it off",
				pl.panes[0].WindowID, pl.anchor)
		}
	}
}

// TestOrderWindowsByTreeNests checks that the indent grows with the tree,
// not with the reported Depth: the grandchild below claims depth 1 and is
// still drawn two levels in, because that is where the parent walk puts
// it.
func TestOrderWindowsByTreeNests(t *testing.T) {
	windows := [][]tmux.Pane{
		{{PaneID: "%root", WindowID: "@root"}},
		{{PaneID: "%kid", WindowID: "@kid"}},
		{{PaneID: "%grandkid", WindowID: "@grandkid"}},
	}
	states := map[string]state.Session{
		"%root":     {Instance: "root-inst"},
		"%kid":      {Instance: "kid-inst", ParentInstance: "root-inst", Depth: 1},
		"%grandkid": {Instance: "gk-inst", ParentInstance: "kid-inst", Depth: 1},
	}
	got := orderWindowsByTree(windows, states)
	if !sameIDs(windowIDs(got), []string{"@root", "@kid", "@grandkid"}) {
		t.Fatalf("order = %v, want parent-first", windowIDs(got))
	}
	depth := depths(got)
	if depth["@kid"] != 1 || depth["@grandkid"] != 2 {
		t.Errorf("depths = kid %d, grandkid %d; want 1 and 2", depth["@kid"], depth["@grandkid"])
	}
}

// TestOrderWindowsByTreeHandlesCycle checks that a bogus ParentInstance
// naming a window's own descendant (or itself) never drops a window from
// the result - only from wherever the cycle would have placed it - the
// same guarantee orderTree (cmd/kido/agents.go) makes. The depth walk
// must survive it too: it runs over the ordered result exactly once, so a
// ring cannot make it recurse.
func TestOrderWindowsByTreeHandlesCycle(t *testing.T) {
	windows := [][]tmux.Pane{
		{{PaneID: "%a", WindowID: "@a"}},
		{{PaneID: "%b", WindowID: "@b"}},
	}
	states := map[string]state.Session{
		"%a": {Instance: "a-inst", ParentInstance: "b-inst"},
		"%b": {Instance: "b-inst", ParentInstance: "a-inst"},
	}
	got := orderWindowsByTree(windows, states)
	if len(got) != 2 {
		t.Fatalf("order = %v, want both windows exactly once", windowIDs(got))
	}
	seen := map[string]bool{}
	for _, id := range windowIDs(got) {
		seen[id] = true
	}
	if !seen["@a"] || !seen["@b"] {
		t.Errorf("order = %v, want both @a and @b present", windowIDs(got))
	}
	if got[0].depth != 0 {
		t.Errorf("the first window of a cycle is drawn as a root, want depth 0, got %d", got[0].depth)
	}
}
