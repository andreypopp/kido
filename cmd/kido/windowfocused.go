package main

import (
	"fmt"
	"regexp"

	"kido/internal/tmux"
)

// windowFocusedIDPattern matches windowIDPattern in closewindow.go: this
// command never passes its argument to a tmux target, so there is no
// resolution hazard to guard against, but a plain @N is the only shape
// tmux.Pane.WindowID ever takes, and refusing anything else fails loudly
// instead of just always answering "false".
var windowFocusedIDPattern = regexp.MustCompile(`^@[0-9]+$`)

// windowFocusedCmd implements `kido window-focused WINDOW_ID`: prints
// "true" or "false", answering whether some client is looking at that
// window right now (tmux.WindowFocused - the same test close-window and
// internal/reap's sweep use). pi/kido-agents.ts's idle self-exit timer is
// its only caller: a subagent about to shut itself down for being idle
// must not take a screen the user is actively reading, and re-arms
// instead (docs/design.md, "Idle self-exit").
func windowFocusedCmd(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: kido window-focused WINDOW_ID")
	}
	if !windowFocusedIDPattern.MatchString(args[0]) {
		return fmt.Errorf("window-focused: %q is not a window id (@N)", args[0])
	}
	panes, err := listPanes()
	if err != nil {
		return err
	}
	if tmux.WindowFocused(panes, args[0]) {
		fmt.Println("true")
	} else {
		fmt.Println("false")
	}
	return nil
}
