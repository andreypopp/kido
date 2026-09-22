package ui

import (
	"testing"

	"kido/internal/state"
	"kido/internal/tmux"
)

func windowIDs(windows [][]tmux.Pane) []string {
	var ids []string
	for _, w := range windows {
		ids = append(ids, w[0].WindowID)
	}
	return ids
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
	got, depth := orderWindowsByTree(windows, states)
	want := []string{"@shell", "@root", "@child2", "@child1"}
	if !sameIDs(windowIDs(got), want) {
		t.Fatalf("order = %v, want %v", windowIDs(got), want)
	}
	for id, wantDepth := range map[string]int{"@shell": 0, "@root": 0, "@child2": 1, "@child1": 1} {
		if depth[id] != wantDepth {
			t.Errorf("depth[%s] = %d, want %d", id, depth[id], wantDepth)
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
	got, depth := orderWindowsByTree(windows, states)
	if !sameIDs(windowIDs(got), []string{"@shell", "@orphan"}) {
		t.Fatalf("order = %v, want tmux's own order kept", windowIDs(got))
	}
	if depth["@orphan"] != 0 {
		t.Errorf("depth[@orphan] = %d, want 0: its parent is in no window of this session", depth["@orphan"])
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
	got, depth := orderWindowsByTree(windows, states)
	if !sameIDs(windowIDs(got), []string{"@root", "@kid", "@grandkid"}) {
		t.Fatalf("order = %v, want parent-first", windowIDs(got))
	}
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
	got, depth := orderWindowsByTree(windows, states)
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
	if depth[windowIDs(got)[0]] != 0 {
		t.Errorf("the first window of a cycle is drawn as a root, want depth 0, got %d", depth[windowIDs(got)[0]])
	}
}
