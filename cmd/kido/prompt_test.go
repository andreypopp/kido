package main

import (
	"strings"
	"testing"
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
