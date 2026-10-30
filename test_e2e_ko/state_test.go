package ko_test

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestLiveSynchronizedSnapshotAndHistory(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("i=0; while [ $i -lt 100 ]; do printf 'history-%s\\r\\n' $i; i=$((i+1)); done; printf '\033[?2026hSYNCREADY'; IFS= read -r done")
	v := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	data, _ := snapshot(t, v)
	terminal := decode(t, data)
	if !strings.Contains(terminal.Screen, "SYNCREADY") {
		output(t, v, "SYNCREADY")
		send(t, v, map[string]any{"resync": map[string]any{"history": "all", "images": "none"}})
		data, _ = snapshot(t, v)
		terminal = decode(t, data)
	}
	if terminal.Sync {
		t.Fatal("snapshot retains mode 2026")
	}
	history := s.request("GET", "/panes/"+p+"/screen?history=all", nil, 200, nil)
	screen := s.request("GET", "/panes/"+p+"/screen?history=none", nil, 200, nil)
	if !strings.Contains(history, "history-0\r") && !strings.Contains(history, "history-0\n") {
		t.Fatalf("history missing: %q", history)
	}
	if strings.Contains(screen, "history-0\n") || !strings.Contains(screen, "SYNCREADY") {
		t.Fatalf("screen selection: %q", screen)
	}
}
func TestUnsafePasteIsNotWritten(t *testing.T) {
	t.Parallel()
	s := start(t)
	record := filepath.Join(s.dir, "input")
	p := s.pane(fmt.Sprintf("stty raw -echo; printf READY; tee '%s'", record))
	v := s.dialWS("/panes/"+p+"/view", nil, 101)
	s.ready(v, "READY")
	var response struct {
		Paste struct {
			Pasted bool
			Unsafe bool
		}
	}
	s.request("POST", "/panes/"+p+"/input", map[string]any{"paste": map[string]any{"id": 41, "text": "unsafe\n", "check_safe": true}}, 200, &response)
	if response.Paste.Pasted || !response.Paste.Unsafe {
		t.Fatalf("unsafe response: %+v", response)
	}
	s.typeText(v, "BARRIER")
	output(t, v, "BARRIER")
	input, e := os.ReadFile(record)
	if e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(input, []byte("BARRIER")) {
		t.Fatalf("unsafe input written: %q", input)
	}
}
func TestSIGTERMKillsPrograms(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("trap '' HUP; printf READY; while :; do read x; done")
	v := s.dialWS("/panes/"+p+"/view", nil, 101)
	s.ready(v, "READY")
	var panes []struct {
		PID int `json:"pid"`
	}
	s.request("GET", "/panes", nil, 200, &panes)
	if len(panes) != 1 || panes[0].PID <= 0 {
		t.Fatalf("program pid: %+v", panes)
	}
	s.stop()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		if err := syscall.Kill(panes[0].PID, 0); err == syscall.ESRCH {
			break
		}
		select {
		case <-deadline.C:
			t.Fatalf("program %d survived shutdown", panes[0].PID)
		case <-tick.C:
		}
	}
}
func TestClientCloseClosesItsViews(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("printf READY; cat")
	c, id := s.client(p)
	h := s.headers()
	h.Set("Ko-Client", id)
	v := s.dialWS("/panes/"+p+"/view", h, 101)
	snapshot(t, v)
	c.Close()
	v.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, _, e := v.ReadMessage(); e != nil {
			if strings.Contains(e.Error(), "timeout") {
				t.Fatal("view survived client close")
			}
			break
		}
	}
	req := s.headers()
	req.Set("Ko-Client", id)
	s.dialWS("/panes/"+p+"/view", req, 410)
}
