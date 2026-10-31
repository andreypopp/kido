package ko_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func historyProgram(record string) string {
	return fmt.Sprintf("stty raw -echo; i=0; while [ $i -lt 20000 ]; do printf 'history-%%05d: abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\\r\\n' \"$i\"; i=$((i+1)); done; printf '\033]2;history-ready\007\033[?2004hREADY'; tee '%s'", record)
}
func TestFullSnapshotSlowReader(t *testing.T) {
	t.Parallel()
	s := start(t)
	c, _ := s.client("")
	p := s.pane(historyProgram("/dev/null"))
	event(t, c, "title")
	v := s.dialWS("/panes/"+p+"/view?offset=1000000000000&history=all", nil, 101)
	s.request("GET", "/panes/"+p+"/screen", nil, 200, nil)
	var snapshot bytes.Buffer
	v.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		kind, data := read(t, v)
		if kind != websocket.BinaryMessage || len(data) < 11 || data[0] != 2 {
			t.Fatalf("snapshot record: %q", data)
		}
		if data[10] != 0 {
			t.Fatal("full snapshot was downgraded to screen")
		}
		snapshot.Write(data[11:])
		s.request("GET", "/version", nil, 200, nil)
		if data[9]&2 != 0 {
			break
		}
	}
	if snapshot.Len() <= 1<<20 {
		t.Fatalf("fixture does not exceed socket buffer: %d", snapshot.Len())
	}
	terminal := decode(t, snapshot.Bytes(), true)
	if terminal.Rows < 20000 || !strings.Contains(terminal.History, "history-00000:") {
		t.Fatalf("history lost: rows=%d", terminal.Rows)
	}
}
func TestPasteThenEnterDuringSnapshot(t *testing.T) {
	t.Parallel()
	s := start(t)
	c, _ := s.client("")
	record := filepath.Join(s.dir, "input")
	p := s.pane(historyProgram(record))
	event(t, c, "title")
	v := s.dialWS("/panes/"+p+"/view?history=none", nil, 101)
	s.ready(v, "READY")
	messages := []any{
		[]any{"resync", map[string]any{"history": "all", "images": "none"}},
		[]any{"input", []any{"paste", map[string]any{"id": 77, "text": "PASTE", "check_safe": false}}},
		[]any{"input", []any{"key", map[string]any{"action": "press", "key": 58, "mods": 0, "unshifted_codepoint": 0, "text": "", "composing": false}}},
	}
	var batch bytes.Buffer
	for _, message := range messages {
		data, err := json.Marshal(message)
		if err != nil {
			t.Fatal(err)
		}
		if len(data) >= 126 {
			t.Fatal("test frame too large")
		}
		mask := make([]byte, 4)
		if _, err = rand.Read(mask); err != nil {
			t.Fatal(err)
		}
		batch.WriteByte(0x81)
		batch.WriteByte(0x80 | byte(len(data)))
		batch.Write(mask)
		for i, b := range data {
			batch.WriteByte(b ^ mask[i%4])
		}
	}
	v.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := v.UnderlyingConn().Write(batch.Bytes()); err != nil {
		t.Fatal(err)
	}
	s.typeText(v, "BARRIER")
	s.ready(v, "BARRIER")
	input, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte("\033[200~PASTE\033[201~\rBARRIER")
	if !bytes.Equal(input, want) {
		t.Fatalf("input order: %q, want %q", input, want)
	}
}
func TestPaneProcessFailure(t *testing.T) {
	t.Parallel()
	s := start(t)
	c, _ := s.client("")
	p := s.pane("printf READY; cat")
	v := s.dialWS("/panes/"+p+"/view", nil, 101)
	s.ready(v, "READY")
	var rows []struct {
		ID  string
		PID int
	}
	s.request("GET", "/panes", nil, 200, &rows)
	var pid int
	for _, row := range rows {
		if row.ID == p {
			pid = row.PID
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	parent, err := exec.CommandContext(ctx, "ps", "-o", "ppid=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		t.Fatal(err)
	}
	parentPID, err := strconv.Atoi(strings.TrimSpace(string(parent)))
	if err != nil || parentPID <= 1 || pid <= 1 {
		t.Fatalf("parent pid: %s %v", parent, err)
	}
	send(t, v, []any{"resync", map[string]any{"history": "all", "images": "none"}})
	if err = syscall.Kill(owned(t, parentPID, s.cmd.Process.Pid), syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	dead := event(t, c, "dead")
	if !bytes.Contains(dead, []byte(`"cause":["failed",`)) {
		t.Fatalf("failed pane: %s", dead)
	}
	s.request("GET", "/panes/"+p+"/screen", nil, 500, nil)
	s.request("POST", "/panes/"+p+"/input", []any{"paste", map[string]any{"text": "x", "check_safe": false}}, 500, nil)
	v.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, _, err = v.ReadMessage(); err != nil {
			if strings.Contains(err.Error(), "timeout") {
				t.Fatal("failed pane view did not close")
			}
			break
		}
	}
}
func TestUnfocusedFirstClientSizesPane(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("printf READY; cat")
	c := s.dialWS("/client", nil, 101)
	send(t, c, []any{"hello", map[string]any{"kind": "terminal", "name": "unfocused", "focused": false, "pane": p, "size": map[string]any{"cols": 51, "rows": 13, "cell_px": map[string]int{"width": 8, "height": 16}}}})
	event(t, c, "welcome")
	event(t, c, "topology")
	v := s.dialWS("/panes/"+p+"/view", nil, 101)
	data, _ := snapshot(t, v)
	if terminal := decode(t, data); terminal.Rows != 13 {
		t.Fatalf("unfocused sizing: rows=%d", terminal.Rows)
	}
}

// A view with a snapshot still queued cannot read the resize marker that arrives after it. Another
// view's snapshot then pushes that marker out of the ring. The stalled view must still learn the new size.
func TestStalledViewLearnsResizeAfterRingRetention(t *testing.T) {
	t.Parallel()
	s := start(t)
	c, _ := s.client("")
	p := s.pane(historyProgram("/dev/null"))
	event(t, c, "title")
	sizer, _ := s.client(p)
	stalled := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	reader := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	snapshot(t, reader)
	send(t, sizer, []any{"size", map[string]any{"cols": 61, "rows": 21, "cell_px": map[string]int{"width": 8, "height": 16}}})
	event(t, reader, "marked")
	flood := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	snapshot(t, flood)
	snapshot(t, stalled)
	stalled.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		kind, data := read(t, stalled)
		if kind == websocket.BinaryMessage && len(data) >= 11 && data[0] == 2 && data[9]&1 != 0 {
			return
		}
		if tag, payload := tagged(data); kind == websocket.TextMessage && tag == "marked" && bytes.Contains(payload, []byte(`"cols":61`)) {
			return
		}
	}
}

func TestResumeSkipsResizeMarkersBeforeTheOffset(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("stty -echo -icanon min 1 time 0; printf READY; cat -v")
	c, _ := s.client(p)
	v := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	s.ready(v, "READY")
	send(t, c, []any{"size", map[string]any{"cols": 62, "rows": 22, "cell_px": map[string]int{"width": 8, "height": 16}}})
	event(t, v, "marked")
	s.typeText(v, "later\n")
	offset := output(t, v, "later")
	v.Close()
	v = s.dialWS(fmt.Sprintf("/panes/%s/view?history=all&offset=%d", p, offset), nil, 101)
	s.typeText(v, "after\n")
	for text := ""; !strings.Contains(text, "after"); {
		kind, data := read(t, v)
		switch {
		case kind == websocket.BinaryMessage && len(data) >= 9 && data[0] == 1:
			text += string(data[9:])
		case kind == websocket.TextMessage:
			t.Fatalf("resume replayed a message from before its offset: %s", data)
		default:
			t.Fatalf("unexpected record on resume: %q", data)
		}
	}
}

func TestDeathHasOneTimestamp(t *testing.T) {
	t.Parallel()
	s := start(t)
	c, _ := s.client("")
	p := s.pane("printf READY; IFS= read -r go; exit 7")
	v := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	s.ready(v, "READY")
	s.request("POST", "/panes/"+p+"/input", []any{"text", base64.StdEncoding.EncodeToString([]byte("\n"))}, 200, nil)
	var notice struct {
		Dead struct{ At int64 }
	}
	if err := json.Unmarshal(event(t, c, "dead"), &notice); err != nil {
		t.Fatal(err)
	}
	var marked struct {
		Marker [2]json.RawMessage
	}
	if err := json.Unmarshal(event(t, v, "marked"), &marked); err != nil {
		t.Fatal(err)
	}
	var marker struct{ At int64 }
	if err := json.Unmarshal(marked.Marker[1], &marker); err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Dead struct{ At int64 }
	}
	s.request("GET", "/panes", nil, 200, &rows)
	if notice.Dead.At == 0 || notice.Dead.At != marker.At || notice.Dead.At != rows[0].Dead.At {
		t.Fatalf("death times differ: event %d, view marker %d, row %d", notice.Dead.At, marker.At, rows[0].Dead.At)
	}
}
