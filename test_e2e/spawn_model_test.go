package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// writeFakeListModelsPi answers `pi --list-models` with a fixed table in
// the shape pi prints (a header, then provider and model id separated by
// any run of blanks), and otherwise sleeps, standing in for a pi a
// spawned window can run.
func writeFakeListModelsPi(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"case \"$*\" in\n" +
		"  *--list-models*)\n" +
		"    printf 'PROVIDER\\tMODEL\\nacme\\tclaude-sonnet-5\\nacme  claude-opus-5\\nother\\tgemini-pro\\n'\n" +
		"    exit 0\n" +
		"    ;;\n" +
		"esac\n" +
		"exec sleep 300\n"
	if err := os.WriteFile(filepath.Join(dir, "pi"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// A bare alias like "sonnet" - what a bare `pi --model sonnet` silently
// matches no provider for, runs no turn, and exits 0 (the bug report
// this fixes) - must be refused before any window is created.
func TestSpawnRefusesModelRejectedByPi(t *testing.T) {
	t.Parallel()
	piDir := filepath.Join(t.TempDir(), "model-pi-bin")
	writeFakeListModelsPi(t, piDir)
	h := startPathPrefix(t, "alpha", piDir)

	h.liveParent("alpha", "model-e2e-parent")
	// PATH is set on the command itself, not relied on from the pane's own
	// login shell (macOS path_helper puts the machine's real pi first, the
	// trap AGENTS.md describes for the shims): the gate runs `pi` from
	// kido's own environment.
	outFile := filepath.Join(h.dir, "model-refused.out")
	h.sendLiteral(fmt.Sprintf("PATH=%s:$PATH %s tool spawn_subagent --parent-pid 1 --parent-session model-e2e-parent --name model-e2e --task-file %s -- pi --name model-e2e --model sonnet > %s 2>&1; echo rc=$? >> %s",
		shellQuote(piDir), kidoBin, h.writeTaskFile("model-e2e"), outFile, outFile))
	h.sendKeys("Enter")
	var out string
	h.waitFor(func() bool {
		b, err := os.ReadFile(outFile)
		if err != nil || !strings.Contains(string(b), "rc=") {
			return false
		}
		out = string(b)
		return true
	}, settle, msgf("%s to contain an rc= line", outFile))
	if !strings.Contains(out, "acme/{") {
		t.Fatalf("output = %q, want the fake pi's table to have answered, not the machine's own", out)
	}
	if !strings.Contains(out, "rc=1") {
		t.Errorf("kido tool spawn_subagent with an unconfigured model = %q, want rc=1", out)
	}
	if !strings.Contains(out, "sonnet") || !strings.Contains(out, "claude-sonnet-5") {
		t.Errorf("output = %q, want it to name the model and what pi --list-models configured", out)
	}
	if got := h.in("list-windows", "-a", "-F", "#{window_name}"); strings.Contains(got, "model-e2e") {
		t.Errorf("windows = %q, want no window created for a refused spawn", got)
	}
}

// The model gate matches provider/model exactly, against every row pi
// lists, and runs pi only for a pi command that names a model. The
// accepted spawn also pins where --fork and --session-id go: after "pi",
// ahead of the child's own flags.
func TestSpawnModelMustBeAConfiguredProvidersOwn(t *testing.T) {
	t.Parallel()
	piDir := filepath.Join(t.TempDir(), "model-pi-bin")
	writeFakeListModelsPi(t, piDir)
	h := startPathPrefix(t, "alpha", piDir)
	h.liveParent("alpha", "model-e2e-parent")
	// A window's command is looked up on the PATH kido was run with, so each
	// PATH keeps the system directories for the sleep the windows run.
	system := ":/usr/bin:/bin"
	noPi := shellQuote(t.TempDir()) + system
	// Its --list-models fails, so a spawn that ran it would be refused.
	failDir := filepath.Join(t.TempDir(), "failing-pi-bin")
	if err := os.MkdirAll(failDir, 0o755); err != nil {
		t.Fatal(err)
	}
	failing := "#!/bin/sh\ncase \"$*\" in *--list-models*) exit 1 ;; esac\nexec sleep 300\n"
	if err := os.WriteFile(filepath.Join(failDir, "pi"), []byte(failing), 0o755); err != nil {
		t.Fatal(err)
	}

	spawn := func(tag, path string, command ...string) string {
		out := filepath.Join(h.dir, tag+".out")
		h.sendLiteral(fmt.Sprintf("PATH=%s %s tool spawn_subagent --parent-pid 1 --parent-session model-e2e-parent --name %s --task-file %s --fork caller-e2e -- %s > %s 2>&1; echo rc=$? >> %s",
			path, kidoBin, tag, h.writeTaskFile(tag), strings.Join(command, " "), out, out))
		h.sendKeys("Enter")
		return h.waitFileContains(out, "rc=")
	}
	withPi := shellQuote(piDir) + ":$PATH"
	const configured = "acme/{claude-sonnet-5,claude-opus-5}, other/{gemini-pro}"
	for _, m := range []string{"sonnet", "claude-sonnet-5", "nope/claude-sonnet-5"} {
		want := fmt.Sprintf("kido tool spawn_subagent: model %q is not a model of a configured provider; configured: %s\nrc=1\n", m, configured)
		if got := spawn("refused", withPi, "pi", "--model", m); got != want {
			t.Errorf("--model %s: got %q, want %q", m, got, want)
		}
	}
	want := `kido tool spawn_subagent: could not validate model "acme/claude-opus-5": pi --list-models: exec: "pi": executable file not found in $PATH` + "\nrc=1\n"
	if got := spawn("nopi", noPi, "pi", "--model", "acme/claude-opus-5"); got != want {
		t.Errorf("no pi on PATH: got %q, want %q", got, want)
	}
	if got := h.in("list-windows", "-a", "-F", "#{window_name}"); strings.Contains(got, "refused") || strings.Contains(got, "nopi") {
		t.Errorf("windows = %q, want none created for a refused spawn", got)
	}

	// Not pi, or pi with no model: nothing to validate, so pi is never asked.
	for _, c := range [][]string{{"/bin/sh", "-c", shellQuote("exec sleep 300"), "--model", "sonnet"}, {"pi", "--name", "unmodelled"}} {
		if got := spawn("unvalidated-"+strconv.Itoa(len(c)), shellQuote(failDir)+system, c...); len(strings.Fields(got)) != 4 || !strings.Contains(got, "rc=0") {
			t.Errorf("spawn -- %q = %q, want it spawned without asking pi --list-models", c, got)
		}
	}

	got := spawn("accepted", withPi, "pi", "--name", "kid", "--model", "acme/claude-opus-5")
	fields := strings.Fields(got)
	if len(fields) != 4 || !strings.Contains(got, "rc=0") {
		t.Fatalf("--model acme/claude-opus-5 = %q, want it spawned", got)
	}
	wantLine := "pi --fork caller-e2e --session-id " + fields[2] + " --name kid --model acme/claude-opus-5"
	if started := h.startCommand(fields[0]); started != wantLine {
		t.Errorf("accepted pane's command = %q, want %q", started, wantLine)
	}
}

// A child ending itself with no turn ever run (`kido run-outcome
// --unreported`, what share/pi/kido-agents.ts's idle self-exit calls) must
// save its own pane's screen before it exits, not leave that to a sweep
// that may never run before the window closes - `kido close-run` never
// captures a screen at all. The window is kept alive (`sleep 300`) so
// the screen file existing right after run-outcome returns is proof the
// capture happened at self-report time.
func TestRunOutcomeCapturesScreenBeforeWindowCloses(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const marker = "KIDO-E2E-NO-TURN-MARKER-9f3c"
	const noTurnText = "no turn ever ran: the task was delivered and the session never started work on it"
	// spawnRun wraps the script in single quotes (shellQuote), so the
	// detail text needs only its own double quotes, not a second layer.
	// The sleep before run-outcome is not decoration: kido tool spawn_subagent
	// writes meta.json only after Tmux.Exec.new_window returns, so calling
	// run-outcome immediately could win the race against that file existing.
	script := fmt.Sprintf(`echo %s; sleep 0.3; %s run-outcome --result failed --unreported --text "%s" -- "$KIDO_AGENT_RUN_ID"; sleep 300`,
		marker, kidoBin, noTurnText)
	runID, windowID := h.spawnRun("no-turn-e2e", script)

	h.waitFor(func() bool { return h.runOutcome(runID) == "failed" }, settle,
		msgf("run %s to record its own no-turn-ever-ran outcome", runID))

	if !h.windowExists(windowID) {
		t.Fatalf("window %s is already gone; the screen capture race this test checks needs it still up", windowID)
	}
	out := h.runKido("alpha", "no-turn-screen.out", "runs", runID)
	if !strings.Contains(out, marker) {
		t.Errorf("kido runs %s = %q, want the child's own screen captured before it exited, marker %q included", runID, out, marker)
	}
}

// A failure's saved screen refines a no-turn detail with pi's login line,
// the one line saying why no turn ran; any other detail stays as given. A
// completed ending captures nothing.
func TestRunOutcomeNamesPisLoginLine(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const login = "Use /login to log into a provider via OAuth or API key"
	const noTurn = "no turn ever ran: the task was delivered and the session never started work on it"
	for _, c := range []struct{ name, result, text, want string }{
		{"login-e2e", "failed", noTurn, noTurn + ` (the pane showed: "` + login + `")`},
		{"other-e2e", "failed", "exit 1", "exit 1"},
		{"fine-e2e", "completed", "", ""},
	} {
		// The sleep before run-outcome: see TestRunOutcomeCapturesScreenBeforeWindowCloses.
		script := fmt.Sprintf(`echo "%s"; sleep 0.3; %s run-outcome --result %s --text "%s" -- "$KIDO_AGENT_RUN_ID"; sleep 300`,
			login, kidoBin, c.result, c.text)
		runID, _ := h.spawnRun(c.name, script)
		info := h.waitOutcome(runID)
		if info.Outcome != c.result || info.OutcomeText != c.want {
			t.Errorf("%s: outcome %q/%q, want %q/%q", c.name, info.Outcome, info.OutcomeText, c.result, c.want)
		}
		screen, _ := h.runMeta(c.name, runID)["screen"].(string)
		if captured := strings.Contains(screen, login); captured != (c.result == "failed") {
			t.Errorf("%s: screen %q, want it captured for a failure only", c.name, screen)
		}
	}
}
