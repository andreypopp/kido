package main

import (
	"testing"

	"kido/internal/state"
	"kido/internal/tmux"
)

// TestPaneCommand covers the per-pane command snapshot's script sends to
// put an agent back where it was: a recorded state.Session is the primary
// source, and a pane's foreground command (or, for pi, procs.Sweep's view
// of its process tree) is only the fallback for a pane that never
// reported.
func TestPaneCommand(t *testing.T) {
	claudePane := tmux.Pane{PaneID: "%1", PanePID: 1, CurrentCommand: "claude"}
	piPane := tmux.Pane{PaneID: "%2", PanePID: 2, CurrentCommand: "node"}
	shellPane := tmux.Pane{PaneID: "%3", PanePID: 3, CurrentCommand: "zsh"}

	for _, tc := range []struct {
		name    string
		pane    tmux.Pane
		states  map[string]state.Session
		piPanes map[int]bool
		want    string
	}{
		{
			name:   "claude with a record resumes by id",
			pane:   claudePane,
			states: map[string]state.Session{"%1": {ID: "sess-1", Agent: state.AgentClaude}},
			want:   "claude --resume sess-1",
		},
		{
			name: "claude with no record continues",
			pane: claudePane,
			want: "claude --continue",
		},
		{
			name:   "pi with a record resumes by session",
			pane:   piPane,
			states: map[string]state.Session{"%2": {ID: "pi-sess-1", Agent: state.AgentPi}},
			want:   "pi --session pi-sess-1",
		},
		{
			name:    "pi with no record but seen by the sweep starts bare",
			pane:    piPane,
			piPanes: map[int]bool{2: true},
			want:    "pi",
		},
		{
			name: "a plain shell pane gets no command",
			pane: shellPane,
			want: "",
		},
		{
			name:   "a record from an agent kido does not recognize is not claude in disguise",
			pane:   piPane,
			states: map[string]state.Session{"%2": {ID: "other-1", Agent: "other"}},
			want:   "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := paneCommand(tc.pane, tc.states, tc.piPanes); got != tc.want {
				t.Errorf("paneCommand() = %q, want %q", got, tc.want)
			}
		})
	}
}
