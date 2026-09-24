package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// modernBash returns a bash new enough for PS0, which is what
// shell/bash/integration.bash is built on and what macOS's own 3.2
// /bin/bash does not have.
func modernBash(t *testing.T) string {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash in PATH")
	}
	out, err := exec.Command(bash, "-c", "printf %s.%s ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}").Output()
	if err != nil {
		t.Fatalf("%s: %v", bash, err)
	}
	major, minor, _ := strings.Cut(string(out), ".")
	maj, _ := strconv.Atoi(major)
	min, _ := strconv.Atoi(minor)
	if maj < 4 || (maj == 4 && min < 4) {
		t.Skipf("bash %s is older than 4.4, which PS0 needs", out)
	}
	return bash
}

// osc133Seqs is every OSC 133 marker in a stream, whole. The shell's own
// noise - its prompt, the lines it echoes back off a piped stdin, the
// commands' output - sits between them and is not what is being asserted.
var osc133Seqs = regexp.MustCompile("\x1b\\]133;[^\x07]*\x07")

// bashSession runs the lines through a real interactive bash with
// shell/bash/integration.bash sourced, and returns the OSC 133 markers it
// wrote in order. Prompts go to stderr and the hooks' own output to
// stdout, so both are read as one stream: in a pane they are one stream,
// the tty.
func bashSession(t *testing.T, lines ...string) []string {
	t.Helper()
	bash := modernBash(t)
	script, err := filepath.Abs(filepath.Join("..", "..", "shell", "bash", "integration.bash"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	rc := filepath.Join(dir, "bashrc")
	// PS1 empty so nothing but the markers carries an escape sequence,
	// and sourced twice because the integration promises that is the same
	// as sourcing it once.
	body := "source " + strconv.Quote(script) + "\nsource " + strconv.Quote(script) + "\nPS1=''\n"
	if err := os.WriteFile(rc, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	// -i because stdin is a pipe: it is what the pty of a real pane would
	// have made bash decide on its own. noTTY keeps the shell off the
	// developer's terminal, which it would otherwise report to.
	cmd := noTTY(exec.Command(bash, "--rcfile", rc, "-i"))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + dir,
		// The cap is in characters, which is only true of a bash indexing
		// strings by character.
		"LC_ALL=en_US.UTF-8",
		"HISTFILE=" + filepath.Join(dir, "history"),
	}
	// Ended by closing stdin rather than by an `exit` line: exit is a
	// command line like any other and would report itself. The shell's own
	// status is then the last command's, which is nothing to fail on -
	// TestBashIntegrationMarksACommand runs `false` on purpose.
	cmd.Stdin = strings.NewReader(strings.Join(lines, "\n") + "\n")
	out, _ := cmd.CombinedOutput()
	return osc133Seqs.FindAllString(string(out), -1)
}

// bashPreexec runs the command-start hook over one history entry and
// returns the bytes it writes. Control characters take this path rather
// than the session above because bash never lets them reach a history
// entry off a piped stdin - it is readline, on a real terminal, that puts
// a literal BEL in a line (ctrl-v ctrl-g) and in the history with it.
func bashPreexec(t *testing.T, cmdline string) string {
	t.Helper()
	bash := modernBash(t)
	script, err := filepath.Abs(filepath.Join("..", "..", "shell", "bash", "integration.bash"))
	if err != nil {
		t.Fatal(err)
	}
	// -i because the integration installs nothing in a shell that is not
	// interactive, there being no prompt there to hang a hook on.
	cmd := noTTY(exec.Command(bash, "-ic",
		"source "+strconv.Quote(script)+"; history -s \"$1\"; kido_osc133_preexec", "_", cmdline))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + t.TempDir(),
		"LC_ALL=en_US.UTF-8",
	}
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	return string(out)
}

// TestBashIntegrationMarksACommand is the whole cycle for one command
// line: a prompt, the command starting with its text, and the command
// ending with its status. The first prompt carries no D - nothing has run
// - and the exit status reported is the command's own, not whatever ran
// after it on the way to the next prompt.
func TestBashIntegrationMarksACommand(t *testing.T) {
	got := bashSession(t, "true", "false")
	want := []string{
		"\x1b]133;A\x07",
		"\x1b]133;C;cmdline=true\x07",
		"\x1b]133;D;0\x07",
		"\x1b]133;A\x07",
		"\x1b]133;C;cmdline=false\x07",
		"\x1b]133;D;1\x07",
		"\x1b]133;A\x07",
	}
	if strings.Join(got, "") != strings.Join(want, "") {
		t.Errorf("markers = %q, want %q", got, want)
	}
}

// TestBashIntegrationMarksAPipelineOnce is why the command-start marker
// hangs off PS0 rather than a DEBUG trap: bash expands PS0 once per
// command line, where the trap fires once per simple command and would
// report three starts for a three-stage pipeline - two of them inside a
// command tmux already believes to be running.
func TestBashIntegrationMarksAPipelineOnce(t *testing.T) {
	line := "echo hi | cat | cat"
	var starts []string
	for _, s := range bashSession(t, line) {
		if strings.HasPrefix(s, bashStart) {
			starts = append(starts, s)
		}
	}
	want := bashStart + line + "\x07"
	if len(starts) != 1 || starts[0] != want {
		t.Errorf("starts = %q, want exactly one %q", starts, want)
	}
}

// bashStart is the command-start marker up to its command line.
const bashStart = "\x1b]133;C;cmdline="

// bashPayload is the cmdline= value in a command-start marker.
func bashPayload(t *testing.T, marker string) string {
	t.Helper()
	if !strings.HasPrefix(marker, bashStart) || !strings.HasSuffix(marker, "\x07") {
		t.Fatalf("output %q is not a 133;C sequence", marker)
	}
	return strings.TrimSuffix(strings.TrimPrefix(marker, bashStart), "\x07")
}

// lastStart is the last command-start marker in a session's markers.
func lastStart(t *testing.T, seqs []string) string {
	t.Helper()
	var start string
	for _, s := range seqs {
		if strings.HasPrefix(s, bashStart) {
			start = s
		}
	}
	if start == "" {
		t.Fatalf("no command-start marker in %q", seqs)
	}
	return start
}

// TestBashIntegrationEmitsCmdline checks the literal bytes of the
// command-start marker. The command line goes out verbatim: tmux
// sanitises the value it stores, and any escaping added here would be
// escaped a second time there and reach the sidebar unreadable. The one
// thing that must not survive is a control character, which would end the
// OSC sequence early.
func TestBashIntegrationEmitsCmdline(t *testing.T) {
	ordinary := "git log --oneline | head -3"
	if got := bashPreexec(t, ordinary); got != bashStart+ordinary+"\x07" {
		t.Errorf("kido_osc133_preexec(%q) = %q, want the command line verbatim", ordinary, got)
	}

	// ';' and '=' are part of the OSC's own syntax, but cmdline= is the
	// last parameter and its value runs to the end of the string.
	punct := "FOO=bar; make test"
	if got := bashPreexec(t, punct); got != bashStart+punct+"\x07" {
		t.Errorf("kido_osc133_preexec(%q) = %q, want ';' and '=' intact", punct, got)
	}

	nasty := "a\x07b\x1bc"
	got := bashPreexec(t, nasty)
	if want := bashStart + "a b c\x07"; got != want {
		t.Errorf("kido_osc133_preexec(%q) = %q, want %q", nasty, got, want)
	}
	if strings.ContainsAny(bashPayload(t, got), "\x07\x1b") {
		t.Errorf("output %q still carries a raw BEL or ESC inside the OSC payload", got)
	}
}

// TestBashIntegrationTruncatesCmdline pins the 1024-character cap and
// that it cuts by character, so a multibyte rune is never split.
func TestBashIntegrationTruncatesCmdline(t *testing.T) {
	line := "true " + strings.Repeat("héllo", 300) // multibyte, 1505 characters
	start := lastStart(t, bashSession(t, line))
	payload := bashPayload(t, start)
	if n := len([]rune(payload)); n != 1024 {
		t.Fatalf("truncated command line is %d runes, want 1024 (marker %q)", n, start)
	}
	if !strings.HasPrefix(line, payload) {
		t.Errorf("truncated command line is not a prefix of the original")
	}
	if strings.ContainsRune(payload, '\ufffd') {
		t.Errorf("truncated command line %q contains a replacement rune: cut mid-rune", payload)
	}
}
