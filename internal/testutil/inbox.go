// Package testutil holds test scaffolding shared by more than one of
// kido's test packages. It is a normal package rather than a _test file
// so both cmd/kido and e2e can import it; nothing outside tests uses it.
package testutil

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// SocketDir is a temp directory short enough to hold a unix socket path:
// t.TempDir() embeds the test's name under /var/folders/... on macOS,
// which can push sun_path past its 104-byte limit.
func SocketDir(t testing.TB) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "kido-inbox")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// Inbox is a fake agent inbox, standing in for the socket pi's kido
// extension listens on: it accepts one connection at a time, reads it to
// EOF (the client's half-close is the end of one prompt), answers as
// reply says, and records what arrived.
type Inbox struct {
	Path string
	mu   sync.Mutex
	msgs []string
}

// StartInbox listens on a fresh unix socket and serves it until the test
// ends. reply is what the server answers each prompt with; "" means never
// answer at all, leaving the client on its deadline.
func StartInbox(t testing.TB, reply string) *Inbox {
	t.Helper()
	in := &Inbox{Path: filepath.Join(SocketDir(t), "inbox.sock")}
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
				// Hold the connection open with nothing to read, so
				// the client hits its deadline rather than EOF.
				time.AfterFunc(10*time.Second, func() { conn.Close() })
				continue
			}
			io.WriteString(conn, reply) //nolint:errcheck // best effort
			conn.Close()
		}
	}()
	return in
}

// Received is the prompts delivered over the socket so far.
func (in *Inbox) Received() []string {
	in.mu.Lock()
	defer in.mu.Unlock()
	return append([]string(nil), in.msgs...)
}

// StaleSocket is a socket file whose listener is gone, the way a dead
// agent leaves one behind: connecting gets ECONNREFUSED, not ENOENT.
func StaleSocket(t testing.TB) string {
	t.Helper()
	path := filepath.Join(SocketDir(t), "stale.sock")
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	ln.SetUnlinkOnClose(false) // leave the file behind, as a crash would
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("stale socket vanished: %v", err)
	}
	return path
}
