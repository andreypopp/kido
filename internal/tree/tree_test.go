package tree

import (
	"fmt"
	"strings"
	"testing"
)

// node is the smallest thing Order can be asked about: an id and the id it
// names as its parent.
type node struct{ id, parent string }

func order(items []node) []string {
	var ids []string
	for _, n := range Order(items, func(n node) string { return n.id }, func(n node) string { return n.parent }) {
		ids = append(ids, n.id)
	}
	return ids
}

// TestOrderKeepsEveryItem pins that whatever the parent edges say, the
// output is always a permutation of the input: a dropped item is the
// one failure mode that matters more than any ordering.
func TestOrderKeepsEveryItem(t *testing.T) {
	cases := map[string][]node{
		"empty":               nil,
		"one root":            {{"a", ""}},
		"self-parent":         {{"a", "a"}},
		"two-cycle":           {{"a", "b"}, {"b", "a"}},
		"three-cycle":         {{"a", "c"}, {"b", "a"}, {"c", "b"}},
		"cycle with a child":  {{"a", "b"}, {"b", "a"}, {"c", "a"}},
		"absent parent":       {{"a", "ghost"}, {"b", ""}},
		"duplicate ids":       {{"a", ""}, {"a", ""}, {"b", "a"}},
		"chain four deep":     {{"d", "c"}, {"c", "b"}, {"b", "a"}, {"a", ""}},
		"two roots, one deep": {{"a", ""}, {"b", "a"}, {"c", ""}, {"d", "b"}},
	}
	for name, items := range cases {
		got := order(items)
		if len(got) != len(items) {
			t.Errorf("%s: Order returned %d items (%v) for %d (%v)", name, len(got), got, len(items), items)
			continue
		}
		want := map[string]int{}
		for _, n := range items {
			want[n.id]++
		}
		for _, id := range got {
			want[id]--
		}
		for id, n := range want {
			if n != 0 {
				t.Errorf("%s: id %q appears %d time(s) too few in %v", name, id, n, got)
			}
		}
	}
}

// TestOrderIsParentFirstAndStable pins that a child follows its parent,
// and anything not in a tree keeps the order it arrived in.
func TestOrderIsParentFirstAndStable(t *testing.T) {
	items := []node{
		{"shell", ""},
		{"kid2", "top"},
		{"top", ""},
		{"kid1", "top"},
		{"grandkid", "kid2"},
	}
	want := "shell,top,kid2,grandkid,kid1"
	if got := strings.Join(order(items), ","); got != want {
		t.Errorf("Order = %s, want %s", got, want)
	}
}

// TestOrderIsDeterministic pins that repeated runs over identical input
// agree, guarding against a walk depending on Go's map iteration order.
func TestOrderIsDeterministic(t *testing.T) {
	var items []node
	for i := range 40 {
		parent := ""
		if i > 0 {
			parent = fmt.Sprint(i % 7)
		}
		items = append(items, node{fmt.Sprint(i), parent})
	}
	first := strings.Join(order(items), ",")
	for i := range 20 {
		if got := strings.Join(order(items), ","); got != first {
			t.Fatalf("run %d = %s, want %s", i, got, first)
		}
	}
}
