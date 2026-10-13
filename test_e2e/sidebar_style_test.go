package e2e

import (
	"fmt"
	"regexp"
	"testing"
)

// sgr256 matches an escape that sets the 256-colour foreground (38) or
// background (48) to index n, alone or among other parameters.
func sgr256(layer, n int) *regexp.Regexp {
	return regexp.MustCompile(fmt.Sprintf(`\x1b\[(?:[\d:]+;)*%d;5;%d(?:;[\d:]+)*m`, layer, n))
}

// The @kido-sidebar-*-style options restyle a running sidebar, read on
// its tick, and a bad value is named in its footer. Lines: 0 alpha (the
// client's session), 1 its pane, 2 beta, 3 its pane. The first check is
// the negative control: nothing carries the colours before they are set.
func TestSidebarStyleOptions(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.waitRows(4)

	tint, band, name := sgr256(48, 24), sgr256(48, 52), sgr256(38, 33)
	for i, line := range h.capture()[:4] {
		if side := sideOf(line); tint.MatchString(side) || band.MatchString(side) || name.MatchString(side) {
			t.Fatalf("line %d is styled before any option is set: %q", i, side)
		}
	}

	h.in("set", "-g", "@kido-sidebar-current-rows-style", "bg=colour24")
	h.in("set", "-g", "@kido-sidebar-session-style", "fg=colour33,bg=colour52")
	h.waitFor(func() bool {
		l := h.capture()
		return len(l) > 3 && tint.MatchString(sideOf(l[1])) &&
			band.MatchString(sideOf(l[2])) && name.MatchString(sideOf(l[2]))
	}, settle, func() string { return fmt.Sprintf("the tint on line 1, the band on line 2: %q", h.capture()[:4]) })
	if l := h.capture(); tint.MatchString(sideOf(l[3])) {
		t.Fatalf("beta's pane took the current session's tint: %q", sideOf(l[3]))
	}

	h.in("set", "-g", "@kido-sidebar-dim-style", "fg=bogus")
	h.waitFor(func() bool { return hasLine(h.sidebar(), "@kido-sidebar-dim-style: unknown") }, settle,
		func() string { return fmt.Sprintf("the bad option named in the footer: %q", h.sidebar()) })
}
