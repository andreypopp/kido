package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
)

var (
	streamBatchInterval = msFromEnv("KIDO_STREAM_BATCH_MS", 250*time.Millisecond)
	streamBackoffFloor  = msFromEnv("KIDO_STREAM_BACKOFF_MS", 500*time.Millisecond)
	streamBackoffCap    = msFromEnv("KIDO_STREAM_BACKOFF_CAP_MS", 10*time.Second)
)

const (
	// A batch goes early once it has this much text, rather than waiting
	// out the interval.
	streamBatchBytes = 4 * 1024
	// The bounded buffer: what a parent that is slow or gone costs this
	// process. Past it the oldest lines go, so what survives is the tail,
	// for the same reason the completion notice carries one.
	streamPendingMax = 64 * 1024
	// What one run may put into a parent's context. Past it the stream
	// stops and says so, once; the count of everything it did not carry is
	// in the completion notice, so the model never believes it saw it all.
	streamRunBudget = 256 * 1024
)

// streamer is the writer the wrapper tees into. Write is called from the
// goroutine copying the command's output and never blocks on the parent:
// it takes a mutex, appends, and returns. A single sender goroutine does
// every send, so nothing is ever in flight twice and the completion notice
// can be ordered after the last chunk simply by closing first.
type streamer struct {
	meta subrun.Meta
	// The parent's inbox, resolved once and held: a stream makes thousands
	// of sends, so the resolution - a state directory read - happens once
	// rather than per chunk, and again only after a failure, which is the
	// one event that can mean the address has changed. Only the sender
	// goroutine and Close, after it has stopped, touch it.
	inbox string

	mu       sync.Mutex
	partial  []byte   // a line the command has not finished writing
	pending  []string // complete lines waiting for a send
	bytes    int      // pending's size, against streamPendingMax
	total    int      // lines the command has written
	sent     int      // lines a parent has acknowledged
	streamed int      // bytes a parent has acknowledged, against streamRunBudget
	overrun  bool     // the budget line has been sent; nothing follows it

	wake chan struct{}
	stop chan struct{}
	done chan struct{}
}

// newStreamer starts the sender goroutine for run meta. A parent that
// cannot be resolved is not an error here: every send simply fails, every
// line is counted as unstreamed, and the run carries on - the output file
// is the source of truth and the child must never wait on an LLM.
func newStreamer(meta subrun.Meta) *streamer {
	s := &streamer{
		meta: meta,
		wake: make(chan struct{}, 1),
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	go s.run()
	return s
}

func (s *streamer) Write(p []byte) (int, error) {
	s.mu.Lock()
	s.partial = append(s.partial, p...)
	for {
		i := bytes.IndexByte(s.partial, '\n')
		if i < 0 {
			break
		}
		s.push(s.partial[:i])
		s.partial = s.partial[i+1:]
	}
	// The bounded buffer, applied after the append so one enormous burst
	// leaves the newest lines rather than the oldest.
	for s.bytes > streamPendingMax && len(s.pending) > 0 {
		s.bytes -= len(s.pending[0]) + 1
		s.pending = s.pending[1:]
	}
	ready := s.bytes >= streamBatchBytes
	s.mu.Unlock()
	if ready {
		s.signal()
	}
	return len(p), nil
}

// push queues one complete line; s.mu is held.
func (s *streamer) push(line []byte) {
	l := sanitizeStreamLine(string(line))
	s.total++
	s.pending = append(s.pending, l)
	s.bytes += len(l) + 1
}

// signal asks the sender to take a batch now. Never blocks: the channel
// holds one pending wake, which is all "there is something to send" needs.
func (s *streamer) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// run is the sender: one batch at a time, at most one send in flight, and
// nothing at all while a failure's backoff is still running.
func (s *streamer) run() {
	defer close(s.done)
	ticker := time.NewTicker(streamBatchInterval)
	defer ticker.Stop()
	backoff := time.Duration(0)
	var retryAt time.Time
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
		case <-s.wake:
		}
		if !retryAt.IsZero() && time.Now().Before(retryAt) {
			continue
		}
		batch, lines, n := s.take()
		if batch == "" {
			continue
		}
		if err := s.send(batch); err != nil {
			// The batch is gone: it is not retried, and the lines in it are
			// counted for the completion notice. Retrying would deliver a
			// build's output out of date and out of order, and the file has
			// it all regardless.
			if backoff == 0 {
				backoff = streamBackoffFloor
			} else if backoff *= 2; backoff > streamBackoffCap {
				backoff = streamBackoffCap
			}
			retryAt = time.Now().Add(backoff)
			continue
		}
		backoff, retryAt = 0, time.Time{}
		s.credit(lines, n)
	}
}

// take removes the pending lines and returns them as one chunk, with the
// number of lines and bytes it is made of. Past the run's budget it returns
// the one line that says so, and after that nothing at all.
func (s *streamer) take() (text string, lines, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.pending) == 0 {
		return "", 0, 0
	}
	if s.streamed >= streamRunBudget {
		if s.overrun {
			return "", 0, 0
		}
		s.overrun = true
		s.pending, s.bytes = nil, 0
		return "... " + strconv.Itoa(streamRunBudget) + " bytes streamed for this run; the rest is only in " + subrun.OutputPath(s.meta.ID), 0, 0
	}
	text = strings.Join(s.pending, "\n")
	lines, n = len(s.pending), s.bytes
	s.pending, s.bytes = nil, 0
	return text, lines, n
}

// credit records what a parent acknowledged, which is the only thing that
// counts as streamed: a chunk the wire accepted but nobody answered for is
// a chunk the model may never see.
func (s *streamer) credit(lines, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sent += lines
	s.streamed += n
}

// Close stops the stream and returns how many of the command's lines the
// parent never acknowledged. It flushes what is left first - including a
// last line the command wrote without a newline - and waits for any send
// already in flight, so the completion notice its caller sends next is
// strictly after the final chunk.
func (s *streamer) Close() int {
	close(s.stop)
	<-s.done

	s.mu.Lock()
	if len(s.partial) > 0 {
		s.push(s.partial)
		s.partial = nil
	}
	s.mu.Unlock()

	if batch, lines, n := s.take(); batch != "" {
		if err := s.send(batch); err == nil {
			s.credit(lines, n)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.total - s.sent
}

// sanitizeStreamLine strips what build output is full of and a model can
// do nothing with: ANSI escape sequences and control bytes, tab excepted.
// The output file keeps the bytes as written; this is only what travels.
func sanitizeStreamLine(line string) string {
	var b strings.Builder
	for i := 0; i < len(line); {
		c := line[i]
		if c == 0x1b {
			i += escapeLen(line[i:])
			continue
		}
		if c < 0x20 && c != '\t' {
			i++
			continue
		}
		b.WriteByte(c)
		i++
	}
	return strings.TrimRight(b.String(), " \t\r")
}

// escapeLen is how many bytes of an escape sequence starting at s[0] to
// drop: a CSI or OSC sequence up to its terminator, else the escape and
// the one byte after it.
func escapeLen(s string) int {
	if len(s) < 2 {
		return len(s)
	}
	switch s[1] {
	case '[': // CSI: parameters, then one final byte in @-~
		for i := 2; i < len(s); i++ {
			if s[i] >= 0x40 && s[i] <= 0x7e {
				return i + 1
			}
		}
		return len(s)
	case ']': // OSC: up to BEL or ST, neither of which need be there
		for i := 2; i < len(s); i++ {
			if s[i] == 0x07 {
				return i + 1
			}
			if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '\\' {
				return i + 2
			}
		}
		return len(s)
	default:
		return 2
	}
}

// errNoStreamParent is every way a run has nobody to stream to: no parent
// edge at all (a `kido async_bash` typed at a human's shell), a parent
// whose record is gone, or one that never advertised an inbox to send a
// non-message kind to.
var errNoStreamParent = errors.New("no live parent listening for this run's output")

func (s *streamer) send(text string) error {
	if s.inbox == "" {
		// A non-message kind needs an inbox bound, since it can never fall back
		// to a paste; every way of having no parent is one error.
		if s.meta.ParentSession == "" {
			return errNoStreamParent
		}
		live, err := state.LoadLive()
		if err != nil {
			return err
		}
		parent, ok := state.Find(live, s.meta.ParentSession)
		if !ok || parent.Inbox == "" {
			return errNoStreamParent
		}
		s.inbox = parent.Inbox
	}
	raw, err := json.Marshal(msg.Envelope{
		V:      msg.V1,
		Kind:   msg.KindStream,
		ID:     msg.NewID(),
		From:   msg.From{Name: s.meta.Name},
		Text:   text,
		Run:    string(s.meta.ID),
		Output: subrun.OutputPath(s.meta.ID),
	})
	if err != nil {
		return err
	}
	if err := msg.Deliver(s.inbox, string(raw)); err != nil {
		s.inbox = "" // resolve again next time; this address answered for nothing
		return err
	}
	return nil
}
