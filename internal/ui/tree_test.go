package ui

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

func windowIDs(placements []windowPlacement) []string {
	var ids []string
	for _, pl := range placements {
		ids = append(ids, pl.panes[0].WindowID)
	}
	return ids
}

// anchors is the window -> anchor pane view: where the walk hung each
// window, which is the whole of what it decides. "" is a root.
func anchorsOf(placements []windowPlacement) map[string]string {
	a := map[string]string{}
	for _, pl := range placements {
		a[pl.panes[0].WindowID] = pl.anchor
	}
	return a
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
// testAt is the fixed instant every renderRows test runs at. agentState
// stamps it onto TS too, so state.Stalled sees a zero gap and its answer
// does not depend on a stray ~/.local/state/kido/wake left by a real kido
// running on the machine the tests happen to run on.
var testAt = time.Unix(1700000000, 0)

func renderRows(panes []tmux.Pane, states map[string]state.Session) []string {
	at := testAt
	m := model{
		started: at,
		seen:    map[string]time.Time{},
		phases:  map[string]shellPhase{},
		now:     func() time.Time { return at },
		at:      at,
		snap:    snapshot{current: "sess", panes: panes, states: states, lingering: lingeringSubagents(panes, states, nil)},
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
		Instance: inst, ParentInstance: parent, TS: testAt,
	}
}

// deadSubagentPane is a finished subagent's window as the sweep sees it
// during its linger: its record is gone (nothing in states names its
// pane), but the window mark kido spawn_subagent wrote survives, since only the
// state record and the mark's own "run=" prefix are removed by
// kido agent-status --remove.
func deadSubagentPane(w, pane, parentInstance string) tmux.Pane {
	return tmux.Pane{
		SessionName: "sess", WindowID: w, PaneID: pane,
		Dead: true, Subagent: tmux.SubagentMark("", parentInstance, 1),
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
		"┌◼ orchestrator",
		"│ └◼ subagent",
		"└ zsh",
	})
}

// TestRenderFieldCasesAlignBesideEachOther pins all three of field()'s
// cases in one screen, since that is exactly where the single-space
// change (one space between the tree glyph and the label, not two) is
// easiest to get wrong: an indicator glyph sitting flush against its tree
// glyph, a known pane with nothing to say keeping the same two-column
// width so its title still lines up with the indicator row above it, and
// a shell with no OSC 133 integration at all getting no field - so its
// title starts one column earlier than the other two, which is the tell,
// not a bug.
func TestRenderFieldCasesAlignBesideEachOther(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@1", "%1", "orchestrator"),
		{SessionName: "sess", WindowID: "@1", PaneID: "%2", Title: "idle-agent"},
		shellPane("@1", "%3"),
	}
	states := map[string]state.Session{
		"%1": agentState("root-inst", "", "orchestrator"),
		"%2": {Agent: state.AgentPi, Status: state.Idle, Title: "idle-agent", Instance: "idle-inst", TS: testAt},
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"┌◼ orchestrator",
		"├  idle-agent",
		"└ zsh",
	})
}

// TestRenderGroupsSiblingSubagents is the user's own sketch: a parent
// with several live subagents reads as one bracket around all of them -
// ├ for each sibling but the last, └ for the last - rather than as a run
// of identical dots that says nothing about them belonging together.
func TestRenderGroupsSiblingSubagents(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@13", "%22", "orchestrator"),
		shellPane("@13", "%47"),
		agentPane("@20", "%30", "subagent-a"),
		agentPane("@21", "%31", "subagent-b"),
		agentPane("@22", "%32", "subagent-c"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
		"%30": agentState("kid-a-inst", "root-inst", "subagent-a"),
		"%31": agentState("kid-b-inst", "root-inst", "subagent-b"),
		"%32": agentState("kid-c-inst", "root-inst", "subagent-c"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"┌◼ orchestrator",
		"│ ├◼ subagent-a",
		"│ ├◼ subagent-b",
		"│ └◼ subagent-c",
		"└ zsh",
	})
}

// TestRenderGroupsSiblingSubagentsWithTheirOwnShells is the two-pane
// sibling in that same group: since this fix its own ┌…└ bracket keeps
// its full span beside the group glyph, one column further in, rather
// than losing row 0 to it - a two-pane child reads as its own window
// with the group glyph marking it as anchored, not as a run of rows the
// group glyph has partly swallowed.
func TestRenderGroupsSiblingSubagentsWithTheirOwnShells(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@13", "%22", "orchestrator"),
		agentPane("@20", "%30", "subagent-a"),
		shellPane("@20", "%40"),
		agentPane("@21", "%31", "subagent-b"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
		"%30": agentState("kid-a-inst", "root-inst", "subagent-a"),
		"%31": agentState("kid-b-inst", "root-inst", "subagent-b"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ orchestrator",
		"  ├┌◼ subagent-a",
		"  │└ zsh",
		"  └◼ subagent-b",
	})
}

// TestRenderGroupsSiblingSubagentsAtDepthTwo is the sketch generalised one
// level further: subagent-a has a lone grandchild of its own, which gets
// a group glyph too (a group of one), hanging off the group's own │
// continuation, and subagent-b's grandchildren form a group of their
// own, nested inside a group nested inside a group.
func TestRenderGroupsSiblingSubagentsAtDepthTwo(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@1", "%1", "root"),
		agentPane("@2", "%2", "subagent-a"),
		agentPane("@3", "%3", "subagent-b"),
		agentPane("@4", "%4", "grandkid-a1"),
		agentPane("@5", "%5", "grandkid-b1"),
		agentPane("@6", "%6", "grandkid-b2"),
	}
	states := map[string]state.Session{
		"%1": agentState("root-inst", "", "root"),
		"%2": agentState("a-inst", "root-inst", "subagent-a"),
		"%3": agentState("b-inst", "root-inst", "subagent-b"),
		"%4": agentState("a1-inst", "a-inst", "grandkid-a1"),
		"%5": agentState("b1-inst", "b-inst", "grandkid-b1"),
		"%6": agentState("b2-inst", "b-inst", "grandkid-b2"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ root",
		"  ├◼ subagent-a",
		"  │ └◼ grandkid-a1",
		"  └◼ subagent-b",
		"    ├◼ grandkid-b1",
		"    └◼ grandkid-b2",
	})
}

// TestRenderGroupsSiblingSubagentsWithADeadOne checks the × treatment
// survives grouping: a lingering dead sibling keeps its dim × and label
// while still taking its ├/└ place among its live siblings.
func TestRenderGroupsSiblingSubagentsWithADeadOne(t *testing.T) {
	id := newRun(t, "subagent-b", "")
	panes := []tmux.Pane{
		agentPane("@13", "%22", "orchestrator"),
		agentPane("@20", "%30", "subagent-a"),
		lingeringSubagentPane("@21", "%31", id, "root-inst"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
		"%30": agentState("kid-a-inst", "root-inst", "subagent-a"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ orchestrator",
		"  ├◼ subagent-a",
		"  └× subagent-b",
	})
}

// TestRenderMultipleTopLevelAgentsInOneWindow checks that root-level
// agents sharing a window - not a subagent group at all, just two panes
// of one window - are unaffected by grouping: the window's own ┌/└/├
// bracket draws them exactly as it always has, since neither anchors the
// other.
func TestRenderMultipleTopLevelAgentsInOneWindow(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@1", "%1", "first"),
		agentPane("@1", "%2", "second"),
	}
	states := map[string]state.Session{
		"%1": agentState("first-inst", "", "first"),
		"%2": agentState("second-inst", "", "second"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"┌◼ first",
		"└◼ second",
	})
}

// TestRenderKeepsTheColumnAcrossANestedChild is the case the glyphs make
// awkward: a three-pane window with a subagent hanging off its middle
// pane. The parent's column is carried down the left of the child's rows
// with a stem, so the bracket still reads as one window with a block
// nested inside it. The child is also the lone-child-with-two-panes case:
// since this fix its own ┌…└ bracket keeps its full span, one column in
// from the group glyph (a group of one), rather than losing row 0 to it.
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
		"├◼ orchestrator",
		"│ └┌◼ subagent",
		"│  └ zsh",
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
		"└◼ orchestrator",
		"  └◼ subagent",
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
			Instance: "kid-inst", ParentInstance: "root-inst", Depth: 1, TS: testAt},
		"%3": {Agent: state.AgentPi, Status: state.Running, Title: "grandkid",
			Instance: "gk-inst", ParentInstance: "kid-inst", Depth: 1, TS: testAt},
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ root",
		"  └◼ kid",
		"    └◼ grandkid",
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
			Instance: "orphan-inst", ParentInstance: "elsewhere-inst", Depth: 1, TS: testAt},
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ unrelated",
		"╶◼ orphan",
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
	if rows[1] != "╶◼ a" {
		t.Errorf("rows[1] = %q, want the first member of the ring drawn as a root", rows[1])
	}
	if rows[2] != "  └◼ b" && rows[2] != "╶◼ b" {
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
		"┌◼ root",
		"│ ├◼ kid-a",
		"│ └◼ kid-b",
		"│   └◼ grandkid",
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
	anchors := anchorsOf(got)
	// The anchor is the pane the parent agent runs in, not its window.
	for id, wantAnchor := range map[string]string{"@shell": "", "@root": "", "@child2": "%root", "@child1": "%root"} {
		if anchors[id] != wantAnchor {
			t.Errorf("anchor[%s] = %q, want %q", id, anchors[id], wantAnchor)
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
	for _, pl := range got {
		if pl.anchor != "" {
			t.Errorf("anchor[%s] = %q, want none: its parent is in no window of this session, so there is no edge to hang it off",
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
	// Each hangs off the pane of its own parent, which is what
	// appendWindows recurses through to indent: one level for the kid, two
	// for the grandkid, whatever Depth either reported.
	anchors := anchorsOf(got)
	if anchors["@kid"] != "%root" || anchors["@grandkid"] != "%kid" {
		t.Errorf("anchors = kid %q, grandkid %q; want %%root and %%kid", anchors["@kid"], anchors["@grandkid"])
	}
}

// TestOrderWindowsByTreeHandlesCycle checks that a bogus ParentInstance
// naming a window's own descendant (or itself) never drops a window from
// the result - only from wherever the cycle would have placed it - the
// same guarantee orderTree (cmd/kido/agents.go) makes. The placement
// walk must survive it too: it runs over the ordered result exactly
// once, so a ring cannot make it recurse.
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
	if got[0].anchor != "" {
		t.Errorf("the first window of a cycle is drawn as a root, want no anchor, got %q", got[0].anchor)
	}
}

// TestOrderWindowsByTreeFallsBackToMarkWhenRecordGone is the bug this
// walk used to have: a finished subagent's record is removed on exit
// (kido agent-status --remove) while its window lingers for the sweep.
// With no record at all for the window, the parent comes from the
// window mark instead of dropping to a root.
func TestOrderWindowsByTreeFallsBackToMarkWhenRecordGone(t *testing.T) {
	windows := [][]tmux.Pane{
		{{PaneID: "%root", WindowID: "@root"}},
		{deadSubagentPane("@kid", "%kid", "root-inst")},
	}
	states := map[string]state.Session{
		"%root": {Instance: "root-inst"},
	}
	got := orderWindowsByTree(windows, states)
	if !sameIDs(windowIDs(got), []string{"@root", "@kid"}) {
		t.Fatalf("order = %v, want the marked window to follow its marked parent", windowIDs(got))
	}
	if a := anchorsOf(got)["@kid"]; a != "%root" {
		t.Errorf("anchor[@kid] = %q, want %%root: the mark says its parent is @root", a)
	}
}

// TestOrderWindowsByTreeRecordBeatsStaleMark checks requirement 1: the
// record stays authoritative whenever it exists, even one that disagrees
// with the mark - a live subagent moved or reparented by
// kido spawn_subagent --resume, whose window mark was written once at creation
// and is never rewritten to match.
func TestOrderWindowsByTreeRecordBeatsStaleMark(t *testing.T) {
	windows := [][]tmux.Pane{
		{{PaneID: "%root", WindowID: "@root"}},
		{{PaneID: "%other", WindowID: "@other"}},
		{{PaneID: "%kid", WindowID: "@kid", Subagent: tmux.SubagentMark("run-1", "other-inst", 1)}},
	}
	states := map[string]state.Session{
		"%root":  {Instance: "root-inst"},
		"%other": {Instance: "other-inst"},
		"%kid":   {Instance: "kid-inst", ParentInstance: "root-inst"},
	}
	got := orderWindowsByTree(windows, states)
	for _, pl := range got {
		if pl.panes[0].WindowID == "@kid" && pl.anchor != "%root" {
			t.Errorf("anchor[@kid] = %q, want %%root: the live record names root-inst, not the mark's other-inst", pl.anchor)
		}
	}
}

// TestOrderWindowsByTreeMarkedOrphanIsRoot is the marked counterpart of
// TestOrderWindowsByTreeIndentsOnlyRealChildren: a window whose record is
// gone and whose mark names a parent instance that is not in this
// session (moved away, or a stale mark from a previous server) is drawn
// flush left, not hung off whatever row precedes it.
func TestOrderWindowsByTreeMarkedOrphanIsRoot(t *testing.T) {
	windows := [][]tmux.Pane{
		{{PaneID: "%shell", WindowID: "@shell"}},
		{deadSubagentPane("@kid", "%kid", "elsewhere-inst")},
	}
	got := orderWindowsByTree(windows, map[string]state.Session{})
	if !sameIDs(windowIDs(got), []string{"@shell", "@kid"}) {
		t.Fatalf("order = %v, want both windows kept in tmux's own order", windowIDs(got))
	}
	if a := anchorsOf(got)["@kid"]; a != "" {
		t.Errorf("anchor[@kid] = %q, want none: its marked parent is in no window of this session", a)
	}
	for _, pl := range got {
		if pl.anchor != "" {
			t.Errorf("anchor[%s] = %q, want none", pl.panes[0].WindowID, pl.anchor)
		}
	}
}

// TestOrderWindowsByTreeMarkFallbackDropsNothing is requirement 4 for the
// mark fallback specifically: a mark naming a parent instance that
// exists nowhere at all - not even in another session's row - still
// keeps the window in the result, drawn as a root.
func TestOrderWindowsByTreeMarkFallbackDropsNothing(t *testing.T) {
	windows := [][]tmux.Pane{
		{deadSubagentPane("@kid", "%kid", "nonexistent-inst")},
	}
	got := orderWindowsByTree(windows, map[string]state.Session{})
	if !sameIDs(windowIDs(got), []string{"@kid"}) {
		t.Fatalf("order = %v, want the window kept even though its marked parent doesn't exist", windowIDs(got))
	}
}

// TestRenderNestsADeadSubagentForTheWholeLinger is the bug report itself,
// as a rendered screen: a finished subagent's record is removed while
// its dead-paned window lingers for the sweep, and it must stay nested
// under its parent's pane rather than jump to the left margin for the
// whole linger.
func TestRenderNestsADeadSubagentForTheWholeLinger(t *testing.T) {
	panes := []tmux.Pane{
		agentPane("@13", "%22", "orchestrator"),
		deadSubagentPane("@20", "%30", "root-inst"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
	}
	// Before the fix this rendered as two flush-left rows: "sess",
	// "╶◼ orchestrator", "╶ " (the dead pane un-nested at the left
	// margin, no longer indented under its parent) - exactly during the
	// window the user is most likely to be looking at it to read its last
	// screen.
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ orchestrator",
		"  └ ",
	})
}

// lingeringSubagentPane is a finished subagent's window carrying a real
// run id in its mark, unlike deadSubagentPane's empty one, so
// lingeringSubagents has something to look up on disk.
func lingeringSubagentPane(w, pane, runID, parentInstance string) tmux.Pane {
	return tmux.Pane{
		SessionName: "sess", WindowID: w, PaneID: pane,
		Dead: true, Subagent: tmux.SubagentMark(runID, parentInstance, 1),
	}
}

// liveSubagentPane is lingeringSubagentPane's alive twin: a marked window
// with a real run id but no state record for its pane, and Dead false -
// a plain `bash` run for its whole life, or an agent run in the window
// between new-window and its first status report.
func liveSubagentPane(w, pane, runID, parentInstance string) tmux.Pane {
	return tmux.Pane{
		SessionName: "sess", WindowID: w, PaneID: pane,
		Dead: false, Subagent: tmux.SubagentMark(runID, parentInstance, 1),
	}
}

// newRun writes a run's meta (and, if result != "", its outcome) under a
// fresh KIDO_STATE_DIR and returns its id.
func newRun(t *testing.T, name string, result subrun.Result) string {
	t.Helper()
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := subrun.NewID()
	if err := subrun.Create(id, "task"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{ID: id, Name: name}); err != nil {
		t.Fatal(err)
	}
	if result != "" {
		if err := subrun.RecordOutcome(id, subrun.Outcome{Result: result}); err != nil {
			t.Fatal(err)
		}
	}
	return id
}

// TestRenderLingeringSubagentShowsItsOwnName is the identity half of the
// bug report: a lingering window with no record must show the run's own
// name, not the bare pane command (CurrentCommand is empty here, the way
// a dead pane's is; the live bug reads "pi", but either way it is not
// the run's name).
func TestRenderLingeringSubagentShowsItsOwnName(t *testing.T) {
	id := newRun(t, "fix the flaky test", "")
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}
	rows := renderRows(panes, nil)
	wantRows(t, rows, []string{
		"sess",
		"╶× fix the flaky test",
	})
}

// TestRenderLingeringSubagentLooksDead checks the row is visibly distinct
// from every live status glyph, not just from a bare pane command: the ×
// this task adds must not collide with anything indicator() or
// indicatorDone()/indicatorFailed() already draws for a live pane.
func TestRenderLingeringSubagentLooksDead(t *testing.T) {
	id := newRun(t, "subagent", "")
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}
	rows := renderRows(panes, nil)
	row := rows[1]
	if !strings.Contains(row, "×") {
		t.Fatalf("row = %q, want the dead glyph ×", row)
	}
	for _, live := range []string{"◼", "◆", "◌", "✓", "!"} {
		if strings.Contains(row, live) {
			t.Errorf("row = %q, contains %q, a live status glyph", row, live)
		}
	}
}

// TestRenderLiveMarkedPaneWithNoRecordShowsRunning is the bug fix itself:
// a marked pane whose run has no state record yet, but whose process is
// still alive, must not read as dead for however long it takes that
// record to appear (a bash run under async_bash never writes one at
// all). It renders as a running row - the same ◼ field an agent pane
// gets - labelled from the run's own meta name, not dimmed like the
// tombstone.
func TestRenderLiveMarkedPaneWithNoRecordShowsRunning(t *testing.T) {
	id := newRun(t, "make build", "")
	panes := []tmux.Pane{liveSubagentPane("@20", "%30", id, "")}
	wantRows(t, renderRows(panes, nil), []string{
		"sess",
		"╶◼ make build",
	})
}

// TestRenderDeadMarkedPaneWithNoRecordStaysTombstone is the negative
// control TestRenderLiveMarkedPaneWithNoRecordShowsRunning is unsafe
// without: without it, a fix that rendered every marked pane with no
// record as running - live or dead - would pass the positive case too.
// A dead pane keeps exactly today's tombstone: the dimmed name and, once
// recorded, its outcome.
func TestRenderDeadMarkedPaneWithNoRecordStaysTombstone(t *testing.T) {
	id := newRun(t, "make build", "")
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}
	wantRows(t, renderRows(panes, nil), []string{
		"sess",
		"╶× make build",
	})
}

// TestRenderSplitPaneOfALiveRunIsAnOrdinaryPane is the bug itself: the
// user split a running bash/agent window, and the split pane must draw
// as a plain shell rather than as a second copy of the run. Only the
// pane createRunWindow actually marked with SubagentPane carries the
// running label; its sibling, which inherits the window-scoped Subagent
// through tmux's own option fallback but carries no SubagentPane of its
// own, falls through to the ordinary pane path.
func TestRenderSplitPaneOfALiveRunIsAnOrdinaryPane(t *testing.T) {
	id := newRun(t, "make build", "")
	runPane := liveSubagentPane("@20", "%30", id, "")
	runPane.SubagentPane = id
	split := shellPane("@20", "%31")
	split.Subagent = runPane.Subagent // the window mark, inherited by every pane
	wantRows(t, renderRows([]tmux.Pane{runPane, split}, nil), []string{
		"sess",
		"┌◼ make build",
		"└ zsh",
	})
}

// TestRenderMarkedWindowWithNoPaneOptionKeepsTodaysBehaviour is the
// negative control: a window marked before SubagentPane existed, where
// no pane carries it, must not un-nest or drop the run label - every
// unreported pane of it keeps drawing as the run in progress, exactly as
// it always has, rather than being refused the label just because none
// of its panes can prove ownership.
func TestRenderMarkedWindowWithNoPaneOptionKeepsTodaysBehaviour(t *testing.T) {
	id := newRun(t, "make build", "")
	runPane := liveSubagentPane("@20", "%30", id, "")
	split := liveSubagentPane("@20", "%31", id, "")
	wantRows(t, renderRows([]tmux.Pane{runPane, split}, nil), []string{
		"sess",
		"┌◼ make build",
		"└◼ make build",
	})
}

// TestRenderReproducesTheLiveSplitBugReport is the exact incident: the
// user switched to a keepAlive pi named "helper" (one pane, reported and
// idle) and split it, leaving the window [zsh split %5, pi %4] in tmux's
// own list-panes order - the split newer and so, under split -b, listed
// first. Sorted to creation order (tmux.OrderSessions) the reported pi
// %4 comes first regardless, its own SubagentPane keeps the zsh split
// from ever being mistaken for the run, and the two-pane anchored window
// draws its own bracket beside the group glyph rather than losing row 0
// to it.
func TestRenderReproducesTheLiveSplitBugReport(t *testing.T) {
	pi := agentPane("@20", "%4", "helper")
	pi.SubagentPane = "run-1"
	pi.Subagent = tmux.SubagentMark("run-1", "root-inst", 1)
	split := shellPane("@20", "%5")
	split.Subagent = pi.Subagent // the window mark, inherited by every pane
	panes := []tmux.Pane{
		agentPane("@13", "%22", "working-on-kido"),
		split, // listed before pi, as tmux would after `split-window -b`
		pi,
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "working-on-kido"),
		"%4":  {Agent: state.AgentPi, Status: state.Idle, Title: "helper", Instance: "helper-inst", ParentInstance: "root-inst", TS: testAt},
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ working-on-kido",
		"  └┌  helper",
		"   └ zsh",
	})
}

// TestRenderLiveSubagentWithRecordUnaffected pins that this change is
// scoped to marked-and-unreported panes only: a live subagent that has
// already reported keeps taking the agent-row path entirely, never
// lingeringLabel, whether its pane happens to be alive or dead.
func TestRenderLiveSubagentWithRecordUnaffected(t *testing.T) {
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
		"┌◼ orchestrator",
		"│ └◼ subagent",
		"└ zsh",
	})
}

// TestRenderLingeringSubagentShowsOutcome checks the second half: when a
// sweep or the subagent's own run-outcome call has recorded how the run
// ended, the row shows it. A completed run also swaps the glyph for a
// dimmed checkmark rather than the cross - see TestRenderLingeringSubagentGlyphByOutcome.
func TestRenderLingeringSubagentShowsOutcome(t *testing.T) {
	id := newRun(t, "subagent", subrun.Completed)
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}
	wantRows(t, renderRows(panes, nil), []string{
		"sess",
		"╶✓ subagent  completed",
	})
}

// TestRenderLingeringSubagentGlyphByOutcome is the glyph choice itself:
// a completed run gets the dimmed checkmark, since it is the same claim
// indicatorDone makes for a live agent's finished turn, just weaker; a
// failed or died run keeps the cross, since neither is a claim of
// success; and a run somebody stopped keeps the cross too, because ending
// deliberately is not finishing the work - a checkmark would claim it did
// what it did not.
func TestRenderLingeringSubagentGlyphByOutcome(t *testing.T) {
	cases := []struct {
		result subrun.Result
		glyph  string
	}{
		{subrun.Completed, "✓"},
		{subrun.Failed, "×"},
		{subrun.Died, "×"},
		{subrun.Stopped, "×"},
	}
	for _, c := range cases {
		id := newRun(t, "subagent", c.result)
		panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}
		row := renderRows(panes, nil)[1]
		if !strings.Contains(row, c.glyph) {
			t.Errorf("result %q: row = %q, want glyph %q", c.result, row, c.glyph)
		}
		other := "✓"
		if c.glyph == "✓" {
			other = "×"
		}
		if strings.Contains(row, other) {
			t.Errorf("result %q: row = %q, want no %q", c.result, row, other)
		}
	}
}

// TestRenderLingeringSubagentNoOutcomeKeepsCross checks the honesty rule:
// a window that has just died with no outcome recorded yet must not show
// the checkmark, since nothing has confirmed it finished successfully -
// only its arrival, already covered by TestRenderLingeringSubagentInventsNoOutcome,
// turns the row from a name into a verdict.
func TestRenderLingeringSubagentNoOutcomeKeepsCross(t *testing.T) {
	id := newRun(t, "subagent", "")
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}
	row := renderRows(panes, nil)[1]
	if !strings.Contains(row, "×") {
		t.Errorf("row = %q, want the cross while no outcome is recorded", row)
	}
	if strings.Contains(row, "✓") {
		t.Errorf("row = %q, want no checkmark before an outcome is recorded", row)
	}
}

// TestRenderLingeringSubagentInventsNoOutcome is the other side of that:
// absence of a recorded outcome must not be guessed at, because a sweep
// writes Died a moment later for a genuine crash and "not known yet" is
// the honest answer until then.
func TestRenderLingeringSubagentInventsNoOutcome(t *testing.T) {
	id := newRun(t, "subagent", "")
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}
	row := renderRows(panes, nil)[1]
	for _, guess := range []string{"completed", "failed", "stopped", "died"} {
		if strings.Contains(row, guess) {
			t.Errorf("row = %q, invented an outcome %q nobody recorded", row, guess)
		}
	}
}

// TestRenderLiveSubagentUnaffectedByLingering is the regression that
// matters most: a live subagent with a record still renders its status
// indicator and title exactly as before, never the lingering label - the
// lingering path is only reachable through paneLabel's !isAgent branch.
func TestRenderLiveSubagentUnaffectedByLingering(t *testing.T) {
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
		"┌◼ orchestrator",
		"│ └◼ subagent",
		"└ zsh",
	})
}

// TestRenderLingeringSubagentMissingRunDirDegradesGracefully covers a
// mark whose run directory was never created, or has since been removed:
// lingeringSubagents must skip it rather than error out or panic, and
// the row falls back to the plain pane-command label it always had.
func TestRenderLingeringSubagentMissingRunDirDegradesGracefully(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", "no-such-run", "")}
	rows := renderRows(panes, nil)
	wantRows(t, rows, []string{
		"sess",
		"╶ ",
	})
}

// TestLingeringSubagentsCarryForward pins what the previous tick's
// answer is for. A lingering window's name never changes (subrun.Meta is
// written once at spawn) and the sidebar ticks ten times a second for
// the whole ~30s linger, so re-reading it is some six hundred pointless
// file opens per finished subagent. Carrying the entry forward is
// asserted the only way that cannot pass by accident: the meta file is
// deleted between the two calls, so an implementation that re-reads
// loses the name outright.
//
// The outcome is the deliberate exception and the second half of this
// test: a carried entry without one is asked again each tick, because
// that file appears later - written by the child as it exits, or by the
// sweep on its behalf - and it is the only thing about the row still
// able to change.
func TestLingeringSubagentsCarryForward(t *testing.T) {
	id := newRun(t, "subagent", "")
	panes := []tmux.Pane{lingeringSubagentPane("@20", "%30", id, "")}

	first := lingeringSubagents(panes, nil, nil)
	if first[id].name != "subagent" || first[id].outcomeOK {
		t.Fatalf("first read = %+v, want the run's name and no outcome yet", first[id])
	}

	if err := os.Remove(filepath.Join(subrun.Dir(), id, "meta.json")); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome(id, subrun.Outcome{Result: subrun.Completed}); err != nil {
		t.Fatal(err)
	}

	next := lingeringSubagents(panes, nil, first)
	if next[id].name != "subagent" {
		t.Errorf("name = %q, want it carried forward from the previous tick rather than re-read", next[id].name)
	}
	if !next[id].outcomeOK || next[id].outcome != subrun.Completed {
		t.Errorf("outcome = %+v, want the outcome recorded since the previous tick to be picked up", next[id])
	}
}

// TestLingeringSubagentsRecoversPaneSeenLate pins the real race the split
// fix has: createRunWindow issues the window mark and the pane mark as
// two separate tmux commands, so a tick that reacts to the window's own
// %window-add notification can poll in between them, before the pane
// mark exists at all - measured live, in
// TestSidebarShowsASplitBashRunPaneAsAnOrdinaryShell (e2e), which failed
// every run against the version of this function that only ever set
// `pane` once, at creation. Reusing that first, paneless reading forever
// would draw every unreported pane of the window as the run for its
// whole life, exactly the bug this whole change fixes - so the pane must
// be recovered from a later tick's panes rather than frozen empty.
func TestLingeringSubagentsRecoversPaneSeenLate(t *testing.T) {
	id := newRun(t, "split-e2e", "")
	runPane := liveSubagentPane("@20", "%1", id, "")
	// The first tick observes the window mark but not yet the pane mark,
	// as a tick landing between the two separate set-option calls would.
	first := lingeringSubagents([]tmux.Pane{runPane}, nil, nil)
	if first[id].pane != "" {
		t.Fatalf("first read pane = %q, want \"\" (the pane mark not observed yet)", first[id].pane)
	}

	runPane.SubagentPane = id
	split := shellPane("@20", "%2")
	split.Subagent = runPane.Subagent
	next := lingeringSubagents([]tmux.Pane{runPane, split}, nil, first)
	if next[id].pane != "%1" {
		t.Errorf("pane = %q after the pane mark appeared, want %%1 recovered rather than staying \"\" forever", next[id].pane)
	}
}

// TestRenderLingeringSubagentStillNests is f430308's fix, checked again
// with a real run id in the mark rather than the empty one
// deadSubagentPane uses: the identity fix must not cost the place fix.
func TestRenderLingeringSubagentStillNests(t *testing.T) {
	id := newRun(t, "subagent", "")
	panes := []tmux.Pane{
		agentPane("@13", "%22", "orchestrator"),
		lingeringSubagentPane("@20", "%30", id, "root-inst"),
	}
	states := map[string]state.Session{
		"%22": agentState("root-inst", "", "orchestrator"),
	}
	wantRows(t, renderRows(panes, states), []string{
		"sess",
		"╶◼ orchestrator",
		"  └× subagent",
	})
}
