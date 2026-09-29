package msg

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

// TestDeliverHappy checks that the message arrives byte for byte,
// including newlines and non-ASCII, with no framing or trailing newline
// added, and that "ok" is taken as delivered.
func TestDeliverHappy(t *testing.T) {
	for _, text := range []string{
		"hello there",
		"first line\nsecond line\n\nfourth",
		"héllo — π agents, ünicode ✳",
	} {
		in := testutil.StartInbox(t, "ok\n")
		if err := Deliver(in.Path, text); err != nil {
			t.Fatalf("Deliver(%q): %v", text, err)
		}
		msgs := in.Received()
		if len(msgs) != 1 || msgs[0] != text {
			t.Errorf("server got %q, want exactly [%q]", msgs, text)
		}
	}
}

// TestDeliverNoReply checks that a server that accepts and then says
// nothing is a plain error, not ErrInboxUnavailable: the message did go
// out, so the caller must not send it again with send-keys.
func TestDeliverNoReply(t *testing.T) {
	defer func(d time.Duration) { InboxTimeout = d }(InboxTimeout)
	InboxTimeout = 300 * time.Millisecond

	in := testutil.StartInbox(t, "")
	start := time.Now()
	err := Deliver(in.Path, "hi")
	if err == nil {
		t.Fatal("Deliver: no error, want a deadline error")
	}
	if errors.Is(err, ErrInboxUnavailable) {
		t.Errorf("err = %v, want a hard error (the message was already written)", err)
	}
	// One deadline covers the whole exchange, connect included, so a peer
	// that never answers costs one timeout and not two. (A unix connect()
	// returns at once while the listen backlog has room, so this fixture
	// exercises the read half; the bound is what pins the contract.)
	if elapsed := time.Since(start); elapsed > InboxTimeout+InboxTimeout/2 {
		t.Errorf("took %v, want under %v: the one deadline must bound the whole exchange",
			elapsed, InboxTimeout+InboxTimeout/2)
	}
	if msgs := in.Received(); len(msgs) != 1 || msgs[0] != "hi" {
		t.Errorf("server got %q, want [\"hi\"]", msgs)
	}
}

// TestDeliverBadReply checks that an answer other than "ok" is a hard
// error too, for the same reason.
func TestDeliverBadReply(t *testing.T) {
	in := testutil.StartInbox(t, "nope\n")
	err := Deliver(in.Path, "hi")
	if err == nil || errors.Is(err, ErrInboxUnavailable) {
		t.Errorf("err = %v, want a hard error", err)
	}
}

// TestDeliverRefused checks that a "refused" reply is reported as
// ErrAskRefused, distinct from both "ok" and a generic bad reply, and
// that it is not ErrInboxUnavailable - the send-keys fallback must never
// fire on a deliberate refusal.
func TestDeliverRefused(t *testing.T) {
	in := testutil.StartInbox(t, "refused\n")
	err := Deliver(in.Path, "hi")
	if !errors.Is(err, ErrAskRefused) {
		t.Fatalf("err = %v, want ErrAskRefused", err)
	}
	if errors.Is(err, ErrInboxUnavailable) {
		t.Errorf("err = %v, want not ErrInboxUnavailable: a refusal must never trigger the paste fallback", err)
	}
}

// TestDeliverUnavailable checks the cases that mean nothing was
// delivered and send-keys is still open: no path at all, a path that does
// not exist, a stale socket a dead agent left behind, and a path too long
// for sun_path.
func TestDeliverUnavailable(t *testing.T) {
	cases := map[string]string{
		"empty":   "",
		"missing": filepath.Join(testutil.SocketDir(t), "nothing-here.sock"),
		"stale":   testutil.StaleSocket(t),
		"toolong": "/tmp/" + strings.Repeat("x", 200) + ".sock",
	}
	for name, path := range cases {
		err := Deliver(path, "hi")
		if !errors.Is(err, ErrInboxUnavailable) {
			t.Errorf("%s: err = %v, want ErrInboxUnavailable", name, err)
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

	got, err := InboxPath("pi-123")
	if err != nil {
		t.Fatalf("InboxPath: %v", err)
	}
	want := filepath.Join(dir, "inbox", "pi-123.sock")
	if got != want {
		t.Errorf("InboxPath = %q, want %q", got, want)
	}
	if !filepath.IsAbs(got) {
		t.Errorf("InboxPath = %q, want an absolute path", got)
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

	got, err := InboxPath("agent")
	if err == nil {
		t.Fatalf("InboxPath = %q, want an error for a path over %d bytes", got, sunPathMax)
	}
	if got != "" {
		t.Errorf("InboxPath = %q, want no path alongside the error", got)
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
		if got, err := InboxPath(name); err == nil {
			t.Errorf("InboxPath(%q) = %q, want an error", name, got)
		}
	}
}
