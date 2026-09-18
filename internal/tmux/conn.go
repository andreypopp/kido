package tmux

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// A Conn is one long-lived tmux control-mode client ("tmux -C
// attach-session"): commands are written to its stdin and their output read
// back, instead of forking a tmux process per query. It also reports the
// server's notifications, so the sidebar can refresh the moment tmux
// changes rather than on the next tick.
//
// The connection is supervised: if the client dies (the attached session
// was killed, the server restarted) it is re-dialled with backoff, and
// every query made while it is down fails with ErrNotConnected so the
// caller can fall back to running tmux directly.
type Conn struct {
	client string        // side client, re-queried for the session to attach to
	notify chan struct{} // coalesced "something changed" signals, cap 1
	raw    chan struct{} // notifications straight off the wire
	done   chan struct{} // closed by Close

	once sync.Once

	mu  sync.Mutex // serializes Run: replies come back in order
	cur struct {
		sync.Mutex
		c *child
	}

	// followed is the session this connection's control client is attached
	// to, as far as Follow knows: set by dial (which attaches to the side
	// client's session directly) and by a successful Follow. It makes
	// Follow a no-op when nothing changed, so a call every tick costs
	// nothing once the two clients agree.
	followed struct {
		sync.Mutex
		session string
	}
}

// ErrNotConnected is returned by Conn methods while the control client is
// down; the caller should fall back to a plain tmux exec.
var ErrNotConnected = errors.New("tmux: control connection is down")

const (
	// debounce is how long notifications are coalesced: a width drag or a
	// new window emits a burst of them.
	debounce = 50 * time.Millisecond
	// runTimeout bounds one command. tmux answers in microseconds; a
	// timeout means the stream is out of step, so the client is killed and
	// re-dialled rather than left to answer the wrong question.
	runTimeout = 2 * time.Second
	minBackoff = 100 * time.Millisecond
	maxBackoff = 2 * time.Second
)

// Connect starts a supervised control client for the side client's session.
// It returns immediately: the first dial happens in the background and
// queries fail with ErrNotConnected until it lands.
func Connect(client string) *Conn {
	c := &Conn{
		client: client,
		notify: make(chan struct{}, 1),
		raw:    make(chan struct{}, 1),
		done:   make(chan struct{}),
	}
	go c.supervise()
	go c.coalesce()
	return c
}

// Notify receives a value whenever tmux reported a change. Signals are
// coalesced and dropped when one is already pending, so a reader that is
// busy never falls behind.
func (c *Conn) Notify() <-chan struct{} { return c.notify }

// Close stops the control client. The child also exits on its own if kido
// dies without calling this: kido holds the only write end of its stdin, so
// the pipe closes and the control client reads EOF.
func (c *Conn) Close() {
	c.once.Do(func() {
		close(c.done)
		if ch := c.child(); ch != nil {
			ch.kill()
		}
	})
}

// Run sends one tmux command and returns the lines of its output block.
// A %error block becomes an error.
func (c *Conn) Run(cmd string) ([]string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	ch := c.child()
	if ch == nil {
		return nil, ErrNotConnected
	}
	// Drop anything left over from an abandoned command.
	for {
		select {
		case <-ch.replies:
			continue
		default:
		}
		break
	}
	if _, err := io.WriteString(ch.stdin, cmd+"\n"); err != nil {
		ch.kill()
		return nil, ErrNotConnected
	}
	timer := time.NewTimer(runTimeout)
	defer timer.Stop()
	select {
	case b := <-ch.replies:
		return b.lines, b.err
	case <-ch.dead:
		return nil, ErrNotConnected
	case <-c.done:
		return nil, ErrNotConnected
	case <-timer.C:
		ch.kill() // the stream is out of step; start over
		return nil, fmt.Errorf("tmux -C %s: timed out", cmd)
	}
}

// ListPanes is ListPanes over the connection.
func (c *Conn) ListPanes() ([]Pane, error) {
	lines, err := c.Run("list-panes -a -F " + quote(paneFormat))
	if err != nil {
		return nil, err
	}
	return parsePanes(lines), nil
}

// ClientState is ClientState over the connection.
func (c *Conn) ClientState(client string) (session string, focused bool, err error) {
	lines, err := c.Run("list-clients -F " + quote(clientFormat))
	if err != nil {
		return "", false, err
	}
	if len(lines) == 0 {
		return "", false, errors.New("tmux: no clients")
	}
	session, focused = parseClientState(lines, client)
	return session, focused, nil
}

// Follow makes the control client switch to session, so that the
// %layout-change, %window-pane-changed and %session-window-changed
// notifications for windows in it - only sent to a control client for the
// session it is itself attached to - reach this connection. It is a no-op
// once the control client is already there, so it is cheap enough to call
// on every tick; an error (the session no longer exists) is left for the
// next call to retry. switch-client with -t only moves the targeted
// client, so this never disturbs the user's own client.
func (c *Conn) Follow(session string) error {
	c.followed.Lock()
	same := c.followed.session == session
	c.followed.Unlock()
	if same {
		return nil
	}
	if _, err := c.Run("switch-client -t " + quote(session)); err != nil {
		return err
	}
	c.setFollowed(session)
	return nil
}

func (c *Conn) setFollowed(session string) {
	c.followed.Lock()
	c.followed.session = session
	c.followed.Unlock()
}

// quote wraps an argument for tmux's own command parser, which splits on
// whitespace and treats "#" as a comment outside quotes. Inside single
// quotes everything is literal, so an embedded quote is closed, escaped and
// reopened as in the shell.
func quote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// ---- the child process -----------------------------------------------------

type child struct {
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	replies chan block
	dead    chan struct{} // closed when the client is gone
	once    sync.Once
}

func (ch *child) kill() {
	ch.once.Do(func() {
		ch.stdin.Close() // makes the control client exit on its own
		if ch.cmd.Process != nil {
			ch.cmd.Process.Kill()
		}
	})
}

func (c *Conn) child() *child {
	c.cur.Lock()
	defer c.cur.Unlock()
	return c.cur.c
}

func (c *Conn) setChild(ch *child) {
	c.cur.Lock()
	defer c.cur.Unlock()
	c.cur.c = ch
}

// supervise keeps one control client running until Close.
func (c *Conn) supervise() {
	backoff := minBackoff
	for {
		select {
		case <-c.done:
			return
		default:
		}
		ch, err := c.dial()
		if err == nil {
			backoff = minBackoff
			c.setChild(ch)
			c.signal() // the sidebar may have missed changes while down
			select {
			case <-ch.dead:
			case <-c.done:
			}
			c.setChild(nil)
			ch.kill()
		}
		select {
		case <-c.done:
			return
		case <-time.After(backoff):
		}
		if backoff *= 2; backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

// dial starts a control client attached to the side client's session and
// waits for the attach command's own output block, which proves the stream
// is up. The session is re-queried every time: after a session is killed
// the old name is gone, and the client has moved elsewhere.
func (c *Conn) dial() (*child, error) {
	args := []string{"-C", "attach-session", "-f", "no-output,ignore-size"}
	// no-output keeps tmux from streaming every pane's bytes at us;
	// ignore-size keeps this sizeless client out of window sizing.
	session, _ := ClientState(c.client)
	if session != "" {
		args = append(args, "-t", session)
	}
	cmd := exec.Command(binary(), args...)
	cmd.WaitDelay = time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdin.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		stdin.Close()
		return nil, err
	}
	ch := &child{cmd: cmd, stdin: stdin, replies: make(chan block, 4), dead: make(chan struct{})}
	go func() {
		parse(stdout, func(b block) {
			select {
			case ch.replies <- b:
			default: // nobody is waiting: an abandoned command's reply
			}
		}, func(name string) {
			if name == "%exit" {
				ch.kill()
				return
			}
			if notifications[name] {
				c.signal()
			}
		})
		ch.kill()
		cmd.Wait()
		close(ch.dead)
	}()

	// attach-session answers with a block of its own (empty, or the error
	// of an attach that found no session); wait for it, so a failed attach
	// is reported here and Run never picks the block up.
	timer := time.NewTimer(runTimeout)
	defer timer.Stop()
	select {
	case b := <-ch.replies:
		if b.err != nil {
			ch.kill()
			return nil, b.err
		}
		c.setFollowed(session) // matches Follow's no-op check; avoids a redundant switch right after connecting
		return ch, nil
	case <-ch.dead:
		return nil, errors.New("tmux -C: client exited before attaching")
	case <-c.done:
		ch.kill()
		return nil, errors.New("closed")
	case <-timer.C:
		ch.kill()
		return nil, errors.New("tmux -C: timed out attaching")
	}
}

// ---- notifications ---------------------------------------------------------

// notifications are the control-mode notifications (control-notify.c) that
// change what the sidebar draws. Everything else - %output, paste buffer
// changes, subscriptions - is ignored.
var notifications = map[string]bool{
	"%window-add":              true,
	"%window-close":            true,
	"%window-renamed":          true,
	"%unlinked-window-add":     true,
	"%unlinked-window-close":   true,
	"%unlinked-window-renamed": true,
	"%sessions-changed":        true,
	"%session-changed":         true,
	"%session-renamed":         true,
	"%session-window-changed":  true,
	"%client-session-changed":  true,
	"%client-detached":         true,
	"%layout-change":           true,
	"%window-pane-changed":     true,
	"%pane-mode-changed":       true,
}

// signal marks that something changed, without ever blocking the reader.
func (c *Conn) signal() {
	select {
	case c.raw <- struct{}{}:
	default:
	}
}

// coalesce turns bursts of notifications into one signal per debounce
// window: a width drag or a new window emits several at once.
func (c *Conn) coalesce() {
	for {
		select {
		case <-c.done:
			return
		case <-c.raw:
		}
		timer := time.NewTimer(debounce)
		for waiting := true; waiting; {
			select {
			case <-c.done:
				timer.Stop()
				return
			case <-c.raw: // swallowed: the pending signal covers it
			case <-timer.C:
				waiting = false
			}
		}
		select {
		case c.notify <- struct{}{}:
		default: // a signal is already pending
		}
	}
}

// ---- the control-mode stream -----------------------------------------------

// block is one command's output: the lines between %begin and %end, or the
// error text of a %error.
type block struct {
	lines []string
	err   error
}

// parse reads a control-mode stream and calls onBlock for each command's
// output and onNotify with the name of each notification line. Parsing is
// block-aware: inside a %begin/%end block every line is data, "%0<tab>zsh"
// included, and only lines outside a block are notifications.
func parse(r io.Reader, onBlock func(block), onNotify func(name string)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024) // a pane title can be long
	var (
		lines []string
		id    string // "<time> <number>" of the open block, "" when none
	)
	for sc.Scan() {
		line := strings.TrimSuffix(sc.Text(), "\r")
		if id == "" {
			if rest, ok := strings.CutPrefix(line, "%begin "); ok {
				id, lines = guardID(rest), nil
				continue
			}
			if strings.HasPrefix(line, "%") {
				name, _, _ := strings.Cut(line, " ")
				onNotify(name)
			}
			continue
		}
		// Only a guard line carrying this block's time and number closes
		// it; command output that happens to look like one does not.
		if rest, ok := strings.CutPrefix(line, "%end "); ok && guardID(rest) == id {
			onBlock(block{lines: lines})
			id, lines = "", nil
			continue
		}
		if rest, ok := strings.CutPrefix(line, "%error "); ok && guardID(rest) == id {
			onBlock(block{lines: lines, err: errors.New(strings.Join(lines, "; "))})
			id, lines = "", nil
			continue
		}
		lines = append(lines, line)
	}
}

// guardID is the time and number of a guard line ("%begin <time> <number>
// <flags>"); the flags differ between a block's %begin and its %end.
func guardID(rest string) string {
	f := strings.Fields(rest)
	if len(f) < 2 {
		return rest
	}
	return f[0] + " " + f[1]
}
