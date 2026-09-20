package main

import (
	"io"
	"os"
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

// TestPromptFlagParsing checks parsePromptArgs directly for --session,
// --fallback-to-session (both spellings), and the default (neither set).
func TestPromptFlagParsing(t *testing.T) {
	cases := []struct {
		args         []string
		session, fbk bool
	}{
		{nil, false, false},
		{[]string{"--session"}, true, false},
		{[]string{"-session"}, true, false},
		{[]string{"--fallback-to-session"}, false, true},
		{[]string{"-fallback-to-session"}, false, true},
	}
	for _, c := range cases {
		session, fbk, err := parsePromptArgs(c.args)
		if err != nil {
			t.Fatalf("parsePromptArgs(%v): %v", c.args, err)
		}
		if session != c.session || fbk != c.fbk {
			t.Errorf("parsePromptArgs(%v) = (%v, %v), want (%v, %v)",
				c.args, session, fbk, c.session, c.fbk)
		}
	}
}

// TestPromptFlagsMutuallyExclusive checks that --session and
// --fallback-to-session together are rejected, both via parsePromptArgs
// directly and via prompt's exit code and message.
func TestPromptFlagsMutuallyExclusive(t *testing.T) {
	args := []string{"--session", "--fallback-to-session"}
	if _, _, err := parsePromptArgs(args); err == nil {
		t.Fatalf("parsePromptArgs(%v): want error, got nil", args)
	}

	old := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	code := prompt(args, strings.NewReader("hi"))
	w.Close()
	os.Stderr = old
	out, _ := io.ReadAll(r)

	if code != 1 {
		t.Errorf("code = %d, want 1", code)
	}
	if want := "--session and --fallback-to-session are mutually exclusive"; !strings.Contains(string(out), want) {
		t.Errorf("stderr = %q, want it to contain %q", out, want)
	}
}
