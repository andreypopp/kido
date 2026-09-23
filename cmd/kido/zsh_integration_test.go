package main

import (
	"bytes"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestZshIntegrationEmitsCmdline drives shell/zsh/integration.zsh through a
// real zsh and checks the literal bytes kido_osc133_preexec writes for a
// command line carrying a BEL, an ESC, a ';', a '=' and a space - the
// characters that would either break the OSC sequence early or collide
// with the cmdline= parameter's own syntax if left unquoted.
func TestZshIntegrationEmitsCmdline(t *testing.T) {
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	script, err := filepath.Abs(filepath.Join("..", "..", "shell", "zsh", "integration.zsh"))
	if err != nil {
		t.Fatal(err)
	}

	run := func(t *testing.T, cmdline string) string {
		t.Helper()
		var out, errb bytes.Buffer
		cmd := exec.Command(zsh, "-c", "source "+script+"; kido_osc133_preexec \"$1\"", "_", cmdline)
		cmd.Stdout, cmd.Stderr = &out, &errb
		if err := cmd.Run(); err != nil {
			t.Fatalf("zsh: %v (stderr %q)", err, errb.String())
		}
		return out.String()
	}

	nasty := "a\x07b\x1bc;d=e f"
	got := run(t, nasty)
	want := "\033]133;C;cmdline=a$'\\a'b$'\\033'c\\;d=e\\ f\007"
	if got != want {
		t.Errorf("kido_osc133_preexec(%q) = %q, want %q", nasty, got, want)
	}
	if strings.ContainsAny(got[len("\033]133;C;cmdline="):len(got)-1], "\x07\x1b") {
		t.Errorf("output %q still carries a raw BEL or ESC inside the OSC payload", got)
	}

	long := strings.Repeat("héllo ", 300) // multibyte, well past the 1024-char cap
	got = run(t, long)
	payload := strings.TrimSuffix(strings.TrimPrefix(got, "\033]133;C;cmdline="), "\007")
	// The command line is quoted, so decode it back through zsh's own
	// reader rather than comparing quoted bytes to the raw input.
	decode := exec.Command(zsh, "-c", "eval \"print -rn -- $1\"", "_", payload)
	var decoded bytes.Buffer
	decode.Stdout = &decoded
	if err := decode.Run(); err != nil {
		t.Fatalf("decoding truncated payload: %v", err)
	}
	if n := len([]rune(decoded.String())); n != 1024 {
		t.Errorf("truncated command line is %d runes, want 1024", n)
	}
	if !strings.HasPrefix(long, decoded.String()) {
		t.Errorf("truncated command line is not a prefix of the original")
	}
	for _, r := range decoded.String() {
		if r == '\ufffd' {
			t.Errorf("truncated command line %q contains a replacement rune: cut mid-rune", decoded.String())
		}
	}
}
