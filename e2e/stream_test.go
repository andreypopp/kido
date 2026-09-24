package e2e

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"kido/internal/msg"
)

// TestAsyncBashStreamCoalescesAndEndsWithTheNotice is streaming end to
// end, and what it asserts is the shape of the traffic rather than any
// one envelope: twenty lines reach the parent as far fewer than twenty
// envelopes (coalescing, which is the whole reason a line is not an
// envelope - one queued message is one LLM turn under pi's default
// drain), every one of them before the single completion notice (the
// ordering the wire cannot give, since it has one connection per message
// and no sequencing), and that notice names the run and its exit status.
//
// The command's own idle duration (lines*writeEvery, about a second) is
// what the notice wait is scaled off, not the debounce-driven `settle`
// every other wait in this suite uses: a command already running close
// to that bound has no debounce to wait out, only a slow machine to
// finish on, and 5s was found to be too tight for that alone.
//
// The batch window is set far wider than writeEvery, and the envelope
// budget is judged against the number of windows the run actually
// spanned (elapsed/batch + 2, cmd/kido/async_stream_test.go's
// TestStreamCoalescesAndStripsAnsi): on a loaded runner a 50ms gap
// between lines can stretch well past a 100ms window, and a fixed
// count of envelopes then measures how far it stretched rather than
// whether the wrapper batches at all. It is set on this test's own
// inner server (like ZDOTDIR elsewhere in this suite), not in the
// shared harness config, because no other e2e test drives --stream.
//
// Watched over a span rather than sampled once, for the reason
// stableCount gives: one notice and the first of two are identical at any
// instant.
func TestAsyncBashStreamCoalescesAndEndsWithTheNotice(t *testing.T) {
	t.Parallel()
	const lines = 20
	const writeEvery = 50 * time.Millisecond
	const batch = 2 * time.Second
	const noticeWait = 20 * time.Second

	h := start(t, "alpha")
	h.in("set-environment", "-g", "KIDO_STREAM_BATCH_MS", strconv.FormatInt(batch.Milliseconds(), 10))
	in := h.asyncParent("alpha", "parent-stream-e2e")

	runStart := time.Now()
	h.asyncBashWith([]string{"--stream"}, "chatty",
		"sh", "-c", fmt.Sprintf("for i in $(seq 1 %d); do echo line $i; sleep %.3f; done; exit 2", lines, writeEvery.Seconds()))

	h.waitFor(func() bool { return lastNotice(h, in) != "" }, noticeWait,
		msgf("the parent's inbox to receive the run's completion notice"))
	elapsed := time.Since(runStart)
	// The notice is the wrapper's last act, but the chunks before it were
	// sent by the same process in the same order, so nothing can still be
	// in flight behind it.
	time.Sleep(300 * time.Millisecond)

	var chunks, notices int
	var notice msg.Envelope
	for i, raw := range in.Received() {
		env, ok := msg.Parse([]byte(raw))
		if !ok {
			t.Fatalf("envelope %d is not v1: %q", i, raw)
		}
		switch env.Kind {
		case msg.KindStream:
			chunks++
			if notices > 0 {
				t.Errorf("envelope %d is a chunk after the completion notice; the notice must be last", i)
			}
		case msg.KindNotice:
			notices, notice = notices+1, env
		default:
			t.Errorf("envelope %d is a %q, want only chunks and one notice", i, env.Kind)
		}
	}
	if chunks == 0 {
		t.Fatalf("no output was streamed at all; the inbox holds %d envelopes", len(in.Received()))
	}
	// A batching wrapper can send at most one chunk per window the run
	// spanned, plus the one its close flushes. A wrapper sending one
	// envelope per line sends all of them however long the run took.
	want := int(elapsed/batch) + 2
	if chunks > want {
		t.Errorf("%d lines arrived as %d envelopes over %v, want at most %d: a chunk is a %v window's worth of output, not a line", lines, chunks, elapsed, want, batch)
	}
	if notices != 1 {
		t.Errorf("parent received %d completion notices, want exactly 1", notices)
	}
	t.Logf("%d lines arrived as %d stream envelopes, then one notice", lines, chunks)
	if notice.From.Name != "chatty" || !strings.Contains(notice.Text, "exit status 2") {
		t.Errorf("notice = %+v, want it to name chatty and exit status 2", notice)
	}
}

// lastNotice is the text of the completion notice in in, or "" while
// there is none.
func lastNotice(h *harness, in interface{ Received() []string }) string {
	h.t.Helper()
	for _, raw := range in.Received() {
		if env, ok := msg.Parse([]byte(raw)); ok && env.Kind == msg.KindNotice {
			return env.Text
		}
	}
	return ""
}
