package msg

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kido/internal/state"
)

// InboxTimeout bounds the whole exchange, from connect to reply. The
// agent answers as soon as it has read the message, so anything slower is
// a wedged peer, not a busy one. A variable so tests can shorten it.
var InboxTimeout = 2 * time.Second

// sunPathMax is the largest unix socket path the kernel accepts (104 bytes
// of sun_path on macOS, of which one is the terminator; Linux allows 108).
// Dialing a longer one fails anyway, but failing here keeps the reason
// legible and the behaviour the same on both platforms.
const sunPathMax = 103

// InboxPath is where an agent named name should put its inbox socket:
// <state dir>/inbox/<name>.sock, absolute, with the directory created. A
// name with a path separator or ".." is rejected, and a path too long for
// sun_path is an error rather than a truncated path, so the caller does
// without an inbox instead of listening where kido cannot dial.
func InboxPath(name string) (string, error) {
	switch {
	case name == "":
		return "", fmt.Errorf("empty name")
	case strings.ContainsRune(name, '/'), strings.ContainsRune(name, filepath.Separator):
		return "", fmt.Errorf("name %q contains a path separator", name)
	case strings.Contains(name, ".."):
		return "", fmt.Errorf("name %q contains %q", name, "..")
	}
	dir, err := filepath.Abs(state.Dir())
	if err != nil {
		return "", err
	}
	dir = filepath.Join(dir, "inbox")
	path := filepath.Join(dir, name+".sock")
	// Before anything is created, so a rejected name leaves nothing behind.
	if len(path) > sunPathMax {
		return "", fmt.Errorf("socket path is %d bytes, over the %d-byte limit: %s",
			len(path), sunPathMax, path)
	}
	// Only the inbox directory is private: anyone who can write into it
	// can impersonate an agent's socket.
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return path, nil
}

// ErrInboxUnavailable reports that nothing was sent: the socket path is
// empty or unusable, the file is missing, or it is a stale socket a dead
// process left behind. It is the only error a paste may fall back on;
// every failure after the connection is up is reported as itself, since
// the message may already have arrived.
var ErrInboxUnavailable = errors.New("no agent listening on the inbox")

// ErrAskRefused reports that an ask was read and deliberately declined,
// not merely undelivered, so it must never fall back to a paste either.
var ErrAskRefused = errors.New("ask refused: the target already has an ask outstanding to the asker")

// Deliver sends text to the agent listening on the unix socket at path
// and waits for its acknowledgement. A nil error means the agent has the
// message; test ErrInboxUnavailable with errors.Is.
func Deliver(path, text string) error {
	if path == "" {
		return fmt.Errorf("%w: no socket path", ErrInboxUnavailable)
	}
	if len(path) > sunPathMax {
		return fmt.Errorf("%w: socket path is %d bytes, over the %d-byte limit",
			ErrInboxUnavailable, len(path), sunPathMax)
	}
	// One deadline for the whole exchange, connect included: a listener
	// whose owner is wedged with a full accept backlog blocks in connect(),
	// before there is a connection to set a deadline on.
	deadline := time.Now().Add(InboxTimeout)
	d := net.Dialer{Deadline: deadline}
	c, err := d.Dial("unix", path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInboxUnavailable, err)
	}
	conn := c.(*net.UnixConn) // CloseWrite is the framing
	defer conn.Close()

	if err := conn.SetDeadline(deadline); err != nil {
		return fmt.Errorf("inbox %s: %w", path, err)
	}
	if _, err := io.WriteString(conn, text); err != nil {
		return fmt.Errorf("inbox %s: %w", path, err)
	}
	if err := conn.CloseWrite(); err != nil {
		return fmt.Errorf("inbox %s: %w", path, err)
	}
	reply, err := io.ReadAll(conn)
	if err != nil {
		return fmt.Errorf("inbox %s: %w", path, err)
	}
	switch got := strings.TrimSpace(string(reply)); got {
	case "ok":
		return nil
	case "refused":
		return fmt.Errorf("inbox %s: %w", path, ErrAskRefused)
	default:
		return fmt.Errorf("inbox %s: answered %q, want \"ok\"", path, got)
	}
}

// Send marshals env and delivers it to to's inbox. to.Inbox == "" is an
// error: an envelope kind has no v0 text fallback, and a caller wanting
// one goes through Deliver directly with its own choice of payload.
func Send(to state.Session, env Envelope) error {
	if to.Inbox == "" {
		return fmt.Errorf("%w: session %s has no inbox", ErrInboxUnavailable, to.ID)
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return err
	}
	return Deliver(to.Inbox, string(raw))
}

// Notify sends text as a "notice" envelope from from to the live agent
// holding parentSession. It is every ending's sender: cmd/kido has no
// business knowing the inbox wire, so a run's ending is reported through
// here rather than back through package main.
func Notify(parentSession string, from From, text string) error {
	live, err := state.LoadLive()
	if err != nil {
		return err
	}
	target, ok := state.Find(live, parentSession)
	if !ok {
		return fmt.Errorf("no live process holds session %q; the parent is gone, nothing sent", parentSession)
	}
	return Send(target, Envelope{V: V1, Kind: KindNotice, ID: NewID(), From: from, Text: text})
}
