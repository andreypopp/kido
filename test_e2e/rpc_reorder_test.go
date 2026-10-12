package e2e

import (
	"fmt"
	"strings"
	"testing"
)

func (f *feed) sessionOrder() []string {
	var ids []string
	for _, s := range f.last().Sessions {
		ids = append(ids, s.ID)
	}
	return ids
}

func (f *feed) waitSessionOrder(want ...string) {
	f.h.t.Helper()
	f.waitLast(func(s feedSnapshot) bool {
		return strings.Join(f.sessionOrder(), " ") == strings.Join(want, " ")
	}, fmt.Sprintf("sessions in order %v", want))
}

func (f *feed) waitRootOrder(session string, want ...string) {
	f.h.t.Helper()
	f.waitLast(func(s feedSnapshot) bool {
		for _, sess := range s.Sessions {
			if sess.ID == session {
				var got []string
				for _, n := range sess.Nodes {
					got = append(got, *n.Window)
				}
				return strings.Join(got, " ") == strings.Join(want, " ")
			}
		}
		return false
	}, fmt.Sprintf("windows of %s in order %v", session, want))
}

func (h *harness) windowOrder(session string) string {
	h.t.Helper()
	return strings.ReplaceAll(h.in("list-windows", "-t", session+":", "-F", "#{window_id}"), "\n", " ")
}

// A reordered session stays where it was put for the sidebar, the feed and
// switch-session alike, and a session created afterwards appends after the
// ranked ones even though it is the newest.
func TestRpcReorderSession(t *testing.T) {
	t.Parallel()
	h := start(t, "ses-a")
	h.newSessionSpaced("ses-b")
	h.newSessionSpaced("ses-c")
	id := func(name string) string { return h.in("display-message", "-p", "-t", name+":", "#{session_id}") }
	a, b, c := id("ses-a"), id("ses-b"), id("ses-c")
	f := h.startFeed("ses-a")
	f.waitSessionOrder(a, b, c)

	f.send(fmt.Sprintf(`{"id":1,"reorder-session":{"session":%q,"relative-to":%q,"placement":"before"}}`, c, a))
	f.waitReply(`{"reply":{"id":1,"reordered":true}}`)
	f.waitSessionOrder(c, a, b)
	f.send(fmt.Sprintf(`{"id":2,"reorder-session":{"session":%q,"relative-to":%q,"placement":"after"}}`, a, b))
	f.waitReply(`{"reply":{"id":2,"reordered":true}}`)
	f.waitSessionOrder(c, b, a)
	ranked := func(order ...string) {
		t.Helper()
		for rank, s := range order {
			if got := h.in("show-options", "-v", "-t", s, "@kido-order"); got != fmt.Sprint(rank) {
				t.Fatalf("%s @kido-order = %q, want %d", s, got, rank)
			}
		}
	}
	ranked(c, b, a)
	if got := h.in("show-options", "-gqv", "@kido-order"); got != "" {
		t.Fatalf("global @kido-order = %q, want unset", got)
	}
	h.waitFor(func() bool {
		ic, ib, ia := h.rowIndex("ses-c"), h.rowIndex("ses-b"), h.rowIndex("ses-a")
		return ic > 0 && ic < ib && ib < ia
	}, settle, msgf("sidebar rows ses-c, ses-b, ses-a"))

	h.newSessionSpaced("ses-d")
	d := id("ses-d")
	f.waitSessionOrder(c, b, a, d)

	h.waitSession("ses-a")
	for _, step := range []struct{ dir, want string }{
		{"next", "ses-d"}, {"next", "ses-c"}, {"next", "ses-b"}, {"prev", "ses-c"}, {"prev", "ses-d"},
	} {
		h.runSwitchSession(step.dir)
		h.waitSession(step.want)
	}

	f.send(fmt.Sprintf(`{"id":3,"reorder-session":{"session":%q,"relative-to":%q,"placement":"before"}}`, d, c))
	f.waitReply(`{"reply":{"id":3,"reordered":true}}`)
	f.waitSessionOrder(d, c, b, a)

	for i, request := range []string{
		fmt.Sprintf(`{"session":"$999999","relative-to":%q,"placement":"before"}`, a),
		fmt.Sprintf(`{"session":%q,"relative-to":"$999999","placement":"after"}`, a),
		fmt.Sprintf(`{"session":%q,"relative-to":%q,"placement":"after"}`, a, a),
	} {
		f.send(fmt.Sprintf(`{"id":%d,"reorder-session":%s}`, 10+i, request))
	}
	f.waitReply(`{"reply":{"id":10,"error":"no such session"}}`)
	f.waitReply(`{"reply":{"id":11,"error":"no such session"}}`)
	f.waitReply(`{"reply":{"id":12,"error":"cannot reorder relative to itself"}}`)
	ranked(d, c, b, a)
}

// Windows move by tmux insertion within their session; the session's
// current window stays current for its attached client even when it is the
// one moved, and the moves the request refuses leave tmux untouched.
func TestRpcReorderWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "root")
	h.liveParent("a", "root-session")
	h.addWindow("a", "one")
	h.addWindow("a", "two")
	h.newSession("b")
	window := func(target string) string { return h.in("display-message", "-p", "-t", target, "#{window_id}") }
	session := h.in("display-message", "-p", "-t", "a:", "#{session_id}")
	root, one, two, other := window("a:root"), window("a:one"), window("a:two"), window("b:")
	f := h.startFeed("a")
	f.waitRootOrder(session, root, one, two)
	reorder := func(id int, source, anchor, placement string) {
		f.send(fmt.Sprintf(`{"id":%d,"reorder-window":{"session":%q,"window":%q,"relative-to":%q,"placement":%q}}`,
			id, session, source, anchor, placement))
	}

	reorder(1, two, root, "before")
	f.waitReply(`{"reply":{"id":1,"reordered":true}}`)
	if got := h.windowOrder("a"); got != strings.Join([]string{two, root, one}, " ") {
		t.Fatalf("after before: %s", got)
	}
	f.waitRootOrder(session, two, root, one)

	h.selectWindow("a", "root")
	reorder(2, root, one, "after")
	f.waitReply(`{"reply":{"id":2,"reordered":true}}`)
	if got := h.windowOrder("a"); got != strings.Join([]string{two, one, root}, " ") {
		t.Fatalf("after after: %s", got)
	}
	f.waitRootOrder(session, two, one, root)
	for _, c := range []string{h.client, f.client} {
		if got := h.in("display-message", "-p", "-c", c, "#{session_id} #{window_id}"); got != session+" "+root {
			t.Fatalf("client %s on %s, want the moved current window %s %s", c, got, session, root)
		}
	}

	_, child := h.subagentWindow("a", "child", "child-session", "root-session")
	f.waitLast(func(s feedSnapshot) bool {
		for _, sess := range s.Sessions {
			for _, n := range sess.Nodes {
				for _, kid := range n.Children {
					if kid.Window != nil && *kid.Window == child {
						return true
					}
				}
			}
		}
		return false
	}, "the subagent window nested under root")
	before := h.windowOrder("a")
	for i, r := range []struct{ source, anchor, want string }{
		{"@999999", one, "no such top-level window in session"},
		{one, "@999999", "no such top-level window in session"},
		{one, one, "cannot reorder relative to itself"},
		{child, one, "no such top-level window in session"},
		{one, child, "no such top-level window in session"},
		{one, other, "no such top-level window in session"},
	} {
		reorder(10+i, r.source, r.anchor, "before")
		f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,"error":%q}}`, 10+i, r.want))
	}
	f.send(fmt.Sprintf(`{"id":20,"reorder-window":{"session":"$999999","window":%q,"relative-to":%q,"placement":"after"}}`, one, two))
	f.waitReply(`{"reply":{"id":20,"error":"no such top-level window in session"}}`)
	if got := h.windowOrder("a"); got != before {
		t.Fatalf("rejected reorders moved windows: %s, was %s", got, before)
	}
}

func (h *harness) windowIndexes(session string) string {
	h.t.Helper()
	return strings.ReplaceAll(h.in("list-windows", "-t", session+":", "-F", "#{window_id}:#{window_index}:#{window_active}"), "\n", " ")
}

// move-window with -s ignores renumber-windows, so kido compacts after the
// move only when the session's option is on; off, gaps survive. Insertion
// shifts a nested window's index along with its neighbours, while the tree
// keeps it under its parent either way.
func TestRpcReorderWindowRenumber(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "root")
	h.liveParent("a", "root-session")
	_, child := h.subagentWindow("a", "child", "child-session", "root-session")
	h.in("new-window", "-d", "-t", "a:5", "-n", "five")
	h.in("new-window", "-d", "-t", "a:9", "-n", "nine")
	window := func(target string) string { return h.in("display-message", "-p", "-t", target, "#{window_id}") }
	session := h.in("display-message", "-p", "-t", "a:", "#{session_id}")
	root, five, nine := window("a:root"), window("a:five"), window("a:nine")
	h.selectWindow("a", "root")
	f := h.startFeed("a")
	f.waitRootOrder(session, root, five, nine)
	reorder := func(id int, source, anchor, placement string) {
		f.send(fmt.Sprintf(`{"id":%d,"reorder-window":{"session":%q,"window":%q,"relative-to":%q,"placement":%q}}`,
			id, session, source, anchor, placement))
		f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,"reordered":true}}`, id))
	}
	nested := func() bool {
		for _, sess := range f.last().Sessions {
			for _, n := range sess.Nodes {
				if *n.Window == root {
					for _, kid := range n.Children {
						if kid.Window != nil && *kid.Window == child {
							return true
						}
					}
				}
			}
		}
		return false
	}

	h.in("set-option", "-t", session, "renumber-windows", "off")
	reorder(1, five, root, "before")
	want := fmt.Sprintf("%s:0:0 %s:1:1 %s:2:0 %s:9:0", five, root, child, nine)
	if got := h.windowIndexes("a"); got != want {
		t.Fatalf("renumber off: %s, want %s", got, want)
	}
	f.waitRootOrder(session, five, root, nine)
	if !nested() {
		t.Fatalf("child left root: %s", f.last().raw)
	}

	h.in("set-option", "-t", session, "renumber-windows", "on")
	reorder(2, five, nine, "after")
	want = fmt.Sprintf("%s:0:1 %s:1:0 %s:2:0 %s:3:0", root, child, nine, five)
	if got := h.windowIndexes("a"); got != want {
		t.Fatalf("renumber on: %s, want %s", got, want)
	}
	f.waitRootOrder(session, root, nine, five)
	if !nested() {
		t.Fatalf("child left root: %s", f.last().raw)
	}
}

// A move in a grouped session would change the other members' windows, so
// it is refused before anything moves.
func TestRpcReorderWindowGrouped(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "root")
	h.addWindow("a", "one")
	h.in("new-session", "-d", "-t", "a", "-s", "g")
	h.in("select-window", "-t", "g:one")
	window := func(target string) string { return h.in("display-message", "-p", "-t", target, "#{window_id}") }
	root, one := window("a:root"), window("a:one")
	f := h.startFeed("a")
	before, beforeG := h.windowIndexes("a"), h.windowIndexes("g")
	for i, name := range []string{"a", "g"} {
		s := h.in("display-message", "-p", "-t", name+":", "#{session_id}")
		f.send(fmt.Sprintf(`{"id":%d,"reorder-window":{"session":%q,"window":%q,"relative-to":%q,"placement":"after"}}`,
			i, s, root, one))
		f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,"error":"cannot reorder windows in a grouped session"}}`, i))
	}
	if a, g := h.windowIndexes("a"), h.windowIndexes("g"); a != before || g != beforeG {
		t.Fatalf("rejected grouped reorder changed windows: a %s (was %s), g %s (was %s)", a, before, g, beforeG)
	}
}
