package ko_test

import (
	"encoding/json"
	"testing"
)

func checkInputFrames(t *testing.T, split bool) {
	s := start(t)
	pane := s.pane("printf 'INPUT-READY\\n'; exec /bin/sh")
	view := s.dialWS("/panes/"+pane+"/view", nil, 101)
	s.ready(view, "INPUT-READY")
	var burst []byte
	cut := 0
	for i, c := range []byte("echo abc\r") {
		key := 20 + int(c-'a')
		codepoint := int(c)
		text := string(c)
		if c == ' ' {
			key = 63
		}
		if c == '\r' {
			key = 58
			codepoint = 0
			text = ""
		}
		payload, err := json.Marshal(map[string]any{"key": map[string]any{"action": 1, "key": key, "mods": 0, "unshifted_codepoint": codepoint, "text": text, "composing": false}})
		if err != nil {
			t.Fatal(err)
		}
		if len(payload) >= 126 {
			t.Fatal("test frame exceeds short header")
		}
		frame := append([]byte{0x81, 0x80 | byte(len(payload)), 1, 2, 3, 4}, payload...)
		for j := range payload {
			frame[6+j] ^= byte(j%4 + 1)
		}
		if i == 4 {
			cut = len(burst) + 3
		}
		burst = append(burst, frame...)
	}
	conn := view.UnderlyingConn()
	if split {
		if n, err := conn.Write(burst[:cut]); err != nil || n != cut {
			t.Fatalf("first fragment: %d %v", n, err)
		}
		output(t, view, "echo")
		if n, err := conn.Write(burst[cut:]); err != nil || n != len(burst)-cut {
			t.Fatalf("last fragment: %d %v", n, err)
		}
	} else if n, err := conn.Write(burst); err != nil || n != len(burst) {
		t.Fatalf("burst: %d %v", n, err)
	}
	output(t, view, "\r\nabc\r\n")
}
func TestViewInputFramesInOneWrite(t *testing.T)       { t.Parallel(); checkInputFrames(t, false) }
func TestViewInputFrameSplitAcrossWrites(t *testing.T) { t.Parallel(); checkInputFrames(t, true) }
