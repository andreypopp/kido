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
	// list here that a new command would not be added to. Each manual's
	// COMMANDS section names each subcommand first on its line.
	var walk func(*testing.T, []string)
	walk = func(t *testing.T, path []string) {
		cmd := exec.Command(kidoBin, append(path, "--help=plain")...)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("kido %s --help=plain: %v\n%s", strings.Join(path, " "), err, stderr.String())
		}
		if got := stderr.String(); got != "" {
			t.Errorf("kido %s --help=plain wrote to stderr:\n%s", strings.Join(path, " "), got)
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
			// Entries follow a blank and use seven spaces; wrapped
			// synopses and further-indented descriptions are not names.
			if inCommands && afterBlank && strings.HasPrefix(line, "       ") && !strings.HasPrefix(line, "        ") {
				names = append(names, strings.Fields(line)[0])
			}
			afterBlank = blank
		}
		if len(path) == 0 && len(names) != 21 || len(path) == 1 && path[0] == "tool" && len(names) != 12 {
			t.Fatalf("found %d subcommands in the manual, want the whole list:\n%s", len(names), out)
		}
		for _, name := range names {
			// ssh passes --help to ssh, which writes its usage to stderr.
			if len(path) == 0 && name == "ssh" {
				continue
			}
			t.Run(name, func(t *testing.T) {
				t.Parallel()
				walk(t, append(append([]string{}, path...), name))
			})
		}
	}
	walk(t, nil)
}
