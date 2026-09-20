package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"kido/internal/state"
	"kido/internal/tmux"
)

// prompt implements `kido prompt [--session] [--fallback-to-session]`: it
// reads a prompt from stdin (the whole input, with one trailing newline
// stripped) and sends it to the one Claude Code pane in scope, the way
// ~/.config/ink/plugged/cctools/bin/ccsend does: send-keys -l the text,
// then Enter a moment later.
//
// Scope is the caller's window by default, or its session with --session
// (also accepted as -session, since flag handles both spellings the same
// way). --fallback-to-session (also -fallback-to-session) keeps the
// default window scope, but widens to the session when the window has no
// Claude Code pane at all; it is mutually exclusive with --session, which
// already means "search the session". The caller's own pane ($TMUX_PANE)
// is only ever a candidate when it is itself a Claude Code pane, since
// candidates are picked by state.IsClaudePane and a plain shell pane never
// qualifies.
//
// Returns the process exit code, printing any error to stderr itself.
func prompt(args []string, stdin io.Reader) int {
	session, fallback, err := parsePromptArgs(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}

	b, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	text := strings.TrimSuffix(string(b), "\n")
	if text == "" {
		fmt.Fprintln(os.Stderr, "no prompt given")
		return 1
	}

	caller := os.Getenv("TMUX_PANE")
	panes, err := tmux.ListPanes()
	if err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	self, ok := findPane(panes, caller)
	if !ok {
		fmt.Fprintf(os.Stderr, "kido prompt: pane %q not found\n", caller)
		return 1
	}

	states, _ := state.Load()
	candidates := claudePanesIn(panes, states, self, session)
	if fallback && len(candidates) == 0 {
		// Widen to the session only when the window has none at all.
		// Several panes in the window would also be several in the
		// session, so exit 5 (ambiguous) must not change by widening;
		// only the not-found case does.
		candidates = claudePanesIn(panes, states, self, true)
	}

	switch len(candidates) {
	case 0:
		fmt.Fprintln(os.Stderr, "claude code not found")
		return 4
	case 1:
		if err := tmux.SendPrompt(candidates[0].PaneID, text); err != nil {
			fmt.Fprintln(os.Stderr, "kido prompt:", err)
			return 1
		}
		return 0
	default:
		fmt.Fprintln(os.Stderr, "multiple claude code found")
		return 5
	}
}

// parsePromptArgs parses prompt's flags: --session/-session and
// --fallback-to-session/-fallback-to-session, rejecting the two together
// and any stray positional argument.
func parsePromptArgs(args []string) (session, fallback bool, err error) {
	fs := flag.NewFlagSet("prompt", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	sessionFlag := fs.Bool("session", false, "search the caller's session instead of its window")
	fallbackFlag := fs.Bool("fallback-to-session", false,
		"search the caller's session, but only when its window has no Claude Code pane")
	if err := fs.Parse(args); err != nil {
		return false, false, err
	}
	if fs.NArg() > 0 {
		return false, false, fmt.Errorf("unknown argument %q", fs.Arg(0))
	}
	if *sessionFlag && *fallbackFlag {
		return false, false, fmt.Errorf("--session and --fallback-to-session are mutually exclusive")
	}
	return *sessionFlag, *fallbackFlag, nil
}

// claudePanesIn returns the Claude Code panes (per state.IsClaudePane) in
// self's session, narrowed to self's window unless wholeSession.
func claudePanesIn(panes []tmux.Pane, states map[string]state.Session, self tmux.Pane, wholeSession bool) []tmux.Pane {
	var out []tmux.Pane
	for _, p := range panes {
		if p.SessionName != self.SessionName {
			continue
		}
		if !wholeSession && p.WindowIndex != self.WindowIndex {
			continue
		}
		if state.IsClaudePane(states, p) {
			out = append(out, p)
		}
	}
	return out
}

// findPane returns the pane with the given id.
func findPane(panes []tmux.Pane, id string) (tmux.Pane, bool) {
	for _, p := range panes {
		if p.PaneID == id {
			return p, true
		}
	}
	return tmux.Pane{}, false
}
