package main

import (
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

// This file is the client side of the inbox protocol (docs/design.md,
// "The inbox"): one message per connection, written whole, half-closed,
// answered with "ok\n" or "refused\n".

// inboxTimeout bounds the whole exchange, from connect to reply. The
// agent answers as soon as it has read the message, so anything slower is
// a wedged peer, not a busy one. A variable so tests can shorten it.
var inboxTimeout = 2 * time.Second

// sunPathMax is the largest unix socket path the kernel accepts (104 bytes
// of sun_path on macOS, of which one is the terminator; Linux allows 108).
// Dialing a longer one fails anyway, but failing here keeps the reason
// legible and the behaviour the same on both platforms.
const sunPathMax = 103

// inboxPath is where an agent named name should put its inbox socket:
// <state dir>/inbox/<name>.sock, absolute, with the directory created. A
// name with a path separator or ".." is rejected, and a path too long for
// sun_path is an error rather than a truncated path, so the caller does
// without an inbox instead of listening where kido cannot dial.
func inboxPath(name string) (string, error) {
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

// errInboxUnavailable reports that nothing was sent: the socket path is
// empty or unusable, the file is missing, or it is a stale socket a dead
// process left behind. It is the only error a paste may fall back on;
// every failure after the connection is up is reported as itself, since
// the message may already have arrived.
var errInboxUnavailable = errors.New("no agent listening on the inbox")

// errAskRefused reports that an ask was read and deliberately declined,
// not merely undelivered, so it must never fall back to a paste either.
var errAskRefused = errors.New("ask refused: the target already has an ask outstanding to the asker")

// deliverInbox sends text to the agent listening on the unix socket at
// path and waits for its acknowledgement. A nil error means the agent has
// the message; test errInboxUnavailable with errors.Is.
func deliverInbox(path, text string) error {
	if path == "" {
		return fmt.Errorf("%w: no socket path", errInboxUnavailable)
	}
	if len(path) > sunPathMax {
		return fmt.Errorf("%w: socket path is %d bytes, over the %d-byte limit",
			errInboxUnavailable, len(path), sunPathMax)
	}
	// One deadline for the whole exchange, connect included: a listener
	// whose owner is wedged with a full accept backlog blocks in connect(),
	// before there is a connection to set a deadline on.
	deadline := time.Now().Add(inboxTimeout)
	d := net.Dialer{Deadline: deadline}
	c, err := d.Dial("unix", path)
	if err != nil {
		return fmt.Errorf("%w: %v", errInboxUnavailable, err)
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
		return fmt.Errorf("inbox %s: %w", path, errAskRefused)
	default:
		return fmt.Errorf("inbox %s: answered %q, want \"ok\"", path, got)
	}
}
