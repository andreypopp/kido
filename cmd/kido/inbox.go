package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
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
//
// Delivering this way beats send-keys because the agent receives a
// well-formed user message rather than keystrokes, and can decide for
// itself what to do when one arrives mid-turn.
//
// A prompt that never reaches an inbox falls back to send-keys, but only
// when the failure proves nothing was delivered: see errInboxUnavailable.

// inboxTimeout bounds the whole exchange, from write to reply. The agent
// answers as soon as it has read the message, so anything slower than this
// is a wedged peer, not a busy one. A variable so tests can shorten it.
var inboxTimeout = 2 * time.Second

// sunPathMax is the largest unix socket path the kernel accepts (104 bytes
// of sun_path on macOS, of which one is the terminator; Linux allows 108).
// Dialing a longer one fails anyway, but failing here keeps the reason
// legible and the behaviour the same on both platforms.
const sunPathMax = 103

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
	// The dial is bounded too: a listener whose owner is wedged with a
	// full accept backlog would otherwise block in connect(), before
	// there is a connection to set a deadline on.
	d := net.Dialer{Timeout: inboxTimeout}
	c, err := d.Dial("unix", path)
	if err != nil {
		return fmt.Errorf("%w: %v", errInboxUnavailable, err)
	}
	conn := c.(*net.UnixConn) // a unix dial always yields one, and CloseWrite is the framing
	defer conn.Close()

	// One deadline for the whole exchange; it is set before the first byte
	// goes out, so a peer that accepts and then wedges cannot hang kido.
	if err := conn.SetDeadline(time.Now().Add(inboxTimeout)); err != nil {
		return fmt.Errorf("inbox %s: %w", path, err)
	}
	if _, err := io.WriteString(conn, text); err != nil {
		return fmt.Errorf("inbox %s: %w", path, err)
	}
	// The half-close is the framing: it is what tells the agent the
	// message is complete.
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
