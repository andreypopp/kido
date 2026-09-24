package main

import (
	"bytes"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// zshPreexec runs shell/zsh/integration.zsh's preexec hook through a real
// zsh and returns the bytes it writes.
func zshPreexec(t *testing.T, cmdline string) string {
	t.Helper()
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	script, err := filepath.Abs(filepath.Join("..", "..", "shell", "zsh", "integration.zsh"))
	if err != nil {
		t.Fatal(err)
	}
	var out, errb bytes.Buffer
	cmd := exec.Command(zsh, "-c", "source "+script+"; kido_osc133_preexec \"$1\"", "_", cmdline)
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("zsh: %v (stderr %q)", err, errb.String())
	}
	return out.String()
}

// oscPrefix is the command-start marker up to its command line. Both
// integrations are held to these same bytes, so both this file's tests
// and bash_integration_test.go's read them through it and payload below.
const oscPrefix = "\033]133;C;cmdline="

// payload is the cmdline= value in a 133;C sequence.
func payload(t *testing.T, got string) string {
	t.Helper()
	if !strings.HasPrefix(got, oscPrefix) || !strings.HasSuffix(got, "\007") {
		t.Fatalf("output %q is not a 133;C sequence", got)
	}
	return strings.TrimSuffix(strings.TrimPrefix(got, oscPrefix), "\007")
}

// TestZshIntegrationEmitsCmdline checks the literal bytes
// kido_osc133_preexec writes. The command line goes out verbatim: tmux
// sanitises the value it stores, and any escaping added here would be
// escaped a second time there and reach the sidebar unreadable. The one
// thing that must not survive is a control character, which would end the
// OSC sequence early.
func TestZshIntegrationEmitsCmdline(t *testing.T) {
	ordinary := "git log --oneline | head -3"
	if got := zshPreexec(t, ordinary); got != oscPrefix+ordinary+"\007" {
		t.Errorf("kido_osc133_preexec(%q) = %q, want the command line verbatim", ordinary, got)
	}

	// ';' and '=' are part of the OSC's own syntax, but cmdline= is the
	// last parameter and its value runs to the end of the string.
	punct := "FOO=bar; make test"
	if got := zshPreexec(t, punct); got != oscPrefix+punct+"\007" {
		t.Errorf("kido_osc133_preexec(%q) = %q, want ';' and '=' intact", punct, got)
	}

	nasty := "a\x07b\x1bc"
	got := zshPreexec(t, nasty)
	if want := oscPrefix + "a b c\007"; got != want {
		t.Errorf("kido_osc133_preexec(%q) = %q, want %q", nasty, got, want)
	}
	if strings.ContainsAny(payload(t, got), "\x07\x1b") {
		t.Errorf("output %q still carries a raw BEL or ESC inside the OSC payload", got)
	}
}

// TestZshIntegrationTruncatesCmdline pins the 1024-character cap and that
// it cuts by character, so a multibyte rune is never split.
func TestZshIntegrationTruncatesCmdline(t *testing.T) {
	long := strings.Repeat("héllo ", 300) // multibyte, well past the 1024-char cap
	got := payload(t, zshPreexec(t, long))
	if n := len([]rune(got)); n != 1024 {
		t.Errorf("truncated command line is %d runes, want 1024", n)
	}
	if !strings.HasPrefix(long, got) {
		t.Errorf("truncated command line is not a prefix of the original")
	}
	if strings.ContainsRune(got, '\ufffd') {
		t.Errorf("truncated command line %q contains a replacement rune: cut mid-rune", got)
	}
}
