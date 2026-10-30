package ko_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

var root string

func TestMain(m *testing.M) {
	var err error
	root, err = filepath.Abs("..")
	if err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "dune", "build", "bin/ko.exe", "bin/ko-pane", "ko_vt/decode.exe", "ko_vt/xterm-ghostty")
	cmd.Dir = root
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		os.Exit(1)
	}
	os.Exit(m.Run())
}

type server struct {
	t    *testing.T
	dir  string
	cmd  *exec.Cmd
	http *http.Client
	vt   string
	log  bytes.Buffer
	wait chan error
	once sync.Once
}

func start(t *testing.T, args ...string) *server {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "ko-")
	if err != nil {
		t.Fatal(err)
	}
	s := &server{t: t, dir: dir, wait: make(chan error, 1)}
	s.cmd = exec.Command(filepath.Join(root, "_build/default/bin/ko.exe"), append([]string{"server", "--server", dir, "--shell", "/bin/sh"}, args...)...)
	// Keep this list in step with cleanEnv in test_e2e/harness_test.go.
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if name == "HOME" || strings.HasPrefix(name, "XDG_") || strings.HasPrefix(name, "KO_") || strings.HasPrefix(name, "KIDO_") || strings.HasPrefix(name, "TMUX") || strings.HasPrefix(name, "BASH_FUNC_") || name == "ZDOTDIR" || name == "ENV" || name == "BASH_ENV" {
			continue
		}
		s.cmd.Env = append(s.cmd.Env, entry)
	}
	s.cmd.Env = append(s.cmd.Env, "HOME="+dir, "XDG_CONFIG_HOME="+dir, "XDG_STATE_HOME="+dir)
	s.cmd.Stdout = &s.log
	s.cmd.Stderr = &s.log
	if err = s.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { s.wait <- s.cmd.Wait() }()
	s.http = &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DialContext: s.dial}}
	t.Cleanup(func() { s.stop(); s.http.CloseIdleConnections(); os.RemoveAll(dir) })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var conn net.Conn
	for ctx.Err() == nil {
		conn, err = s.dial(ctx, "", "")
		if err == nil {
			conn.Close()
			break
		}
	}
	if err != nil {
		t.Fatalf("socket: %v: %s", err, s.log.String())
	}
	var version struct {
		VT string `json:"vt"`
	}
	s.request("GET", "/version", nil, 200, &version)
	s.vt = version.VT
	return s
}
func (s *server) dial(ctx context.Context, _, _ string) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, "unix", filepath.Join(s.dir, "socket"))
}
func (s *server) stop() {
	s.once.Do(func() {
		_ = s.cmd.Process.Signal(syscall.SIGTERM)
		select {
		case err := <-s.wait:
			if err != nil {
				s.t.Errorf("server: %v: %s", err, s.log.String())
			}
		case <-time.After(3 * time.Second):
			_ = s.cmd.Process.Kill()
			s.t.Errorf("shutdown timed out: %s", s.log.String())
		}
	})
}
func (s *server) headers() http.Header {
	h := http.Header{"Ko-Protocol": []string{"1.0"}}
	if s.vt != "" {
		h.Set("Ko-Vt", s.vt)
	}
	return h
}
func (s *server) request(method, path string, body any, status int, out any) string {
	s.t.Helper()
	var data []byte
	if body != nil {
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			s.t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, "http://ko"+path, bytes.NewReader(data))
	if err != nil {
		s.t.Fatal(err)
	}
	req.Header = s.headers()
	response, err := s.http.Do(req)
	if err != nil {
		s.t.Fatalf("%s %s: %v (%s)", method, path, err, s.log.String())
	}
	defer response.Body.Close()
	data, err = io.ReadAll(response.Body)
	if err != nil {
		s.t.Fatal(err)
	}
	if response.StatusCode != status {
		s.t.Fatalf("%s %s: %d %s (%s)", method, path, response.StatusCode, data, s.log.String())
	}
	if out != nil {
		if err = json.Unmarshal(data, out); err != nil {
			s.t.Fatalf("decode %s: %v", data, err)
		}
	}
	return string(data)
}
func (s *server) dialWS(path string, headers http.Header, status int) *websocket.Conn {
	s.t.Helper()
	if headers == nil {
		headers = s.headers()
	}
	d := websocket.Dialer{NetDialContext: s.dial, HandshakeTimeout: 5 * time.Second}
	c, r, e := d.Dial("ws://ko"+path, headers)
	if status != 101 {
		if c != nil {
			c.Close()
		}
		if e == nil || r == nil || r.StatusCode != status {
			s.t.Fatalf("upgrade %s: %v %v", path, r, e)
		}
		r.Body.Close()
		return nil
	}
	if e != nil {
		s.t.Fatalf("upgrade %s: %v (%s)", path, e, s.log.String())
	}
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	s.t.Cleanup(func() { c.Close() })
	return c
}
func (s *server) ready(v *websocket.Conn, needle string) {
	data, _ := snapshot(s.t, v)
	if !strings.Contains(decode(s.t, data).Screen, needle) {
		output(s.t, v, needle)
	}
}
func (s *server) typeText(v *websocket.Conn, text string) {
	send(s.t, v, map[string]any{"text": base64.StdEncoding.EncodeToString([]byte(text))})
}
func send(t *testing.T, c *websocket.Conn, value any) {
	t.Helper()
	c.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if e := c.WriteJSON(value); e != nil {
		t.Fatal(e)
	}
}
func read(t *testing.T, c *websocket.Conn) (int, []byte) {
	t.Helper()
	k, b, e := c.ReadMessage()
	if e != nil {
		t.Fatal(e)
	}
	return k, b
}
func event(t *testing.T, c *websocket.Conn, key string) map[string]json.RawMessage {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	for i := 0; i < 10000; i++ {
		_, b := read(t, c)
		var m map[string]json.RawMessage
		if json.Unmarshal(b, &m) == nil && m[key] != nil {
			return m
		}
	}
	t.Fatalf("no %s", key)
	return nil
}

var size = map[string]int{"cols": 80, "rows": 24, "cell_w_px": 8, "cell_h_px": 16}

func (s *server) client(pane string) (*websocket.Conn, string) {
	c := s.dialWS("/client", nil, 101)
	h := map[string]any{"kind": "terminal", "name": "test", "focused": true, "size": size}
	if pane != "" {
		h["pane"] = pane
	}
	send(s.t, c, map[string]any{"hello": h})
	var identity struct{ Client string }
	for _, key := range []string{"welcome", "topology"} {
		_, data := read(s.t, c)
		var message map[string]json.RawMessage
		if json.Unmarshal(data, &message) != nil || message[key] == nil {
			s.t.Fatalf("expected %s, got %s", key, data)
		}
		if key == "welcome" {
			if e := json.Unmarshal(message[key], &identity); e != nil {
				s.t.Fatal(e)
			}
		}
	}
	return c, identity.Client
}
func (s *server) pane(command string) string {
	var response struct {
		Pane string `json:"pane"`
	}
	s.request("POST", "/panes", map[string]any{"command": []string{"/bin/sh", "-c", command}, "cwd": "/tmp"}, 200, &response)
	return response.Pane
}
func snapshot(t *testing.T, c *websocket.Conn) ([]byte, uint64) {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	var result []byte
	var offset uint64
	for i := 0; i < 10000; i++ {
		k, b := read(t, c)
		if k != websocket.BinaryMessage || len(b) < 11 || b[0] != 2 {
			continue
		}
		offset = binary.LittleEndian.Uint64(b[1:9])
		if b[9]&1 != 0 {
			result = nil
		}
		result = append(result, b[11:]...)
		if b[9]&2 != 0 {
			return result, offset
		}
	}
	t.Fatal("snapshot never completed")
	return nil, 0
}
func decode(t *testing.T, data []byte, full ...bool) struct {
	Sync    bool
	Rows    int
	Screen  string
	History string
} {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(root, "_build/default/ko_vt/decode.exe"))
	if len(full) > 0 && full[0] {
		cmd.Args = append(cmd.Args, "--full")
	}
	cmd.Stdin = bytes.NewReader(data)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("decode: %v: %s", err, output)
	}
	var result struct {
		Sync    bool
		Rows    int
		Screen  string
		History string
	}
	if err = json.Unmarshal(output, &result); err != nil {
		t.Fatal(err)
	}
	return result
}
func output(t *testing.T, c *websocket.Conn, needle string) uint64 {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	var text string
	for i := 0; i < 10000; i++ {
		k, b := read(t, c)
		if k == websocket.BinaryMessage && len(b) >= 9 && b[0] == 1 {
			text += string(b[9:])
			if strings.Contains(text, needle) {
				return binary.LittleEndian.Uint64(b[1:9]) + uint64(len(b)-9)
			}
		}
	}
	t.Fatalf("no output %q", needle)
	return 0
}
func TestPaneDeadSnapshot(t *testing.T) {
	t.Parallel()
	s := start(t)
	c, _ := s.client("")
	p := s.pane("printf '\033]2;dead title\007\033]7;file://localhost/tmp\007\033[?2026hretained'; exit 7")
	seenTitle, seenPwd := false, false
	for {
		_, data := read(t, c)
		var message map[string]json.RawMessage
		if json.Unmarshal(data, &message) != nil {
			t.Fatalf("event: %s", data)
		}
		if value := message["title"]; value != nil {
			seenTitle = string(value) == `"dead title"`
		}
		if value := message["pwd"]; value != nil {
			seenPwd = string(value) == `"file://localhost/tmp"`
		}
		if value := message["dead"]; value != nil {
			if !bytes.Contains(value, []byte(`"status":7`)) {
				t.Fatalf("dead: %s", value)
			}
			break
		}
	}
	if !seenTitle || !seenPwd {
		t.Fatalf("missing title or pwd event: %v %v", seenTitle, seenPwd)
	}
	v := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	data, _ := snapshot(t, v)
	terminal := decode(t, data)
	if terminal.Sync || !strings.Contains(terminal.Screen, "retained") {
		t.Fatalf("snapshot: %+v", terminal)
	}
	screen := s.request("GET", "/panes/"+p+"/screen?history=all", nil, 200, nil)
	if !strings.Contains(screen, "retained") {
		t.Fatalf("screen: %q", screen)
	}
	s.request("DELETE", "/panes/"+p, nil, 200, nil)
	s.request("GET", "/panes/"+p+"/screen", nil, 404, nil)
}
func TestViewResumeResizeAndInput(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("stty -echo -icanon min 1 time 0; printf '\033[?2004h\033[=3;1uREADY'; cat -v")
	c, _ := s.client(p)
	v := s.dialWS("/panes/"+p+"/view?history=all", nil, 101)
	data, offset := snapshot(t, v)
	if !strings.Contains(decode(t, data).Screen, "READY") {
		output(t, v, "READY")
	}
	send(t, v, map[string]any{"paste": map[string]any{"id": 23, "text": "hello\n", "check_safe": false}})
	reply := event(t, v, "paste")
	if !bytes.Contains(reply["paste"], []byte(`"pasted":true`)) {
		t.Fatalf("paste: %s", reply["paste"])
	}
	offset = output(t, v, "^[[201~")
	v.Close()
	v = s.dialWS(fmt.Sprintf("/panes/%s/view?history=all&offset=%d", p, offset), nil, 101)
	s.typeText(v, "resumed\n")
	var resumed string
	for !strings.Contains(resumed, "resumed") {
		kind, data := read(t, v)
		if kind != websocket.BinaryMessage || len(data) < 9 || data[0] != 1 {
			t.Fatalf("resume sent a snapshot or marker: %q", data)
		}
		resumed += string(data[9:])
	}
	send(t, c, map[string]any{"size": map[string]int{"cols": 60, "rows": 20, "cell_w_px": 8, "cell_h_px": 16}})
	marker := event(t, v, "marker")
	if !bytes.Contains(marker["marker"], []byte(`"cols":60`)) {
		t.Fatalf("marker: %s", marker["marker"])
	}
	send(t, v, map[string]any{"resync": map[string]any{"history": "none", "images": "none"}})
	data, _ = snapshot(t, v)
	if decode(t, data).Sync {
		t.Fatal("sync set")
	}
}
func TestKillServer(t *testing.T) {
	t.Parallel()
	s := start(t)
	s.pane("trap '' HUP; while :; do read x; done")
	cmd := exec.Command(filepath.Join(root, "_build/default/bin/ko.exe"), "kill-server", "--server", s.dir)
	if b, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("kill: %v %s", e, b)
	}
	s.stop()
}
func TestVersionAndOrigin(t *testing.T) {
	t.Parallel()
	s := start(t)
	vt := s.vt
	s.vt = "wrong"
	s.request("GET", "/panes", nil, 409, nil)
	req, _ := http.NewRequest("GET", "http://ko/panes", nil)
	req.Header.Set("Ko-Protocol", "2.0")
	r, e := s.http.Do(req)
	if e != nil {
		t.Fatal(e)
	}
	r.Body.Close()
	if r.StatusCode != 426 {
		t.Fatalf("version: %d", r.StatusCode)
	}
	h := s.headers()
	h.Set("Origin", "https://evil.example")
	h.Set("Ko-Vt", vt)
	s.dialWS("/client", h, 409)
}
