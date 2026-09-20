package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kido/internal/testutil"
)

// TestDeliverInboxHappy checks that the message arrives byte for byte,
// including newlines and non-ASCII, with no framing or trailing newline
// added, and that "ok" is taken as delivered.
func TestDeliverInboxHappy(t *testing.T) {
	for _, text := range []string{
		"hello there",
		"first line\nsecond line\n\nfourth",
		"héllo — π agents, ünicode ✳",
	} {
		in := testutil.StartInbox(t, "ok\n")
		if err := deliverInbox(in.Path, text); err != nil {
			t.Fatalf("deliverInbox(%q): %v", text, err)
		}
		msgs := in.Received()
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
	inboxTimeout = 300 * time.Millisecond

	in := testutil.StartInbox(t, "")
	start := time.Now()
	err := deliverInbox(in.Path, "hi")
	if err == nil {
		t.Fatal("deliverInbox: no error, want a deadline error")
	}
	if errors.Is(err, errInboxUnavailable) {
		t.Errorf("err = %v, want a hard error (the message was already written)", err)
	}
	// One deadline covers the whole exchange, connect included, so a peer
	// that never answers costs one timeout and not two. (A unix connect()
	// returns at once while the listen backlog has room, so this fixture
	// exercises the read half; the bound is what pins the contract.)
	if elapsed := time.Since(start); elapsed > inboxTimeout+inboxTimeout/2 {
		t.Errorf("took %v, want under %v: the one deadline must bound the whole exchange",
			elapsed, inboxTimeout+inboxTimeout/2)
	}
	if msgs := in.Received(); len(msgs) != 1 || msgs[0] != "hi" {
		t.Errorf("server got %q, want [\"hi\"]", msgs)
	}
}

// TestDeliverInboxBadReply checks that an answer other than "ok" is a hard
// error too, for the same reason.
func TestDeliverInboxBadReply(t *testing.T) {
	in := testutil.StartInbox(t, "nope\n")
	err := deliverInbox(in.Path, "hi")
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
		"missing": filepath.Join(testutil.SocketDir(t), "nothing-here.sock"),
		"stale":   testutil.StaleSocket(t),
		"toolong": "/tmp/" + strings.Repeat("x", 200) + ".sock",
	}
	for name, path := range cases {
		err := deliverInbox(path, "hi")
		if !errors.Is(err, errInboxUnavailable) {
			t.Errorf("%s: err = %v, want errInboxUnavailable", name, err)
		}
	}
}

// TestInboxPath checks the contract `kido inbox-path NAME` publishes: an
// absolute <state dir>/inbox/<name>.sock, with the inbox directory created
// private to the user.
func TestInboxPath(t *testing.T) {
	// SocketDir rather than t.TempDir(): the path gets a socket bound on
	// it below, and t.TempDir() embeds the test's name.
	dir := testutil.SocketDir(t)
	t.Setenv("KIDO_STATE_DIR", dir)

	got, err := inboxPath("pi-123")
	if err != nil {
		t.Fatalf("inboxPath: %v", err)
	}
	want := filepath.Join(dir, "inbox", "pi-123.sock")
	if got != want {
		t.Errorf("inboxPath = %q, want %q", got, want)
	}
	if !filepath.IsAbs(got) {
		t.Errorf("inboxPath = %q, want an absolute path", got)
	}
	fi, err := os.Stat(filepath.Join(dir, "inbox"))
	if err != nil {
		t.Fatalf("inbox directory: %v", err)
	}
	if !fi.IsDir() || fi.Mode().Perm() != 0o700 {
		t.Errorf("inbox directory mode = %v, want drwx------", fi.Mode())
	}
	// A socket really can be bound there: the whole point of the length
	// check is that the path kido hands out is one the kernel accepts.
	ln, err := net.Listen("unix", got)
	if err != nil {
		t.Fatalf("listen on %s: %v", got, err)
	}
	ln.Close()
}

// TestInboxPathTooLong checks that a path over sun_path's limit is an
// error with nothing usable returned, so the caller skips having an inbox
// rather than listening where kido cannot dial.
func TestInboxPathTooLong(t *testing.T) {
	deep := filepath.Join(os.TempDir(), "kido-"+strings.Repeat("deep", 30))
	t.Setenv("KIDO_STATE_DIR", deep)

	got, err := inboxPath("agent")
	if err == nil {
		t.Fatalf("inboxPath = %q, want an error for a path over %d bytes", got, sunPathMax)
	}
	if got != "" {
		t.Errorf("inboxPath = %q, want no path alongside the error", got)
	}
	if _, err := os.Stat(deep); err == nil {
		os.RemoveAll(deep)
		t.Error("a rejected name created the state directory; it must not")
	}
}

// TestInboxPathBadName checks that a name that could reach outside the
// inbox directory is rejected.
func TestInboxPathBadName(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	for _, name := range []string{"", "..", "../escape", "sub/agent", "a..b"} {
		if got, err := inboxPath(name); err == nil {
			t.Errorf("inboxPath(%q) = %q, want an error", name, got)
		}
	}
}
