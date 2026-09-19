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

// prompt implements `kido prompt [--session]`: it reads a prompt from
// stdin (the whole input, with one trailing newline stripped) and sends
// it to the one Claude Code pane in scope, the way
// ~/.config/ink/plugged/cctools/bin/ccsend does: send-keys -l the text,
// then Enter a moment later.
//
// Scope is the caller's window by default, or its session with --session
// (also accepted as -session, since flag handles both spellings the same
// way). The caller's own pane ($TMUX_PANE) is only ever a candidate when
// it is itself a Claude Code pane, since candidates are picked by
// state.IsClaudePane and a plain shell pane never qualifies.
//
// Returns the process exit code, printing any error to stderr itself.
func prompt(args []string, stdin io.Reader) int {
	fs := flag.NewFlagSet("prompt", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	session := fs.Bool("session", false, "search the caller's session instead of its window")
	if err := fs.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, "kido prompt:", err)
		return 1
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "kido prompt: unknown argument %q\n", fs.Arg(0))
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
	var candidates []tmux.Pane
	for _, p := range panes {
		if p.SessionName != self.SessionName {
			continue
		}
		if !*session && p.WindowIndex != self.WindowIndex {
			continue
		}
		if state.IsClaudePane(states, p) {
			candidates = append(candidates, p)
		}
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

// findPane returns the pane with the given id.
func findPane(panes []tmux.Pane, id string) (tmux.Pane, bool) {
	for _, p := range panes {
		if p.PaneID == id {
			return p, true
		}
	}
	return tmux.Pane{}, false
}
