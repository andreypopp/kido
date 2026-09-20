package ui

import "testing"

// TestAgentTitle checks the two markers agents put before their titles,
// and that everything else keeps the behaviour Claude Code titles have
// always had.
func TestAgentTitle(t *testing.T) {
	for _, c := range []struct{ title, want string }{
		{"✳ Tmux config", "Tmux config"},   // Claude Code
		{"✳ 2 panes", "2 panes"},           // a digit survives the trim
		{"π - kido - kido", "kido - kido"}, // pi, named session
		{"π - kido", "kido"},               // pi, unnamed session
		{"π - ", "-"},                      // nothing after the marker
		{"plain title", "plain title"},     // left as it is
		{"π-no-space", "π-no-space"},       // not pi's marker
		{"", "-"},                          // no title at all
		{"✳ ", "-"},                        // marker only
		{"~/src/kido", "src/kido"},         // the old trim, unchanged
	} {
		if got := agentTitle(c.title); got != c.want {
			t.Errorf("agentTitle(%q) = %q, want %q", c.title, got, c.want)
		}
	}
}
