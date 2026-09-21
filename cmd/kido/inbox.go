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

// An agent that can take a prompt as a real user message (pi, through its
// kido extension) listens on a unix stream socket and reports its path
// with `kido agent-status --inbox PATH`. This is the client side of that
// protocol:
//
//   - one prompt per connection: connect, write the prompt as UTF-8 with
//     no trailing newline and no framing, then half-close the write half
//     so the reader sees EOF as the end of the message;
//   - the agent answers "ok\n" and closes.

// inboxTimeout bounds the whole exchange, from write to reply. The agent
// answers as soon as it has read the message, so anything slower than this
// is a wedged peer, not a busy one. A variable so tests can shorten it.
var inboxTimeout = 2 * time.Second

// sunPathMax is the largest unix socket path the kernel accepts (104 bytes
// of sun_path on macOS, of which one is the terminator; Linux allows 108).
// Dialing a longer one fails anyway, but failing here keeps the reason
// legible and the behaviour the same on both platforms.
const sunPathMax = 103

// inboxPath is where an agent named name should put its inbox socket:
// <state dir>/inbox/<name>.sock, absolute, with the directory created. It
// backs `kido inbox-path <name>` so an agent's extension does not have to
// reimplement state.Dir()'s precedence or guess kido's sun_path budget -
// the same reason `kido debug-log` exists.
//
// A name with a path separator or a ".." in it is rejected: the name goes
// straight into a file name, and an extension passing its session id has
// no business reaching outside the inbox directory. A path too long for
// sun_path is an error rather than a truncated path, so the caller can
// simply do without an inbox instead of listening where kido cannot dial.
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
	// Checked before anything is created, so a rejected name leaves no
	// directory behind.
	if len(path) > sunPathMax {
		return "", fmt.Errorf("socket path is %d bytes, over the %d-byte limit: %s",
			len(path), sunPathMax, path)
	}
	// The state directory keeps the mode its other writers use
	// (state.Record, logHookEvent); only the inbox directory is private,
	// since anyone who can write into it can impersonate an agent's
	// socket. state.Load ignores directories, so this one is invisible to
	// it.
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return path, nil
}

// errInboxUnavailable reports that no agent is listening on the inbox, so
// nothing was delivered and the caller may safely fall back to send-keys:
// the socket path is empty or unusable, the file is missing, or it is a
// stale socket a dead process left behind. Every failure from the moment
// the connection is up is reported as itself instead, because the message
// may already have arrived and a fallback would send it twice.
var errInboxUnavailable = errors.New("no agent listening on the inbox")

// deliverInbox sends text to the agent listening on the unix socket at
// path and waits for its acknowledgement. A nil error means the agent has
// the message. errInboxUnavailable (test with errors.Is) means the message
// was never sent and send-keys is still open; any other error means the
// exchange broke down after the connection was up, and the prompt must not
// be sent again.
func deliverInbox(path, text string) error {
	if path == "" {
		return fmt.Errorf("%w: no socket path", errInboxUnavailable)
	}
	if len(path) > sunPathMax {
		return fmt.Errorf("%w: socket path is %d bytes, over the %d-byte limit",
			errInboxUnavailable, len(path), sunPathMax)
	}
	// One deadline for the whole exchange, connect included: it bounds the
	// dial (a listener whose owner is wedged with a full accept backlog
	// would otherwise block in connect(), before there is a connection to
	// set a deadline on) and then the write and the read, so a peer that is
	// slow to accept and slow to answer still costs one inboxTimeout in
	// total rather than one per phase.
	deadline := time.Now().Add(inboxTimeout)
	d := net.Dialer{Deadline: deadline}
	c, err := d.Dial("unix", path)
	if err != nil {
		return fmt.Errorf("%w: %v", errInboxUnavailable, err)
	}
	conn := c.(*net.UnixConn) // a unix dial always yields one, and CloseWrite is the framing
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
	if got := strings.TrimSpace(string(reply)); got != "ok" {
		return fmt.Errorf("inbox %s: answered %q, want \"ok\"", path, got)
	}
	return nil
}
