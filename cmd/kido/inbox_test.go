package main

import (
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// socketDir is a temp directory short enough to hold a unix socket:
// t.TempDir() embeds the test's name under /var/folders/... on macOS,
// which can push sun_path past its 104-byte limit.
func socketDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "kido-inbox")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// inboxServer is a fake agent inbox: it accepts one connection at a time,
// reads the whole message (the client's half-close is the end of it),
// answers as reply says, and records what arrived. reply "" means never
// answer at all, leaving the client on its deadline.
func inboxServer(t *testing.T, reply string) (path string, got func() []string) {
	t.Helper()
	path = filepath.Join(socketDir(t), "inbox.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })

	var mu sync.Mutex
	var msgs []string
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			b, _ := io.ReadAll(conn)
			mu.Lock()
			msgs = append(msgs, string(b))
			mu.Unlock()
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
	return path, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), msgs...)
	}
}

// staleSocket is a socket file whose listener is gone, the way a dead
// agent leaves one behind: connecting gets ECONNREFUSED, not ENOENT.
func staleSocket(t *testing.T) string {
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

// TestDeliverInboxHappy checks that the message arrives byte for byte,
// including newlines and non-ASCII, with no framing or trailing newline
// added, and that "ok" is taken as delivered.
func TestDeliverInboxHappy(t *testing.T) {
	for _, text := range []string{
		"hello there",
		"first line\nsecond line\n\nfourth",
		"héllo — π agents, ünicode ✳",
	} {
		path, got := inboxServer(t, "ok\n")
		if err := deliverInbox(path, text); err != nil {
			t.Fatalf("deliverInbox(%q): %v", text, err)
		}
		msgs := got()
		if len(msgs) != 1 || msgs[0] != text {
			t.Errorf("server got %q, want exactly [%q]", msgs, text)
		}
	}
}

// TestDeliverInboxNoReply checks that a server that accepts and then says
// nothing is a plain error, not errInboxUnavailable: the message did go
// out, so the caller must not send it again with send-keys.
func TestDeliverInboxNoReply(t *testing.T) {
	defer func(d time.Duration) { inboxTimeout = d }(inboxTimeout)
	inboxTimeout = 150 * time.Millisecond

	path, got := inboxServer(t, "")
	start := time.Now()
	err := deliverInbox(path, "hi")
	if err == nil {
		t.Fatal("deliverInbox: no error, want a deadline error")
	}
	if errors.Is(err, errInboxUnavailable) {
		t.Errorf("err = %v, want a hard error (the message was already written)", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Errorf("took %v; the deadline did not bound the read", elapsed)
	}
	if msgs := got(); len(msgs) != 1 || msgs[0] != "hi" {
		t.Errorf("server got %q, want [\"hi\"]", msgs)
	}
}

// TestDeliverInboxBadReply checks that an answer other than "ok" is a hard
// error too, for the same reason.
func TestDeliverInboxBadReply(t *testing.T) {
	path, _ := inboxServer(t, "nope\n")
	err := deliverInbox(path, "hi")
	if err == nil || errors.Is(err, errInboxUnavailable) {
		t.Errorf("err = %v, want a hard error", err)
	}
}

// TestDeliverInboxUnavailable checks the cases that mean nothing was
// delivered and send-keys is still open: no path at all, a path that does
// not exist, a stale socket a dead agent left behind, and a path too long
// for sun_path.
func TestDeliverInboxUnavailable(t *testing.T) {
	cases := map[string]string{
		"empty":   "",
		"missing": filepath.Join(socketDir(t), "nothing-here.sock"),
		"stale":   staleSocket(t),
		"toolong": "/tmp/" + strings.Repeat("x", 200) + ".sock",
	}
	for name, path := range cases {
		err := deliverInbox(path, "hi")
		if !errors.Is(err, errInboxUnavailable) {
			t.Errorf("%s: err = %v, want errInboxUnavailable", name, err)
		}
	}
}
