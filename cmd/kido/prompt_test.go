package main

import (
	"strings"
	"testing"

	"kido/internal/tmux"
)

// TestPromptEmptyStdin checks that empty input (or input that is only a
// newline) is rejected before kido ever talks to tmux.
func TestPromptEmptyStdin(t *testing.T) {
	for _, in := range []string{"", "\n"} {
		if code := prompt(nil, strings.NewReader(in)); code != 1 {
			t.Errorf("prompt(nil, %q) = %d, want 1", in, code)
		}
	}
}

// TestPromptUnknownArg checks that a stray positional argument is
// rejected up front.
func TestPromptUnknownArg(t *testing.T) {
	if code := prompt([]string{"bogus"}, strings.NewReader("hi")); code != 1 {
		t.Errorf("code = %d, want 1", code)
	}
}

// TestPromptAgentPanesInExcludesSubagentWindows checks that a pane whose window
// carries the @kido_subagent mark is never a candidate, even though it
// looks like an agent pane otherwise (CurrentCommand "claude"): a
// subagent is never a target for kido prompt. The negative control is an
// unmarked second agent pane, which must still make two candidates.
func TestPromptAgentPanesInExcludesSubagentWindows(t *testing.T) {
	self := tmux.Pane{PaneID: "%1", SessionName: "alpha", WindowIndex: 0}
	panes := []tmux.Pane{
		self,
		{PaneID: "%2", SessionName: "alpha", WindowIndex: 1, CurrentCommand: "claude"},
		{PaneID: "%3", SessionName: "alpha", WindowIndex: 2, CurrentCommand: "claude", Subagent: "run=abc"},
	}

	got := agentPanesIn(panes, nil, nil, self, true)
	if len(got) != 1 || got[0].PaneID != "%2" {
		t.Fatalf("agentPanesIn = %v, want only %%2 (the subagent window's pane must be excluded)", got)
	}

	// Negative control: without the mark, both are candidates.
	panes[2].Subagent = ""
	got = agentPanesIn(panes, nil, nil, self, true)
	if len(got) != 2 {
		t.Fatalf("agentPanesIn (unmarked) = %v, want both %%2 and %%3", got)
	}
}

// TestPromptFlagParsing checks parsePromptArgs directly for --window
// (both spellings) and the default (unset).
func TestPromptFlagParsing(t *testing.T) {
	cases := []struct {
		args   []string
		window bool
	}{
		{nil, false},
		{[]string{"--window"}, true},
		{[]string{"-window"}, true},
	}
	for _, c := range cases {
		window, err := parsePromptArgs(c.args)
		if err != nil {
			t.Fatalf("parsePromptArgs(%v): %v", c.args, err)
		}
		if window != c.window {
			t.Errorf("parsePromptArgs(%v) = %v, want %v", c.args, window, c.window)
		}
	}
}
