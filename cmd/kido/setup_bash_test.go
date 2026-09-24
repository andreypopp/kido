package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestBashrcBlockRuns checks the generated block against a real bash, and
// then against the one other shell that reads it.
func TestBashrcBlockRuns(t *testing.T) {
	script := rcBlockRuns(t, "bash", bashrcBlock, "echo sourced\n", "setup-bash")

	// The block can land in ~/.profile, which every sh reads: there it
	// must parse, say nothing, and source nothing - the integration is
	// bash's, and $BASH_VERSION is the guard that keeps a dash login
	// quiet. It has to be dash: macOS's /bin/sh is bash in posix mode,
	// sets $BASH_VERSION itself, and would pass this whatever the block
	// said.
	dash, err := exec.LookPath("dash")
	if err != nil {
		t.Log("no dash in PATH; the sh guard is unchecked here")
		return
	}
	out, errs := runRCBlock(t, dash, bashrcBlock(script))
	if out != "" || errs != "" {
		t.Errorf("under dash the block wrote %q / %q, want silence", out, errs)
	}
}

// TestBashLoginFile pins which file setup-bash puts its second copy in.
// tmux starts a pane's shell as a login shell, which reads none of
// ~/.bashrc, so the answer decides whether a pane reports at all.
func TestBashLoginFile(t *testing.T) {
	write := func(t *testing.T, files map[string]string) string {
		t.Helper()
		home := t.TempDir()
		for name, body := range files {
			if err := os.WriteFile(filepath.Join(home, name), []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		return home
	}

	// Nothing there at all: bash reads ~/.bash_profile first, and
	// creating it shadows nothing.
	if name, why := bashLoginFile(write(t, nil)); name != ".bash_profile" || why != "" {
		t.Errorf("empty home = (%q, %q), want .bash_profile", name, why)
	}

	// A profile that reaches ~/.bashrc needs nothing: one block does both.
	_, why := bashLoginFile(write(t, map[string]string{
		".bash_profile": "[ -f ~/.bashrc ] && . ~/.bashrc\n",
	}))
	if why == "" {
		t.Error("a .bash_profile sourcing .bashrc = a second block, want none")
	}

	// One that does not is where the block goes.
	name, _ := bashLoginFile(write(t, map[string]string{".bash_profile": "export PATH=/x:$PATH\n"}))
	if name != ".bash_profile" {
		t.Errorf("name = %q, want .bash_profile", name)
	}

	// With no bash-only profile, bash reads ~/.profile - and creating a
	// ~/.bash_profile in front of it would stop bash reading it at all.
	name, _ = bashLoginFile(write(t, map[string]string{".profile": "export PATH=/x:$PATH\n"}))
	if name != ".profile" {
		t.Errorf("name = %q, want .profile: a new .bash_profile would shadow it", name)
	}
}
