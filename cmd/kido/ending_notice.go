package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"kido/internal/msg"
	"kido/internal/reap"
	"kido/internal/subrun"
)

// maxNoticeTailBytes is how much of a run's output the completion notice
// carries. The tail, not the head: what a failure has to say, it says
// last.
const maxNoticeTailBytes = 4000

// endingNotice is one run's ending as its parent is told it.
//
// For a bash run, three observers can be the one to send it - the run's
// own wrapper (async_run.go), a sweep that found the window already gone
// (internal/reap, through reapCmd and internal/ui) and `kido
// stop_subagent`; for an agent run, the sweep and the child's own
// shutdown (`kido run-outcome --unreported`). Which of them speaks is
// settled by subrun.RecordOutcome's O_EXCL write, never here. One shape
// for all of them, because a parent must not be able to tell how its run
// ended by which process happened to notice.
type endingNotice struct {
	runID         string
	name          string
	parentSession string
	// kind is the run's kind, the zero value read as an agent run exactly
	// as subrun.Meta.EffectiveKind reads an absent one.
	kind   subrun.Kind
	result subrun.Result
	text   string
	// unstreamed is how many of the run's output lines never reached the
	// parent while it ran (--stream only; zero for every other sender and
	// every other observer of an ending). Reported because a model that
	// watched output arrive would otherwise have no way to know it was
	// watching part of it.
	unstreamed int
}

// noticeFor is the notice for a run a sweep has just recorded the ending
// of.
func noticeFor(n reap.Notice) endingNotice {
	return endingNotice{
		runID:         n.Meta.ID,
		name:          n.Meta.Name,
		parentSession: n.Meta.ParentSession,
		kind:          n.Meta.EffectiveKind(),
		result:        n.Outcome.Result,
		text:          n.Outcome.Text,
	}
}

// runLabel names a run wherever one is spoken about - in a notice, as
// the notice's sender, in what `kido stop_subagent` prints and refuses.
// A run nobody named is its own id, which is at least addressable.
func runLabel(name, id string) string {
	if name == "" {
		return id
	}
	return name
}

func (n endingNotice) label() string { return runLabel(n.name, n.runID) }

// send delivers n to the run's parent, as a notice envelope over its
// inbox. cmd names the calling subcommand, for whatever send prints to
// stderr; the outcome is already on disk by the time this runs, so a
// failure here costs the notice and nothing else.
//
// A run nobody started has nobody to tell - a `kido async_bash` typed at
// a human's shell has no parent session at all - and notify_parent's own
// refusal would only print to a pane that is about to close.
func (n endingNotice) send(cmd string) {
	if n.parentSession == "" {
		return
	}
	send(cmd, sendSpec{ //nolint:errcheck // prints its own error; the outcome is already recorded
		kind:          msg.KindNotice,
		parentSession: n.parentSession,
		fromName:      n.label(),
	}, strings.NewReader(n.body()))
}

// body is the notice text: what ended, how, and the last of what it
// said.
func (n endingNotice) body() string {
	if n.kind != subrun.KindBash {
		return n.agentBody()
	}
	var b strings.Builder
	fmt.Fprintf(&b, "async run %q %s: %s\n", n.label(), n.result, n.text)
	fmt.Fprintf(&b, "run: %s\n", n.runID)
	fmt.Fprintf(&b, "output: %s\n", subrun.OutputPath(n.runID))
	if n.unstreamed > 0 {
		fmt.Fprintf(&b, "%d lines not streamed (the output file above has every one)\n", n.unstreamed)
	}
	tail, omitted, err := tailOfFile(subrun.OutputPath(n.runID), maxNoticeTailBytes)
	switch {
	case err != nil:
		fmt.Fprintf(&b, "--- output unreadable: %v ---", err)
	case tail == "":
		fmt.Fprint(&b, "--- no output ---")
	case omitted > 0:
		fmt.Fprintf(&b, "--- last %d bytes of output (%d omitted) ---\n%s", len(tail), omitted, tail)
	default:
		fmt.Fprintf(&b, "--- output ---\n%s", tail)
	}
	return b.String()
}

// agentBody is the notice for a subagent run that ended without its
// child ever calling notify_parent. It claims nothing about the work:
// the first line is the only verdict there is - the run ended and
// nobody spoke for it - and the rest is what a parent needs to do
// something about that, the run id and the session to pick up where it
// stopped.
func (n endingNotice) agentBody() string {
	var b strings.Builder
	fmt.Fprintf(&b, "subagent %q %s without reporting: it never called notify_parent, so this is the whole account of it\n", n.label(), n.result)
	if n.text != "" {
		fmt.Fprintf(&b, "detail: %s\n", n.text)
	}
	fmt.Fprintf(&b, "run: %s\n", n.runID)
	fmt.Fprintf(&b, "resume: spawn_subagent(resume: %q)\n", n.runID)
	return b.String()
}

// trimPartialRune drops a partial UTF-8 rune from the cut edge of b: the
// front when the bytes before it were dropped (fromFront true), the back
// when the bytes after it were (fromFront false). Walking forward off a
// cut always lands on a lead byte or the end; walking backward can leave
// a lead byte whose continuation bytes were cut away, which needs the
// extra check the forward direction does not.
func trimPartialRune(b []byte, fromFront bool) []byte {
	if fromFront {
		for len(b) > 0 && b[0]&0xC0 == 0x80 {
			b = b[1:]
		}
		return b
	}
	for len(b) > 0 && b[len(b)-1]&0xC0 == 0x80 {
		b = b[:len(b)-1]
	}
	if len(b) > 0 && b[len(b)-1]&0xC0 == 0xC0 {
		b = b[:len(b)-1]
	}
	return b
}

// tailOfFile returns the last max bytes of path and how many bytes were
// dropped from the front of it. The cut is moved forward off a partial
// UTF-8 rune and anything still invalid is replaced, because a notice
// that is not valid UTF-8 is refused by the send path outright - and a
// build log ending mid-character is an ordinary way for that to happen.
func tailOfFile(path string, max int64) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	var omitted int64
	if fi.Size() > max {
		omitted = fi.Size() - max
		if _, err := f.Seek(omitted, io.SeekStart); err != nil {
			return "", 0, err
		}
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return "", 0, err
	}
	if omitted > 0 {
		before := len(b)
		b = trimPartialRune(b, true)
		omitted += int64(before - len(b))
	}
	return strings.ToValidUTF8(string(b), "\uFFFD"), omitted, nil
}
