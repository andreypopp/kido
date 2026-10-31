package ko_test

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStalledViewSkips(t *testing.T) {
	t.Parallel()
	s := start(t)
	c, _ := s.client("")
	p := s.pane("printf READY; IFS= read -r start; head -c 8388608 /dev/zero | tr '\\000' x; printf LAST")
	v := s.dialWS("/panes/"+p+"/view", nil, 101)
	s.ready(v, "READY")
	s.request("POST", "/panes/"+p+"/input", []any{"text", base64.StdEncoding.EncodeToString([]byte("\n"))}, 200, nil)
	event(t, c, "dead")
	event(t, v, "skipped")
	data, _ := snapshot(t, v)
	if !strings.Contains(decode(t, data).Screen, "LAST") {
		t.Fatal("skip snapshot is not current")
	}
}
func TestDetachKeepsKittyInput(t *testing.T) {
	t.Parallel()
	s := start(t)
	record := filepath.Join(s.dir, "input")
	p := s.pane(fmt.Sprintf("stty raw -echo; printf '\033[=3;1uREADY'; tee '%s'", record))
	c, _ := s.client(p)
	v := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	s.ready(v, "READY")
	key := []any{"input", []any{"key", map[string]any{"action": "press", "key": 20, "mods": 2, "unshifted_codepoint": 97, "text": "a", "composing": false}}}
	send(t, v, key)
	s.typeText(v, "FIRST")
	output(t, v, "FIRST")
	c.Close()
	v.Close()
	c, _ = s.client(p)
	_ = c
	v = s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	snapshot(t, v)
	send(t, v, key)
	s.typeText(v, "BARRIER")
	output(t, v, "BARRIER")
	input, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte("\033[97;5uFIRST\033[97;5uBARRIER")
	if !bytes.Equal(input, want) {
		t.Fatalf("pty input: %q, want %q", input, want)
	}
}
func TestPartialResizeSnapshot(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("printf READY; cat")
	c, _ := s.client(p)
	v := s.dialWS("/panes/"+p+"/view?history=none", nil, 101)
	snapshot(t, v)
	send(t, c, []any{"size", map[string]any{"cols": 51, "rows": 13, "cell_px": map[string]int{"width": 8, "height": 16}}})
	data, _ := snapshot(t, v)
	terminal := decode(t, data)
	if terminal.Rows != 13 {
		t.Fatalf("partial resize: %+v", terminal)
	}
}
