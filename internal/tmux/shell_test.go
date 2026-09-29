package tmux

import "testing"

func TestPaneShell(t *testing.T) {
	for _, tc := range []struct {
		name string
		pane Pane
		want Shell
	}{{
		// A shell that never emits OSC 133: no prompt was ever marked,
		// so kido knows nothing and the row must not be decorated.
		name: "no integration",
		pane: Pane{},
		want: ShellNone,
	}, {
		name: "no integration, stale running flag",
		pane: Pane{CommandRunning: true, CommandStartTime: 100},
		want: ShellNone,
	}, {
		name: "idle at the prompt",
		pane: Pane{LastPromptTime: 200, CommandStartTime: 100},
		want: ShellIdle,
	}, {
		name: "command running",
		pane: Pane{CommandRunning: true, CommandStartTime: 300, LastPromptTime: 200},
		want: ShellRunning,
	}, {
		// 133;C without a matching 133;D leaves tmux's running flag set
		// forever; the next prompt's 133;A is what heals it.
		name: "stuck C without D, healed by the next prompt",
		pane: Pane{CommandRunning: true, CommandStartTime: 300, LastPromptTime: 400},
		want: ShellIdle,
	}, {
		// Same second: the prompt is not strictly newer, so the pane
		// still reads as running. tmux's times are whole seconds, and a
		// wrong "idle" the instant a command starts is the worse error.
		name: "command started in the prompt's second",
		pane: Pane{CommandRunning: true, CommandStartTime: 300, LastPromptTime: 300},
		want: ShellRunning,
	}} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.pane.Shell(); got != tc.want {
				t.Errorf("Shell() = %v, want %v", got, tc.want)
			}
		})
	}
}
