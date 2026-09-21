package procs

import (
	"bufio"
	"bytes"
	"os/exec"
	"strings"
)

// psFields runs ps with args and returns its output tokenized into
// whitespace-separated fields per line, via splitPSFields. Sweep and
// parentOf both invoke and split ps output only through this one helper,
// so a robustness fix to either step reaches both. A failure to run ps
// yields no rows, the same as ps reporting an empty table.
func psFields(args ...string) [][]string {
	out, err := exec.Command("ps", args...).Output()
	if err != nil {
		return nil
	}
	return splitPSFields(out)
}

// splitPSFields splits ps output into whitespace-separated fields per
// line, dropping blank lines. It is the pure half of psFields, kept
// separate so row parsing can be table-tested against captured ps output
// without executing ps.
func splitPSFields(out []byte) [][]string {
	var rows [][]string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if f := strings.Fields(sc.Text()); len(f) > 0 {
			rows = append(rows, f)
		}
	}
	return rows
}
