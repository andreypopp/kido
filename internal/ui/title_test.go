package ui

import (
	"testing"

	"kido/internal/tmux"
)

func TestAgentTitleOf(t *testing.T) {
	m := &model{}
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
		p := tmux.Pane{PaneID: "%1", CurrentCommand: "claude", Title: c.title}
		if got, ok := m.agentTitleOf(p); got != c.want || !ok {
			t.Errorf("agentTitleOf(%q) = (%q, %v), want (%q, true)", c.title, got, ok, c.want)
		}
	}
}
