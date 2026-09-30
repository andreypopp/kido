package e2e

import (
	"bytes"
	"os/exec"
	"strings"
	"testing"
)

// Every --help must render cleanly. cmdliner reads "$" in a doc string as
// the start of its own markup, so a doc that names an environment
// variable as $NAME makes it print "cmdliner error: unescaped '$'" to
// stderr - three times, once per formatting pass - before the help it was
// asked for. The variable belongs in $(b,NAME), which is also what makes
// it bold. Checked for every command, because the next one to name a
// variable is the one that would regress.
func TestHelpRendersWithoutCmdlinerErrors(t *testing.T) {
	t.Parallel()
	// subcommands are asked of the binary itself, rather than kept as a
	// list here that a new command would not be added to. A bare `kido`
	// with no arguments prints the manual, whose COMMANDS section names
	// each one first on its line.
	out, err := exec.Command(kidoBin, "--help=plain").Output()
	if err != nil {
		t.Fatalf("kido --help=plain: %v", err)
	}
	var names []string
	inCommands, afterBlank := false, false
	for _, line := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(line, "COMMANDS"):
			inCommands, afterBlank = true, true
			continue
		case line != "" && !strings.HasPrefix(line, " "):
			inCommands = false
			continue
		}
		blank := strings.TrimSpace(line) == ""
		// A command's entry opens with its name on a line indented by
		// seven spaces, and each entry follows a blank line. Both tests
		// matter: the description is indented further, and a synopsis
		// too long for the width wraps onto another seven-space line
		// whose first word ("RUN_ID") is not a command.
		if inCommands && afterBlank && strings.HasPrefix(line, "       ") && !strings.HasPrefix(line, "        ") {
			names = append(names, strings.Fields(line)[0])
		}
		afterBlank = blank
	}
	if len(names) < 10 {
		t.Fatalf("found %d subcommands in the manual, want the whole list:\n%s", len(names), out)
	}
	for _, name := range names {
		// `kido ssh` is a wrapper: it hands its arguments to the real
		// ssh, so --help is ssh's to answer and ssh writes its usage to
		// stderr. There is no cmdliner help here to render.
		if name == "ssh" {
			continue
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			cmd := exec.Command(kidoBin, name, "--help=plain")
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			if err := cmd.Run(); err != nil {
				t.Fatalf("kido %s --help=plain: %v\n%s", name, err, stderr.String())
			}
			if got := stderr.String(); got != "" {
				t.Errorf("kido %s --help=plain wrote to stderr:\n%s", name, got)
			}
		})
	}
}
