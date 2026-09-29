package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kido/internal/state"
	"kido/internal/testutil"
)

// TestSpawnHostileWindowNameMatrix pins every character tmuxConfUnsafe
// rejects for --name, refused before any tmux call, plus the boundary
// cases: an empty name, a 500-byte name, a name that is a bare -d or
// --name (not re-parsed as flags), and a name built to look like a shell
// command, which must land as one literal, inert argv element.
func TestSpawnHostileWindowNameMatrix(t *testing.T) {
	type tc struct {
		name        string
		refuse      bool
		wantLiteral string // checked against calls[0].name when refuse is false
	}
	cases := []tc{
		{name: "kid\rx", refuse: true},
		{name: "", refuse: true},
		{name: strings.Repeat("x", 500), refuse: true},
		{name: "-d", refuse: false, wantLiteral: "-d"},
		{name: "--name", refuse: false, wantLiteral: "--name"},
		{name: "kid;touch /tmp/PWNED", refuse: false, wantLiteral: "kid;touch /tmp/PWNED"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			withPanes(t, samePane)
			t.Setenv("TMUX_PANE", "%1")
			withCallerDepth(t, 0)
			calls := withNewWindow(t, "@1", "%1", nil)
			taskFile := writeTaskFile(t, "task")

			err := spawnSubagentCmd([]string{
				"--parent-pid", "1", "--parent-session", testParentSession,
				"--name", c.name, "--task-file", taskFile,
			})
			if c.refuse {
				if err == nil {
					t.Fatalf("spawnSubagentCmd with name %q = nil error, want a refusal", c.name)
				}
				if len(*calls) != 0 {
					t.Errorf("newWindow was called %d times, want the refusal to happen before any tmux call", len(*calls))
				}
				return
			}
			if err != nil {
				t.Fatalf("spawnSubagentCmd with name %q = %v, want it allowed", c.name, err)
			}
			if len(*calls) != 1 || (*calls)[0].name != c.wantLiteral {
				t.Errorf("newWindow calls = %v, want one call naming %q literally", *calls, c.wantLiteral)
			}
		})
	}
}

// TestSpawnHostileTaskTextRoundTrip pins that a task survives byte for
// byte into the run directory, both when --task-file names a file and
// when it is "-" (stdin).
func TestSpawnHostileTaskTextRoundTrip(t *testing.T) {
	cases := []struct {
		name string
		task []byte
	}{
		{"single quote", []byte(`it's a test`)},
		{"double quote", []byte(`say "hi" now`)},
		{"dollar home", []byte(`echo $HOME and $PATH`)},
		{"backtick", []byte("run `id` now")},
		{"backslash", []byte(`C:\Users\x\file`)},
		{"hash", []byte("# not a comment\nmore text")},
		{"newline", []byte("line one\nline two\nline three\n")},
		{"invalid utf8", []byte{0x41, 0xff, 0xfe, 0x42, 0x80}},
		{"nul byte", []byte("before\x00after")},
		{"empty", []byte{}},
	}
	for _, c := range cases {
		t.Run(c.name+"/file", func(t *testing.T) {
			withPanes(t, samePane)
			t.Setenv("TMUX_PANE", "%1")
			withCallerDepth(t, 0)
			calls := withNewWindow(t, "@1", "%1", nil)

			taskFile := filepath.Join(t.TempDir(), "task.bin")
			if err := os.WriteFile(taskFile, c.task, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := spawnSubagentCmd([]string{
				"--parent-pid", "1", "--parent-session", testParentSession,
				"--name", "kid", "--task-file", taskFile,
			}); err != nil {
				t.Fatal(err)
			}
			relocated := envValue(t, (*calls)[0].env, "KIDO_AGENT_TASK_FILE")
			got, err := os.ReadFile(relocated)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, c.task) {
				t.Errorf("relocated task = %q, want %q byte for byte", got, c.task)
			}
		})
		t.Run(c.name+"/stdin", func(t *testing.T) {
			withPanes(t, samePane)
			t.Setenv("TMUX_PANE", "%1")
			withCallerDepth(t, 0)
			calls := withNewWindow(t, "@1", "%1", nil)
			f, err := os.CreateTemp(t.TempDir(), "stdin")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.Write(c.task); err != nil {
				t.Fatal(err)
			}
			if _, err := f.Seek(0, io.SeekStart); err != nil {
				t.Fatal(err)
			}
			testutil.Swap(t, &os.Stdin, f)
			t.Cleanup(func() { f.Close() })

			if err := spawnSubagentCmd([]string{
				"--parent-pid", "1", "--parent-session", testParentSession,
				"--name", "kid", "--task-file", "-",
			}); err != nil {
				t.Fatal(err)
			}
			relocated := envValue(t, (*calls)[0].env, "KIDO_AGENT_TASK_FILE")
			got, err := os.ReadFile(relocated)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, c.task) {
				t.Errorf("relocated task = %q, want %q byte for byte", got, c.task)
			}
		})
	}
}

// TestMessageAddressingDashPrefixedTarget: a model-authored target
// beginning with "-" must not be parsed as a kido flag; pi/kido-agents.ts
// passes "--" before the target to prevent that.
func TestMessageAddressingDashPrefixedTarget(t *testing.T) {
	for _, target := range []string{"-weird", "--help", "-"} {
		t.Run(target, func(t *testing.T) {
			t.Setenv("KIDO_STATE_DIR", t.TempDir())
			t.Setenv("TMUX_PANE", "%1")
			withPanes(t, samePane)

			in := testutil.StartInbox(t, "ok\n")
			if err := state.Record("target", state.Session{
				Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Title: target,
			}); err != nil {
				t.Fatal(err)
			}

			code := messageAgentCmd([]string{"--", target}, strings.NewReader("hi"))
			if code != 0 {
				t.Fatalf("message_agent -- %q = %d, want 0", target, code)
			}
			if msgs := in.Received(); len(msgs) != 1 {
				t.Fatalf("server got %q, want one message", msgs)
			}
		})
	}
}
