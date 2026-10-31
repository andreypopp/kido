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

	"kido/internal/e2eenv"

	"github.com/gorilla/websocket"
)

var root, koBin string

func TestMain(m *testing.M) {
	var err error
	root, err = filepath.Abs("..")
	if err != nil {
		panic(err)
	}
	koBin = filepath.Join(root, "_build/install/default/bin/ko")
	if err := e2eenv.UnsetHooks(); err != nil {
		fmt.Fprintln(os.Stderr, "e2e setup:", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "dune", "build", "@install", "ko_vt/decode.exe")
	cmd.Dir = root
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		os.Exit(1)
	}
	home, err := e2eenv.Private()
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2e setup:", err)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

type server struct {
	t      *testing.T
	dir    string
	cmd    *exec.Cmd
	http   *http.Client
	vt     string
	limits json.RawMessage
	log    bytes.Buffer
	wait   chan error
	once   sync.Once
}

func testEnv(dir string) []string {
	var env []string
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if name == "TERM_PROGRAM" || name == "TERM_PROGRAM_VERSION" || name == "HOME" || strings.HasPrefix(name, "XDG_") || strings.HasPrefix(name, "KO_") || strings.HasPrefix(name, "KIDO_") || strings.HasPrefix(name, "TMUX") || strings.HasPrefix(name, "BASH_FUNC_") || name == "ZDOTDIR" || name == "ENV" || name == "BASH_ENV" {
			continue
		}
		env = append(env, entry)
	}
	return append(env, "HOME="+dir, "XDG_CONFIG_HOME="+dir, "XDG_STATE_HOME="+dir, "TERM_PROGRAM=Apple_Terminal", "TERM_PROGRAM_VERSION=999")
}
func start(t *testing.T, args ...string) *server {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "ko-")
	if err != nil {
		t.Fatal(err)
	}
	s := &server{t: t, dir: dir, wait: make(chan error, 1)}
	s.cmd = exec.Command(koBin, append([]string{"server", "--server", dir, "--shell", "/bin/sh"}, args...)...)
	s.cmd.Env = testEnv(dir)
	s.cmd.Stdout = &s.log
	s.cmd.Stderr = &s.log
	if err = s.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { s.wait <- s.cmd.Wait() }()
	s.http = &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DialContext: s.dial}}
	t.Cleanup(func() {
		s.stop()
		if t.Failed() {
			t.Logf("server log: %s", s.log.String())
		}
		s.http.CloseIdleConnections()
		os.RemoveAll(dir)
	})
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
	send(s.t, v, []any{"input", []any{"text", base64.StdEncoding.EncodeToString([]byte(text))}})
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
func tagged(b []byte) (string, json.RawMessage) {
	var m []json.RawMessage
	var tag string
	if json.Unmarshal(b, &m) != nil || len(m) != 2 || json.Unmarshal(m[0], &tag) != nil {
		return "", nil
	}
	return tag, m[1]
}
func event(t *testing.T, c *websocket.Conn, key string) json.RawMessage {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	for i := 0; i < 10000; i++ {
		_, b := read(t, c)
		if tag, payload := tagged(b); tag == key {
			return payload
		}
	}
	t.Fatalf("no %s", key)
	return nil
}

var size = map[string]any{"cols": 80, "rows": 24, "cell_px": map[string]int{"width": 8, "height": 16}}

func (s *server) client(pane string) (*websocket.Conn, string) {
	c := s.dialWS("/client", nil, 101)
	h := map[string]any{"kind": "terminal", "name": "test", "focused": true, "size": size}
	if pane != "" {
		h["pane"] = pane
	}
	send(s.t, c, []any{"hello", h})
	var identity struct {
		Client string
		Limits json.RawMessage
	}
	for _, key := range []string{"welcome", "topology"} {
		_, data := read(s.t, c)
		tag, payload := tagged(data)
		if tag != key {
			s.t.Fatalf("expected %s, got %s", key, data)
		}
		if key == "welcome" {
			if e := json.Unmarshal(payload, &identity); e != nil {
				s.t.Fatal(e)
			}
		}
	}
	s.limits = identity.Limits
	return c, identity.Client
}
func (s *server) pane(command string) string {
	var response struct {
		Pane string `json:"pane"`
	}
	s.request("POST", "/panes", map[string]any{"command": []any{"argv", []string{"/bin/sh", "-c", command}}, "cwd": "/tmp"}, 200, &response)
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
		tag, value := tagged(data)
		switch tag {
		case "title":
			seenTitle = bytes.Contains(value, []byte(`"title":"dead title"`))
		case "pwd":
			seenPwd = bytes.Contains(value, []byte(`"pwd":"file://localhost/tmp"`))
		case "dead":
			if !bytes.Contains(value, []byte(`"cause":["exited",7]`)) {
				t.Fatalf("dead: %s", value)
			}
		default:
			if tag == "" {
				t.Fatalf("event: %s", data)
			}
		}
		if tag == "dead" {
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
	send(t, v, []any{"input", []any{"paste", map[string]any{"id": 23, "text": "hello\n", "check_safe": false}}})
	reply := event(t, v, "pasted")
	if !bytes.Contains(reply, []byte(`"pasted":true`)) {
		t.Fatalf("paste: %s", reply)
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
	send(t, c, []any{"size", map[string]any{"cols": 60, "rows": 20, "cell_px": map[string]int{"width": 8, "height": 16}}})
	marker := event(t, v, "marked")
	if !bytes.Contains(marker, []byte(`"cols":60`)) {
		t.Fatalf("marker: %s", marker)
	}
	send(t, v, []any{"resync", map[string]any{"history": "none", "images": "none"}})
	data, _ = snapshot(t, v)
	if decode(t, data).Sync {
		t.Fatal("sync set")
	}
}
func TestKillServer(t *testing.T) {
	t.Parallel()
	s := start(t)
	p := s.pane("trap '' HUP; printf READY; while read x; do :; done")
	v := s.dialWS("/panes/"+p+"/view", nil, 101)
	s.ready(v, "READY")
	var panes []struct {
		PID int `json:"pid"`
	}
	s.request("GET", "/panes", nil, 200, &panes)
	if len(panes) != 1 || panes[0].PID <= 0 {
		t.Fatalf("program pid: %+v", panes)
	}
	t.Cleanup(func() { syscall.Kill(panes[0].PID, syscall.SIGKILL) })
	cmd := exec.Command(koBin, "kill-server", "--server", s.dir)
	if b, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("kill: %v %s", e, b)
	}
	if _, e := os.Stat(s.dir + "/socket"); !os.IsNotExist(e) {
		t.Fatalf("socket after kill-server: %v", e)
	}
	waitGone(t, panes[0].PID, "kill-server")
	s.stop()
}
func TestKillServerSignalsByPeerPID(t *testing.T) {
	t.Parallel()
	dir, err := os.MkdirTemp("/tmp", "ko-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := dir + "/socket"
	script := `import os,signal,socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen()
def stop(*a):
    os.unlink(sys.argv[1])
    os._exit(0)
signal.signal(signal.SIGTERM,stop)
held=[]
while True:
    held.append(s.accept()[0])
`
	cmd := exec.Command("python3", "-I", "-c", script, socket)
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { cmd.Wait(); close(exited) }()
	t.Cleanup(func() { cmd.Process.Kill(); <-exited })
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		if c, e := net.Dial("unix", socket); e == nil {
			c.Close()
			break
		}
		select {
		case <-deadline.C:
			t.Fatal("stand-in server never listened")
		case <-tick.C:
		}
	}
	if b, e := exec.Command(koBin, "kill-server", "--server", dir).CombinedOutput(); e != nil {
		t.Fatalf("kill: %v %s", e, b)
	}
	select {
	case <-exited:
	default:
		t.Fatal("stand-in server survived kill-server")
	}
	if _, e := os.Stat(socket); !os.IsNotExist(e) {
		t.Fatalf("socket after kill-server: %v", e)
	}
}
func TestVersionAndOrigin(t *testing.T) {
	t.Parallel()
	s := start(t)
	s.client("")
	var limits struct{ Scrollback [2]json.RawMessage }
	if err := json.Unmarshal(s.limits, &limits); err != nil {
		t.Fatal(err)
	}
	if string(limits.Scrollback[0]) != `"scrollback"` || string(limits.Scrollback[1]) != `{"max_bytes":50000000}` {
		t.Fatalf("default scrollback limits: %s", s.limits)
	}
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

func TestApi(t *testing.T) {
	t.Parallel()
	s := start(t)
	ko := func(dir, stdin string, args ...string) (string, string, int) {
		cmd := exec.Command(koBin, append([]string{"api", "--server", dir}, args...)...)
		cmd.Env = testEnv(dir)
		cmd.Stdin = strings.NewReader(stdin)
		var out, errs bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errs
		err := cmd.Run()
		code := 0
		if exit, ok := err.(*exec.ExitError); ok {
			code = exit.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		return out.String(), errs.String(), code
	}
	var version struct{ Protocol string }
	if out, _, code := ko(s.dir, "", "/version"); code != 0 || json.Unmarshal([]byte(out), &version) != nil || version.Protocol == "" {
		t.Fatalf("/version: %d %q", code, out)
	}
	if out, _, code := ko(s.dir, "", "-i", "/version"); code != 0 || !strings.HasPrefix(out, "HTTP/1.1 200 OK\r\n") {
		t.Fatalf("--include: %d %q", code, out)
	}
	var created struct{ Pane string }
	if out, _, code := ko(s.dir, `{"command":["shell","exec cat"]}`, "--input", "-", "/panes"); code != 0 || json.Unmarshal([]byte(out), &created) != nil || created.Pane == "" {
		t.Fatalf("POST via stdin: %d %q", code, out)
	}
	file := filepath.Join(s.dir, "body.json")
	if err := os.WriteFile(file, []byte(`{"command":["shell","exec cat"]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, code := ko(s.dir, "", "-X", "POST", "--input", file, "/panes"); code != 0 {
		t.Fatalf("POST via file: %d", code)
	}
	var rows []struct{ ID string }
	if out, _, code := ko(s.dir, "", "/panes"); code != 0 || json.Unmarshal([]byte(out), &rows) != nil || len(rows) != 2 || rows[0].ID != created.Pane {
		t.Fatalf("/panes: %d %q", code, out)
	}
	if out, errs, code := ko(s.dir, "", "/nope"); code != 1 || errs != "ko api: HTTP 404\n" || !strings.Contains(out, "not_found") {
		t.Fatalf("404: %d %q %q", code, out, errs)
	}
	for _, path := range []string{"/client", "/panes/" + created.Pane + "/view?history=all"} {
		if out, errs, code := ko(s.dir, "", path); code != 2 || out != "" || !strings.Contains(errs, "is a WebSocket endpoint") {
			t.Fatalf("%s: %d %q %q", path, code, out, errs)
		}
	}
	empty, err := os.MkdirTemp("/tmp", "ko-api-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(empty)
	for _, dir := range []string{empty, filepath.Join(empty, "absent")} {
		if out, errs, code := ko(dir, "", "/version"); code != 1 || out != "" || errs != "ko api: no server at "+dir+"\n" {
			t.Fatalf("no server: %d %q %q", code, out, errs)
		}
	}
	if entries, _ := os.ReadDir(empty); len(entries) != 0 {
		t.Fatalf("ko api created %v", entries)
	}
}
