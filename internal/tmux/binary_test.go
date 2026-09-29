package tmux

import (
	"os"
	"path/filepath"
	"testing"
)

// TestResolveBinaryOrder pins the three-tier order: $KIDO_TMUX, then a
// "kido-tmux" sibling of the kido executable, then "tmux" on PATH.
func TestResolveBinaryOrder(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "kido")
	if err := os.WriteFile(exe, []byte(""), 0o755); err != nil {
		t.Fatal(err)
	}
	sib := filepath.Join(dir, "kido-tmux")
	if err := os.WriteFile(sib, []byte(""), 0o755); err != nil {
		t.Fatal(err)
	}

	if got := resolveBinary("/opt/kido-tmux", exe); got != "/opt/kido-tmux" {
		t.Errorf("KIDO_TMUX set: got %q, want /opt/kido-tmux", got)
	}
	if got := resolveBinary("", exe); got != sib {
		t.Errorf("sibling present: got %q, want %q", got, sib)
	}
}

// TestResolveBinaryFallsThroughToPathWithNoSibling pins the fallback when
// no "kido-tmux" sits beside the executable.
func TestResolveBinaryFallsThroughToPathWithNoSibling(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "kido")
	if err := os.WriteFile(exe, []byte(""), 0o755); err != nil {
		t.Fatal(err)
	}

	if got := resolveBinary("", exe); got != "tmux" {
		t.Errorf("got %q, want \"tmux\"", got)
	}
}

// TestResolveBinaryKidoTmuxWinsOverSibling pins that $KIDO_TMUX is checked
// first even when a sibling kido-tmux exists to be found.
func TestResolveBinaryKidoTmuxWinsOverSibling(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "kido")
	if err := os.WriteFile(exe, []byte(""), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "kido-tmux"), []byte(""), 0o755); err != nil {
		t.Fatal(err)
	}

	if got := resolveBinary("/elsewhere/tmux", exe); got != "/elsewhere/tmux" {
		t.Errorf("got %q, want /elsewhere/tmux", got)
	}
}

// argv[0] with no separator is a PATH lookup, and that must not resolve
// symlinks either.
func TestInvokedPathLooksUpABareName(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real-kido")
	if err := os.WriteFile(target, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "kido-under-test")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	got, err := InvokedPath("kido-under-test")
	if err != nil {
		t.Fatal(err)
	}
	if got != link {
		t.Errorf("InvokedPath = %q, want the unresolved %q", got, link)
	}
}

// Nothing usable in argv[0] falls back to os.Executable rather than
// failing: the test binary's own path.
func TestInvokedPathFallsBackToExecutable(t *testing.T) {
	want, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	got, err := InvokedPath("")
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("InvokedPath = %q, want %q", got, want)
	}
}
