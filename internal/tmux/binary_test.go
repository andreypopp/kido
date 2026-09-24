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
