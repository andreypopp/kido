package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// toolsFixture is the shared list of pi tool names, read from the same
// file pi's own suite reads.
const toolsFixture = "../../pi/testdata/tools.json"

// TestEveryToolHasASubcommandOfItsName is the mechanical half of "each
// tool gets its own subcommand" (docs/design-subagents.md, "The tools,
// and their commands"). Until this test existed the rule was a
// convention, and the confusion that produced the rule was exactly its
// drift: a `list_agents` tool whose subcommand was called `agents`, and a
// user who ran `kido list_agents` and got an error about a tmux client.
//
// It takes the discriminator-table shape (internal/msg/testdata/
// discriminator.json) rather than a list hardcoded here, because one list
// in one language cannot close the gap that matters. The drift to catch
// is a tool ADDED without a subcommand, and a Go test reading its own
// copy of the tool names would not notice one: nobody editing
// pi/kido-agents.ts has a reason to come here. So the fixture is the one
// list, and the two suites pin its two ends - pi's own suite asserts the
// registered tools are exactly these names, so a new tool fails there
// until the fixture names it, and this test then fails until kido has the
// subcommand. Neither half is load-bearing alone; together they mean a
// tool cannot exist without a command of its own name.
func TestEveryToolHasASubcommandOfItsName(t *testing.T) {
	raw, err := os.ReadFile(filepath.FromSlash(toolsFixture))
	if err != nil {
		t.Fatalf("reading %s: %v", toolsFixture, err)
	}
	var tools []string
	if err := json.Unmarshal(raw, &tools); err != nil {
		t.Fatalf("parsing %s: %v", toolsFixture, err)
	}
	// An emptied or truncated fixture would pass every assertion below by
	// having nothing to check. The other end of that guard is pi's own
	// suite, which compares this list against what the extension actually
	// registers.
	if len(tools) == 0 {
		t.Fatalf("%s names no tools; it is the list both suites check against", toolsFixture)
	}

	for _, tool := range tools {
		if !slices.Contains(subcommands, tool) {
			t.Errorf("tool %q (named in %s, which pi's own suite pins against the tools it registers) "+
				"has no kido subcommand %q; every tool invokes the subcommand it is named after, so add "+
				"the subcommand, rename the tool, or drop the name from the fixture if no tool has it",
				tool, toolsFixture, tool)
		}
	}
}

// TestSubcommandsListIsSound guards what the parity test above leans on.
// `subcommands` is a hand-kept list, so the name it answers a tool with
// could be one main's switch never dispatches - and then parity is being
// checked against a lie. That the list is real is
// TestKnownSubcommandsDispatch's job (dispatch_test.go), which runs every
// name through the built binary; all this adds is the cheap part that
// test cannot see, since a duplicate dispatches perfectly well and only
// shows up in the "subcommands:" line the unknown-subcommand error
// prints.
func TestSubcommandsListIsSound(t *testing.T) {
	if len(subcommands) == 0 {
		t.Fatal("subcommands is empty; unknownSubcommand has nothing to name and the tool parity test checks nothing")
	}
	seen := map[string]bool{}
	for _, cmd := range subcommands {
		if seen[cmd] {
			t.Errorf("subcommand %q is listed twice", cmd)
		}
		seen[cmd] = true
	}
}
