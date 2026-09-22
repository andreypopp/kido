// Package tree holds the parent-first walk behind both `kido agents`
// (cmd/kido/agents.go) and the sidebar's window tree (internal/ui).
package tree

// Order returns items parent-first: every item follows the one whose id
// its parent names, recursively. Siblings, roots, and anything not part
// of a tree at all keep the order they arrived in, so a caller wanting a
// particular sibling order (oldest-report-first, for kido agents; tmux's
// own window order, for the sidebar) sorts its input first rather than
// telling Order about it. id must be unique and non-empty; parent
// returns "" for a root, and a parent naming no item in items is a root
// too.
//
// Every item comes out exactly once, tree or no tree: anything a walk
// from the roots missed (a cycle) is emitted afterwards as a root, so a
// nonsense edge costs an item its place in the tree and nothing else.
func Order[T any](items []T, id func(T) string, parent func(T) string) []T {
	index := make(map[string]int, len(items))
	for i, it := range items {
		index[id(it)] = i
	}
	const root = -1
	children := map[int][]int{} // parent's index, or root -> child indices
	for i, it := range items {
		p := root
		// A self-edge is read as "no parent" rather than as a one-item cycle.
		if j, ok := index[parent(it)]; ok && j != i {
			p = j
		}
		children[p] = append(children[p], i)
	}
	out := make([]T, 0, len(items))
	seen := make([]bool, len(items))
	var walk func(parent int)
	walk = func(parent int) {
		for _, i := range children[parent] {
			if seen[i] {
				continue
			}
			seen[i] = true
			out = append(out, items[i])
			walk(i)
		}
	}
	walk(root)
	for i := range items {
		if !seen[i] {
			seen[i] = true
			out = append(out, items[i])
			walk(i) // the ring's first member pulls the rest of it in
		}
	}
	return out
}
