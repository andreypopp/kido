package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestBashrcBlockRuns checks the generated block against a real bash:
// that it parses, that it sources a script that is there, and that a
// missing one produces a message on stderr instead of bash's own error -
// the whole point of the guard.
func TestBashrcBlockRuns(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash in PATH")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "integration.bash")
	if err := os.WriteFile(script, []byte("echo sourced\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run := func(t *testing.T, sh, source string) (string, string) {
		t.Helper()
		var out, errb strings.Builder
		cmd := exec.Command(sh, "-c", bashrcBlock(source))
		cmd.Stdout, cmd.Stderr = &out, &errb
		if err := cmd.Run(); err != nil {
			t.Fatalf("%s: %v (stderr %q)", sh, err, errb.String())
		}
		return out.String(), errb.String()
	}

	out, errs := run(t, bash, script)
	if strings.TrimSpace(out) != "sourced" {
		t.Errorf("stdout = %q, want the script to have been sourced", out)
	}
	if errs != "" {
		t.Errorf("stderr = %q, want nothing", errs)
	}

	missing := filepath.Join(dir, "gone.bash")
	out, errs = run(t, bash, missing)
	if out != "" {
		t.Errorf("stdout = %q, want nothing", out)
	}
	if !strings.Contains(errs, missing) || !strings.Contains(errs, "setup-bash") {
		t.Errorf("stderr = %q, want it to name %q and how to fix it", errs, missing)
	}

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
	out, errs = run(t, dash, script)
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
