package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// block is the .zshrc block setup-zsh keeps, as the test expects to read
// it back, built from the same markers the code uses.
func block(source string) string {
	return fmt.Sprintf("%s\nsource %q\n%s\n", zshrcBegin, source, zshrcEnd)
}

// TestSetZshrcBlock covers the rc edit: a missing file, one without the
// block, one that already has it at the same path (left alone), one that
// has it at a different path (rewritten in place rather than duplicated),
// one where the block sits in the middle of the file, and one that does
// not end in a newline.
func TestSetZshrcBlock(t *testing.T) {
	const path = "/home/u/.local/share/kido/integration.zsh"
	cases := []struct {
		name   string
		rc     string
		want   string
		action string
	}{
		{
			name:   "no file",
			rc:     "",
			want:   block(path),
			action: "added",
		},
		{
			name:   "existing rc",
			rc:     "alias ll='ls -l'\n",
			want:   "alias ll='ls -l'\n\n" + block(path),
			action: "added",
		},
		{
			name:   "no trailing newline",
			rc:     "alias ll='ls -l'",
			want:   "alias ll='ls -l'\n\n" + block(path),
			action: "added",
		},
		{
			name:   "same path",
			rc:     "alias ll='ls -l'\n\n" + block(path),
			want:   "alias ll='ls -l'\n\n" + block(path),
			action: "unchanged",
		},
		{
			name:   "other path",
			rc:     "alias ll='ls -l'\n\n" + block("/opt/homebrew/share/kido/shell/zsh/integration.zsh"),
			want:   "alias ll='ls -l'\n\n" + block(path),
			action: "updated",
		},
		{
			name:   "block in the middle",
			rc:     "before\n" + block("/old/integration.zsh") + "after\n",
			want:   "before\n" + block(path) + "after\n",
			action: "updated",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, action, err := setZshrcBlock([]byte(c.rc), path)
			if err != nil {
				t.Fatal(err)
			}
			if action != c.action {
				t.Errorf("action = %q, want %q", action, c.action)
			}
			if string(out) != c.want {
				t.Errorf("rc =\n%q\nwant\n%q", out, c.want)
			}
			if n := strings.Count(string(out), zshrcBegin); n != 1 {
				t.Errorf("%d begin markers, want 1", n)
			}
		})
	}
}

// TestSetZshrcBlockBroken checks that a half-edited block is an error
// rather than a guess: kido would otherwise have to decide where somebody
// else's hand-edit ends.
func TestSetZshrcBlockBroken(t *testing.T) {
	for _, rc := range []string{
		zshrcBegin + "\nsource \"/x\"\n",
		"source \"/x\"\n" + zshrcEnd + "\n",
		zshrcEnd + "\nsource \"/x\"\n" + zshrcBegin + "\n",
	} {
		if _, _, err := setZshrcBlock([]byte(rc), "/x"); err == nil {
			t.Errorf("setZshrcBlock(%q) = nil error, want one", rc)
		}
	}
}

// TestFindIntegration checks the one layout kido looks in: the script
// under <prefix>/share/kido/shell/zsh next to <prefix>/bin/kido, found
// through a symlinked binary the way a Homebrew install is, and a clear
// failure when a prefix has no script in it.
func TestFindIntegration(t *testing.T) {
	prefix := t.TempDir()
	script := filepath.Join(prefix, "share", "kido", "shell", "zsh", "integration.zsh")
	for _, dir := range []string{filepath.Dir(script), filepath.Join(prefix, "bin")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(script, []byte("# hooks\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(prefix, "bin", "kido")
	if err := os.WriteFile(exe, nil, 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := findIntegration(exe)
	if err != nil {
		t.Fatal(err)
	}
	// The path is returned as spelled, not resolved: it is what goes
	// into the rc file, and the unresolved spelling is the stable one.
	if got != script {
		t.Errorf("findIntegration = %q, want %q", got, script)
	}

	// The same binary reached through a symlink in a prefix with no
	// share of its own: nothing is found beside the link, so the
	// resolved location is the fallback that answers.
	link := filepath.Join(t.TempDir(), "kido")
	if err := os.Symlink(exe, link); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(script)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := findIntegration(link); err != nil || got != resolved {
		t.Errorf("findIntegration(symlink) = %q, %v; want %q, nil", got, err, resolved)
	}

	// A prefix with no script in it fails, naming the path.
	bare := filepath.Join(t.TempDir(), "bin")
	if err := os.MkdirAll(bare, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err = findIntegration(filepath.Join(bare, "kido"))
	if err == nil {
		t.Fatal("findIntegration in an empty prefix = nil error, want one")
	}
	if !strings.Contains(err.Error(), "integration.zsh") {
		t.Errorf("error %q does not name the path it looked at", err)
	}
}

// TestFindIntegrationPrefersUnresolved pins the ordering that keeps the
// rc line working across a Homebrew upgrade: bin/kido and share/kido are
// both symlinks into a versioned directory, and only the unresolved
// spelling survives brew repointing them.
func TestFindIntegrationPrefersUnresolved(t *testing.T) {
	root := t.TempDir()
	versioned := filepath.Join(root, "Cellar", "kido", "1.0.0")
	script := filepath.Join(versioned, "share", "kido", "shell", "zsh")
	if err := os.MkdirAll(script, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(versioned, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(versioned, "bin", "kido"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(script, "integration.zsh"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	// The stable prefix: bin/kido and share/kido both link into the
	// versioned directory, the way brew links a formula.
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(versioned, "bin", "kido"), filepath.Join(root, "bin", "kido")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "share"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(versioned, "share", "kido"), filepath.Join(root, "share", "kido")); err != nil {
		t.Fatal(err)
	}

	got, err := findIntegration(filepath.Join(root, "bin", "kido"))
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(root, "share", "kido", "shell", "zsh", "integration.zsh")
	if got != want {
		t.Errorf("findIntegration = %q, want the version-stable %q", got, want)
	}
}
