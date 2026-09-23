package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
)

// The streaming half of `kido async-run --stream`: the wrapper's tee gains
// a third writer that batches the command's output lines and sends them to
// the run's parent as "stream" envelopes. The rules it implements - why a
// batch is safe where a line is not, what is dropped and what is counted -
// are in docs/design-subagents.md, "Streaming a run's output".

// The batch interval and the two backoff figures are knobs for the e2e
// suite, which drives kido as a separately built binary and can only reach
// it through the environment (docs/design.md, "Knobs").
var (
	streamBatchInterval = streamDurationFromEnv("KIDO_STREAM_BATCH_MS", 250*time.Millisecond)
	streamBackoffFloor  = streamDurationFromEnv("KIDO_STREAM_BACKOFF_MS", 500*time.Millisecond)
	streamBackoffCap    = streamDurationFromEnv("KIDO_STREAM_BACKOFF_CAP_MS", 10*time.Second)
)

func streamDurationFromEnv(name string, def time.Duration) time.Duration {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n > 0 {
		return time.Duration(n) * time.Millisecond
	}
	return def
}

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
	runID  string
	name   string
	output string
	sender *streamSender

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

// newStreamer starts the sender goroutine for run runID. A parent that
// cannot be resolved is not an error here: every send simply fails, every
// line is counted as unstreamed, and the run carries on - the output file
// is the source of truth and the child must never wait on an LLM.
func newStreamer(runID, name, parentInstance string) *streamer {
	s := &streamer{
		runID:  runID,
		name:   name,
		output: subrun.OutputPath(runID),
		sender: &streamSender{parentInstance: parentInstance, name: name, runID: runID,
			output: subrun.OutputPath(runID)},
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
		line := sanitizeStreamLine(string(s.partial[:i]))
		s.partial = s.partial[i+1:]
		s.total++
		s.pending = append(s.pending, line)
		s.bytes += len(line) + 1
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
		if err := s.sender.send(batch); err != nil {
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
		return "... " + strconv.Itoa(streamRunBudget) + " bytes streamed for this run; the rest is only in " + s.output, 0, 0
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
// strictly after the final chunk (docs/design-subagents.md).
func (s *streamer) Close() int {
	close(s.stop)
	<-s.done

	s.mu.Lock()
	if len(s.partial) > 0 {
		line := sanitizeStreamLine(string(s.partial))
		s.partial = nil
		s.total++
		s.pending = append(s.pending, line)
		s.bytes += len(line) + 1
	}
	s.mu.Unlock()

	if batch, lines, n := s.take(); batch != "" {
		if err := s.sender.send(batch); err == nil {
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

// streamSender is the wire half: the parent's inbox, resolved once and
// held. A send is one connection with its own deadline, exactly as every
// other envelope is; what is different is that a stream makes thousands of
// them, so the resolution - a state directory read and a tmux pane listing
// in send() (message_agent.go) - happens once rather than per chunk, and
// again only after a failure, which is the one event that can mean the
// address has changed.
type streamSender struct {
	parentInstance string
	name           string
	runID          string
	output         string
	inbox          string
}

func (s *streamSender) send(text string) error {
	if s.inbox == "" {
		inbox, err := resolveParentInbox(s.parentInstance)
		if err != nil {
			return err
		}
		s.inbox = inbox
	}
	raw, err := json.Marshal(msg.Envelope{
		V:      msg.V1,
		Kind:   msg.KindStream,
		ID:     msg.NewID(),
		From:   msg.From{Name: s.name},
		Text:   text,
		Run:    s.runID,
		Output: s.output,
	})
	if err != nil {
		return err
	}
	if err := deliverInbox(s.inbox, string(raw)); err != nil {
		s.inbox = "" // resolve again next time; this address answered for nothing
		return err
	}
	return nil
}

// resolveParentInbox finds the inbox of the live agent reporting instance,
// the same registry scan `kido notify_parent` resolves its target through.
// A parent that has not advertised the v1 protocol has nowhere for a
// non-message kind to land, which is send()'s own rule.
func resolveParentInbox(instance string) (string, error) {
	if instance == "" {
		return "", errNoStreamParent
	}
	live, err := state.LoadLive()
	if err != nil {
		return "", err
	}
	for _, s := range live {
		if s.Instance != instance {
			continue
		}
		if s.Inbox == "" || s.Protocol < msg.V1 {
			return "", errNoStreamParent
		}
		return s.Inbox, nil
	}
	return "", errNoStreamParent
}
