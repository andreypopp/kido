package e2e

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// socketDir is a temp directory short enough to hold a unix socket path:
// t.TempDir() embeds the test's name under /var/folders/... on macOS,
// which can push sun_path past its 104-byte limit.
func socketDir(t testing.TB) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "kido-inbox")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// inbox is a fake agent inbox, standing in for the socket pi's kido
// extension listens on: it accepts one connection at a time, reads it to
// EOF (the client's half-close is the end of one prompt), answers as
// reply says, and records what arrived.
type inbox struct {
	Path string
	mu   sync.Mutex
	msgs []string
}

// startInbox listens on a fresh unix socket and serves it until the test
// ends. reply is what the server answers each prompt with; "" means never
// answer at all, leaving the client on its deadline.
func startInbox(t testing.TB, reply string) *inbox {
	t.Helper()
	in := &inbox{Path: filepath.Join(socketDir(t), "inbox.sock")}
	ln, err := net.Listen("unix", in.Path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			b, _ := io.ReadAll(conn)
			in.mu.Lock()
			in.msgs = append(in.msgs, string(b))
			in.mu.Unlock()
			if reply == "" {
				time.AfterFunc(10*time.Second, func() { conn.Close() })
				continue
			}
			io.WriteString(conn, reply) //nolint:errcheck // best effort
			conn.Close()
		}
	}()
	return in
}

func (in *inbox) Received() []string {
	in.mu.Lock()
	defer in.mu.Unlock()
	return append([]string(nil), in.msgs...)
}

// staleSocket is a socket file whose listener is gone, the way a dead
// agent leaves one behind: connecting gets ECONNREFUSED, not ENOENT.
func staleSocket(t testing.TB) string {
	t.Helper()
	path := filepath.Join(socketDir(t), "stale.sock")
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	ln.SetUnlinkOnClose(false)
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("stale socket vanished: %v", err)
	}
	return path
}

// envelope is the inbox protocol's v1 message, as far as the suite reads it.
type envelope struct {
	Kind string `json:"kind"`
	From struct {
		Name string `json:"name"`
	} `json:"from"`
	Text string `json:"text"`
}

// parseEnvelope reports whether raw is a v1 envelope: a JSON object
// carrying both "v" and "kind"; anything else is a v0 raw prompt.
func parseEnvelope(raw string) (envelope, bool) {
	var probe map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &probe) != nil || probe["v"] == nil || probe["kind"] == nil {
		return envelope{}, false
	}
	var env envelope
	if json.Unmarshal([]byte(raw), &env) != nil {
		return envelope{}, false
	}
	return env, true
}

var lookModernBash = sync.OnceValues(func() (bash, skip string) {
	path, err := exec.LookPath("bash")
	if err != nil {
		return "", "no bash in PATH"
	}
	if exec.Command(path, "-c",
		`((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))`).Run() != nil {
		return "", "the bash in PATH is older than 4.4, which PS0 needs"
	}
	return path, ""
})

// modernBash returns a bash new enough for the PS0 hook
// share/bash/integration.bash is built on, and skips the test when this
// host has none - macOS ships 3.2 as its own /bin/bash.
func modernBash(t testing.TB) string {
	t.Helper()
	bash, skip := lookModernBash()
	if skip != "" {
		t.Skip(skip)
	}
	return bash
}

func TestGetInboxCmd(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	dir := filepath.Join(socketDir(t), "state")
	out := h.runScript("alpha", "get-inbox.out", fmt.Sprintf("KIDO_STATE_DIR=%s %s get-inbox 123", shellQuote(dir), kidoBin))
	var value map[string]string
	if err := json.Unmarshal([]byte(firstLine(out)), &value); err != nil {
		t.Fatalf("get-inbox: %s: %v", out, err)
	}
	want := filepath.Join(dir, "inbox", "123.sock")
	if len(value) != 1 || value["path"] != want {
		t.Errorf("get-inbox = %v, want path %s", value, want)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("get-inbox created state directory: %v", err)
	}
}
