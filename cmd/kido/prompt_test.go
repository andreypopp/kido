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
