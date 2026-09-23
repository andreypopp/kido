package e2e

import (
	"strings"
	"testing"
	"time"

	"kido/internal/msg"
)

// TestAsyncBashStreamCoalescesAndEndsWithTheNotice is streaming end to
// end, and what it asserts is the shape of the traffic rather than any
// one envelope: fifty lines written over two and a half seconds reach the
// parent as far fewer than fifty envelopes (coalescing, which is the
// whole reason a line is not an envelope - one queued message is one LLM
// turn under pi's default drain), every one of them before the single
// completion notice (the ordering the wire cannot give, since it has one
// connection per message and no sequencing), and that notice names the
// run and its exit status.
//
// Watched over a span rather than sampled once, for the reason
// stableCount gives: one notice and the first of two are identical at any
// instant.
func TestAsyncBashStreamCoalescesAndEndsWithTheNotice(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-stream-e2e")

	h.asyncBashWith([]string{"--stream"}, "chatty",
		"sh", "-c", "for i in $(seq 1 50); do echo line $i; sleep 0.05; done; exit 2")

	h.waitFor(func() bool { return lastNotice(h, in) != "" }, settle,
		msgf("the parent's inbox to receive the run's completion notice"))
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
	if chunks >= 50 {
		t.Errorf("50 lines arrived as %d envelopes, want them coalesced into far fewer", chunks)
	}
	if notices != 1 {
		t.Errorf("parent received %d completion notices, want exactly 1", notices)
	}
	t.Logf("50 lines arrived as %d stream envelopes, then one notice", chunks)
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
