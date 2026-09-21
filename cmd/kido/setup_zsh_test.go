package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestZshrcBlockRuns checks the generated block against a real zsh: that
// it parses, that it sources a script that is there, and that a missing
// one produces a message on stderr instead of zsh's own error - the whole
// point of the guard.
func TestZshrcBlockRuns(t *testing.T) {
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "integration.zsh")
	if err := os.WriteFile(script, []byte("print sourced\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run := func(t *testing.T, source string) (string, string) {
		t.Helper()
		var out, errb strings.Builder
		cmd := exec.Command(zsh, "-c", zshrcBlock(source))
		cmd.Stdout, cmd.Stderr = &out, &errb
		if err := cmd.Run(); err != nil {
			t.Fatalf("zsh: %v (stderr %q)", err, errb.String())
		}
		return out.String(), errb.String()
	}

	out, errs := run(t, script)
	if strings.TrimSpace(out) != "sourced" {
		t.Errorf("stdout = %q, want the script to have been sourced", out)
	}
	if errs != "" {
		t.Errorf("stderr = %q, want nothing", errs)
	}

	missing := filepath.Join(dir, "gone.zsh")
	out, errs = run(t, missing)
	if out != "" {
		t.Errorf("stdout = %q, want nothing", out)
	}
	if !strings.Contains(errs, missing) || !strings.Contains(errs, "setup-zsh") {
		t.Errorf("stderr = %q, want it to name %q and how to fix it", errs, missing)
	}
}
