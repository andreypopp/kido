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
// and their commands"). Reads the shared fixture rather than a list
// hardcoded here, so a tool added in pi/kido-agents.ts without a
// subcommand fails here too: pi's own suite pins that the fixture names
// exactly the registered tools, and this test pins that kido has a
// subcommand for each. Neither half is load-bearing alone.
func TestEveryToolHasASubcommandOfItsName(t *testing.T) {
	raw, err := os.ReadFile(filepath.FromSlash(toolsFixture))
	if err != nil {
		t.Fatalf("reading %s: %v", toolsFixture, err)
	}
	var tools []string
	if err := json.Unmarshal(raw, &tools); err != nil {
		t.Fatalf("parsing %s: %v", toolsFixture, err)
	}
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

// TestSubcommandsListIsSound guards what the parity test above leans on:
// `subcommands` is a hand-kept list, so it must name each subcommand
// exactly once. That every name in it actually dispatches is
// TestKnownSubcommandsDispatch's job (dispatch_test.go).
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
