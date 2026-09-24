package main

import (
	"testing"
)

// TestZshrcBlockRuns checks the generated block against a real zsh.
func TestZshrcBlockRuns(t *testing.T) {
	rcBlockRuns(t, "zsh", zshrcBlock, "print sourced\n", "setup-zsh")
}
