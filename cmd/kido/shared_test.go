package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kido/internal/tmux"
)

// shipped are the files kido installs under share/kido, by the relative
// path findShared is asked for.
var shipped = []string{"shell/zsh/integration.zsh", "claude/settings.json"}

// TestFindShared checks the one layout kido looks in: the file under
// <prefix>/share/kido next to <prefix>/bin/kido, found through a symlinked
// binary the way a Homebrew install is, and a clear failure when a prefix
// has nothing in it.
func TestFindShared(t *testing.T) {
	for _, rel := range shipped {
		t.Run(rel, func(t *testing.T) {
			prefix := t.TempDir()
			file := filepath.Join(prefix, "share", "kido", filepath.FromSlash(rel))
			for _, dir := range []string{filepath.Dir(file), filepath.Join(prefix, "bin")} {
				if err := os.MkdirAll(dir, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(file, []byte("# shipped\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			exe := filepath.Join(prefix, "bin", "kido")
			if err := os.WriteFile(exe, nil, 0o755); err != nil {
				t.Fatal(err)
			}

			got, err := findShared(exe, rel)
			if err != nil {
				t.Fatal(err)
			}
			// The path is returned as spelled, not resolved: it is what
			// goes into the server's configuration, and the unresolved
			// spelling is the
			// stable one.
			if got != file {
				t.Errorf("findShared = %q, want %q", got, file)
			}

			// The same binary reached through a symlink in a prefix with
			// no share of its own: nothing is found beside the link, so
			// the resolved location is the fallback that answers.
			link := filepath.Join(t.TempDir(), "kido")
			if err := os.Symlink(exe, link); err != nil {
				t.Fatal(err)
			}
			resolved, err := filepath.EvalSymlinks(file)
			if err != nil {
				t.Fatal(err)
			}
			if got, err := findShared(link, rel); err != nil || got != resolved {
				t.Errorf("findShared(symlink) = %q, %v; want %q, nil", got, err, resolved)
			}

			// A prefix with nothing in it fails, naming the path.
			bare := filepath.Join(t.TempDir(), "bin")
			if err := os.MkdirAll(bare, 0o755); err != nil {
				t.Fatal(err)
			}
			_, err = findShared(filepath.Join(bare, "kido"), rel)
			if err == nil {
				t.Fatal("findShared in an empty prefix = nil error, want one")
			}
			want := filepath.Join(filepath.Dir(bare), "share", "kido", filepath.FromSlash(rel))
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error %q does not name the path %q it looked at", err, want)
			}
		})
	}
}

// TestFindSharedPrefersUnresolved pins the ordering that keeps a path kido
// wrote down working across a Homebrew upgrade: bin/kido and share/kido are
// both symlinks into a versioned directory, and only the unresolved
// spelling survives brew repointing them.
func TestFindSharedPrefersUnresolved(t *testing.T) {
	root := t.TempDir()
	versioned := filepath.Join(root, "Cellar", "kido", "1.0.0")
	if err := os.MkdirAll(filepath.Join(versioned, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(versioned, "bin", "kido"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, rel := range shipped {
		p := filepath.Join(versioned, "share", "kido", filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
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

	for _, rel := range shipped {
		got, err := findShared(filepath.Join(root, "bin", "kido"), rel)
		if err != nil {
			t.Fatal(err)
		}
		want := filepath.Join(root, "share", "kido", filepath.FromSlash(rel))
		if got != want {
			t.Errorf("findShared = %q, want the version-stable %q", got, want)
		}
	}
}

// A Homebrew-shaped install: bin/kido and share/kido are symlinks the
// package manager repoints on upgrade, and the versioned directory they
// point at is what `brew cleanup` later deletes. tmux.InvokedPath has to
// keep the prefix spelling, so findShared resolves through the symlinks
// that survive.
func TestInvokedPathKeepsThePrefixSpelling(t *testing.T) {
	root := t.TempDir()
	versioned := filepath.Join(root, "Cellar", "kido", "HEAD-abc1234")
	if err := os.MkdirAll(filepath.Join(versioned, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(versioned, "share", "kido", "shell", "zsh", "integration.zsh")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("# integration\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	realBin := filepath.Join(versioned, "bin", "kido")
	if err := os.WriteFile(realBin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	prefix := filepath.Join(root, "prefix")
	if err := os.MkdirAll(filepath.Join(prefix, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	prefixBin := filepath.Join(prefix, "bin", "kido")
	if err := os.Symlink(realBin, prefixBin); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(prefix, "share"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(versioned, "share", "kido"), filepath.Join(prefix, "share", "kido")); err != nil {
		t.Fatal(err)
	}

	got, err := tmux.InvokedPath(prefixBin)
	if err != nil {
		t.Fatal(err)
	}
	if got != prefixBin {
		t.Fatalf("InvokedPath = %q, want the unresolved %q", got, prefixBin)
	}

	// The whole point: what kido writes down goes through the prefix,
	// not the versioned directory a cleanup removes.
	found, err := findShared(got, "shell/zsh/integration.zsh")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(found, "Cellar") {
		t.Errorf("findShared = %q, want a path that avoids the versioned directory", found)
	}
}
