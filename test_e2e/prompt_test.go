package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func (h *harness) waitInbox(in *inbox, want ...string) {
	h.t.Helper()
	h.waitFor(func() bool {
		got := in.Received()
		if len(got) != len(want) {
			return false
		}
		for i := range got {
			if got[i] != want[i] {
				return false
			}
		}
		return true
	}, settle, func() string {
		return fmt.Sprintf("inbox to receive %q (has %q)", want, in.Received())
	})
}

// agentPaneHere, unlike piPane (new window), splits target's own
// window, for testing kido prompt's window scope.
func (h *harness) agentPaneHere(target, title string) string {
	h.t.Helper()
	id := h.in("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", target, filepath.Join(piBinDir, "pi"), "--")
	h.waitPaneCommand(id, "pi")
	h.title(id, title)
	h.programStatus(id, "state=idle:app=pi")
	h.agentStatus("prompt-"+id, id, "pi")
	return id
}

func (h *harness) promptPane(session, title string) string {
	id := h.piPane(session, title)
	h.agentStatus("prompt-"+id, id, "pi")
	return id
}

func (h *harness) runPrompt(text string, args ...string) {
	h.t.Helper()
	cmd := fmt.Sprintf("printf %s | %s prompt %s; echo rc=$?",
		shellQuote(text), kidoBin, strings.Join(args, " "))
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
}

func shellQuote(s string) string { return "'" + s + "'" }

// waitMain, unlike waitRow, looks at the whole screen including the
// window area. Only useful for the active window's pane; see
// waitPaneText for one in another window.
func (h *harness) waitMain(sub string) {
	h.t.Helper()
	h.waitFor(func() bool {
		for _, l := range h.capture() {
			if strings.Contains(ansi.Strip(l), sub) {
				return true
			}
		}
		return false
	}, settle, msgf("screen shows %q", sub))
}

func (h *harness) paneText(id string) string {
	h.t.Helper()
	out, err := h.tmux(h.inner, "capture-pane", "-p", "-t", id)
	if err != nil {
		return ""
	}
	return out
}

func (h *harness) waitPaneText(id, sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return strings.Contains(h.paneText(id), sub) }, settle,
		func() string { return fmt.Sprintf("pane %s shows %q (is %q)", id, sub, h.paneText(id)) })
}

// paneLines trims the front too (capture-pane already drops trailing
// blanks), so a line is comparable to what was typed or printed on it.
func (h *harness) paneLines(id string) []string {
	h.t.Helper()
	var out []string
	for _, l := range strings.Split(h.paneText(id), "\n") {
		out = append(out, strings.TrimSpace(l))
	}
	return out
}

// waitPaneLine distinguishes a command's output ("AAA") from the command
// line that produced it ("echo AAA") by requiring an exact row match.
func (h *harness) waitPaneLine(id, want string) {
	h.t.Helper()
	h.waitFor(func() bool {
		for _, l := range h.paneLines(id) {
			if l == want {
				return true
			}
		}
		return false
	}, settle, func() string {
		return fmt.Sprintf("pane %s to have a row %q (is %q)", id, want, h.paneText(id))
	})
}

func lineIndex(lines []string, match func(string) bool) int {
	for i, l := range lines {
		if match(l) {
			return i
		}
	}
	return -1
}

// A two-line prompt must reach the agent as one input, not one per line.
// zsh is the stand-in for Claude Code: zle enables bracketed paste the
// same way, so it can tell a paste from typed keys. As typed keys the
// middle newline is an Enter, running "echo AAA" before "echo BBB" is
// even typed; as a paste both lines land in one command line and only
// the trailing Enter runs them - so both echoes appear before either
// output does. That order is the assertion.
func TestPromptMultiLine(t *testing.T) {
	t.Parallel()
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	h := start(t, "alpha")

	// -f: no rc files, so the developer's own zsh setup cannot change what
	// this test sees.
	pane := h.newWindow("alpha", "", zsh, "-f")
	h.waitPaneCommand(pane, "zsh")
	// zle must be up (bracketed paste on) before the paste lands, or tmux
	// writes the bytes raw; zsh -f's default prompt ends in "%".
	h.waitFor(func() bool {
		for _, l := range h.paneLines(pane) {
			if strings.HasSuffix(l, "%") {
				return true
			}
		}
		return false
	}, settle, func() string {
		return fmt.Sprintf("pane %s to reach a zsh prompt (is %q)", pane, h.paneText(pane))
	})

	// No inbox socket: kido delivers through Tmux.Exec.send_prompt, not the
	// socket path (TestPromptInboxNative).
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("pi-1", pane, "pi")

	// printf expands \n inside the pane, not the caller's shell.
	h.runPrompt(`echo AAA\necho BBB`)
	h.waitMain("rc=0")
	h.waitPaneLine(pane, "BBB") // both lines have run by now

	lines := h.paneLines(pane)
	echoBBB := lineIndex(lines, func(l string) bool { return strings.Contains(l, "echo BBB") })
	outAAA := lineIndex(lines, func(l string) bool { return l == "AAA" })
	if echoBBB < 0 || outAAA < 0 || echoBBB > outAAA {
		t.Errorf("the two lines were not one input: %q\n"+
			"want the second line (row %d) on screen before AAA's output (row %d)",
			h.paneText(pane), echoBBB, outAAA)
	}
}

// A pi pane split into the caller's own window is found without
// searching the session - a second pane in another window means a naive
// "always search the session" implementation would see two candidates
// and exit 5 here.
func TestPromptDefaultWindowOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	inWindow := h.agentPaneHere("alpha:", "✳ Claude")
	h.promptPane("alpha", "✳ Other") // another window, same session

	h.runPrompt("hello there")
	h.waitMain("rc=0")
	h.waitPaneText(inWindow, "got: hello there")
}

// Several pi panes in the window is exit 5; the window is not
// empty, so the search never widens to the session.
func TestPromptDefaultWindowSeveral(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.agentPaneHere("alpha:", "✳ One")
	h.agentPaneHere("alpha:", "✳ Two")

	h.runPrompt("hi")
	h.waitMain("multiple agents found")
	h.waitMain("rc=5")
}

// The default scope widens to the session when the window has none.
func TestPromptDefaultSessionOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.promptPane("alpha", "✳ Claude") // a new window, not the shell's own

	h.runPrompt("session scope")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: session scope")
}

// A spawned subagent's window is never a candidate: with the window
// empty and a pi subagent elsewhere, the widened search
// still delivers to the top-level agent rather than seeing two
// candidates and exiting 5.
func TestPromptExcludesSubagentWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	topLevel := h.promptPane("alpha", "✳ Claude") // a new window, not the shell's own

	taskFile := filepath.Join(h.dir, "task.txt")
	if err := os.WriteFile(taskFile, []byte("do the thing"), 0o644); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(h.dir, "spawn.out")
	cmd := fmt.Sprintf("%s tool spawn_subagent --no-parent --name sub-e2e --task-file %s -- %s -- > %s 2>&1",
		kidoBin, taskFile, filepath.Join(piBinDir, "pi"), outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	subPane := fields[1]
	h.waitPaneCommand(subPane, "pi")
	h.programStatus(subPane, "state=idle:app=pi", "sub-e2e")
	if status := h.in("display-message", "-p", "-t", subPane, "#{pane_program_status}"); !strings.Contains(status, `"app":"pi"`) {
		t.Fatalf("subagent missing its root before prompt: %s", status)
	}

	h.runPrompt("hi")
	h.waitMain("rc=0")
	h.waitPaneText(topLevel, "got: hi")
}

func TestPromptDefaultSessionSeveral(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.promptPane("alpha", "✳ One")
	h.promptPane("alpha", "✳ Two")

	h.runPrompt("hi")
	h.waitMain("multiple agents found")
	h.waitMain("rc=5")
}

func TestPromptDefaultNone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.runPrompt("hi")
	h.waitMain("agent not found")
	h.waitMain("rc=4")
}

// --window never widens to the session.
func TestPromptWindowFlagNoneElsewhereInSession(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.promptPane("alpha", "✳ Claude") // a new window, not the shell's own

	h.runPrompt("hi", "--window")
	h.waitMain("agent not found")
	h.waitMain("rc=4")
}

// A pane whose agent reported an inbox socket gets the prompt as a
// message over that socket, no keystrokes at all - the pane's own screen
// must stay as the agent drew it.
func TestPromptInboxNative(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.promptPane("alpha", "π - alpha")
	in := startInbox(t, "ok\n")
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("pi-1", pane, "pi", "--inbox", in.Path)

	h.runPrompt("over the socket")
	h.waitMain("rc=0")
	h.waitInbox(in, "over the socket")
	if got := h.paneText(pane); strings.Contains(got, "got:") { // a wrong send would already be on screen
		t.Errorf("pane %s was typed into as well: %q", pane, got)
	}
}

func TestPromptInboxUnavailable(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.promptPane("alpha", "π - alpha")
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("pi-1", pane, "pi", "--inbox", staleSocket(t))

	h.runPrompt("not pasted")
	h.waitMain("rc=1")
	h.waitMain("alpha is not accepting messages")
	h.stays(func() bool { return !strings.Contains(h.paneText(pane), "got: not pasted") },
		"a prompt to a closed inbox was pasted")
}

func TestPromptWindowFlagOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.agentPaneHere("alpha:", "✳ Claude")

	h.runPrompt("hello there", "--window")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: hello there")
}
