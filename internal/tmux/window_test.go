package tmux

import (
	"reflect"
	"slices"
	"testing"
)

// TestNewWindowArgsHasRequiredFlags pins the flags docs/subagents-plan.md
// and AGENTS.md call out as load-bearing: -d, -c and one -e per env pair
// must all be present, since a subagent whose window is missing any of
// them starts in the wrong place, with the wrong environment, or steals
// the caller's own turn.
func TestNewWindowArgsHasRequiredFlags(t *testing.T) {
	command := []string{"pi", "--name", "worker-1"}
	args := newWindowArgs("$3", "worker-1", "/home/dev/project",
		[]string{"KIDO_AGENT_DEPTH=1", "KIDO_AGENT_TASK_FILE=/tmp/t"}, command)

	if !slices.Contains(args, "-d") {
		t.Errorf("new-window args %v missing -d", args)
	}
	for _, pair := range [][2]string{
		{"-c", "/home/dev/project"},
		{"-t", "$3:"},
		{"-n", "worker-1"},
	} {
		if !hasFlagValue(args, pair[0], pair[1]) {
			t.Errorf("new-window args %v missing %s %s", args, pair[0], pair[1])
		}
	}
	for _, kv := range []string{"KIDO_AGENT_DEPTH=1", "KIDO_AGENT_TASK_FILE=/tmp/t"} {
		if !hasFlagValue(args, "-e", kv) {
			t.Errorf("new-window args %v missing -e %s", args, kv)
		}
	}
	if got := args[len(args)-len(command):]; !reflect.DeepEqual(got, command) {
		t.Errorf("command tail = %v, want %v unmodified at the end", got, command)
	}
}

// hasFlagValue reports whether args contains flag immediately followed by
// value, anywhere - new-window accepts -e (and could, in principle, other
// repeatable flags) more than once, so a plain slices.Contains on the pair
// as two separate lookups would not confirm they are adjacent.
func hasFlagValue(args []string, flag, value string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}
