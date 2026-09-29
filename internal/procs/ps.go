package procs

import (
	"bufio"
	"bytes"
	"os/exec"
	"strings"
)

// psFields runs ps with args and returns its output tokenized into
// whitespace-separated fields per line. A failure to run ps yields no
// rows, the same as ps reporting an empty table.
func psFields(args ...string) [][]string {
	out, err := exec.Command("ps", args...).Output()
	if err != nil {
		return nil
	}
	return splitPSFields(out)
}

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
