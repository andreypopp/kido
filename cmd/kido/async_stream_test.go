package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// withStreamKnobs shortens the wrapper's batching and backoff for a test,
// the way the e2e suite shortens them through the environment.
func withStreamKnobs(t *testing.T, batch, floor, ceiling time.Duration) {
	t.Helper()
	savedBatch, savedFloor, savedCap := streamBatchInterval, streamBackoffFloor, streamBackoffCap
	streamBatchInterval, streamBackoffFloor, streamBackoffCap = batch, floor, ceiling
	t.Cleanup(func() {
		streamBatchInterval, streamBackoffFloor, streamBackoffCap = savedBatch, savedFloor, savedCap
	})
}

// withInboxTimeout shortens the wire's own deadline, which is what a
// stalled parent costs a sender.
func withInboxTimeout(t *testing.T, d time.Duration) {
	t.Helper()
	saved := inboxTimeout
	inboxTimeout = d
	t.Cleanup(func() { inboxTimeout = saved })
}

// streamParent is noticeParent with a chosen reply: "ok\n" for a parent
// that answers, "" for one that accepts the connection and never does,
// which is the only failure that can actually make a sender wait.
func streamParent(t *testing.T, instance, reply string) *testutil.Inbox {
	t.Helper()
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	in := testutil.StartInbox(t, reply)
	if err := state.Record("parent", state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: 1, Status: state.Idle, Title: "orchestrator",
		Instance: instance, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}
	return in
}

// streamText is every stream envelope's text, in arrival order.
func streamText(t *testing.T, envs []msg.Envelope) []string {
	t.Helper()
	var out []string
	for _, e := range envs {
		if e.Kind == msg.KindStream {
			out = append(out, e.Text)
		}
	}
	return out
}

// TestStreamNeverPastes: a stream envelope is a build's output, and the
// one place it must never arrive is a shell that reclaimed a dead agent's
// pane, where every line of it would be a command line. The rule is
// send()'s existing one - a non-message kind never pastes - and this is
// the assertion that it covers the new kind. The assertion that carries
// the test is the last one: the pane was not typed into. A refusal that
// returned an error and pasted anyway satisfies every other one.
func TestStreamNeverPastes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	if err := state.Record("target", state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Title: "victim", Inbox: testutil.StaleSocket(t), Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	var code int
	stderr := captureStderr(t, func() {
		code = send("async-run", sendSpec{kind: msg.KindStream, to: "victim"}, strings.NewReader("line 1\nline 2"))
	})
	if code != 1 {
		t.Fatalf("send = %d, want 1: there is nothing listening", code)
	}
	if !strings.Contains(stderr, "cannot fall back to a paste") {
		t.Errorf("stderr = %q, want it to say a stream cannot be pasted", stderr)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Errorf("sendPrompt calls = %v, want none: a build's output must never be typed into a pane", calls)
	}
}

// TestStreamCoalescesAndStripsAnsi is the feature in one run: lines
// written one at a time, the way a build writes them, arrive as a handful
// of envelopes rather than one each - which is the whole reason a line is
// not an envelope, since pi drains one queued message per poll and each
// one is an LLM turn - and the escape sequences build output is full of
// are gone from what travels, while the output file keeps them.
//
// The lines are written *slowly* on purpose: written in one burst they
// would be coalesced by the pipe alone, and a wrapper sending one
// envelope per line would pass.
//
// The batch window is set far wider than that spacing, and the count is
// judged against the number of windows the run actually spanned, so the
// assertion reads the wrapper's batching rather than the machine's
// speed: on a loaded runner the gaps between lines stretch, and a fixed
// count of envelopes is a measure of how far they stretched.
func TestStreamCoalescesAndStripsAnsi(t *testing.T) {
	const lines = 20
	const writeEvery = 30 * time.Millisecond
	const batch = 2 * time.Second

	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := streamParent(t, "root-inst", "ok\n")
	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "root-inst")
	withStreamKnobs(t, batch, 20*time.Millisecond, 100*time.Millisecond)

	script := fmt.Sprintf(`for i in $(seq 1 %d); do printf '\033[32mline %%s\033[0m\n' $i; sleep %.3f; done`, lines, writeEvery.Seconds())
	id := startAsyncRun(t, "sh", "-c", script)
	start := time.Now()
	captureStdout(t, func() { asyncRunCmd([]string{"--run-id", id, "--name", "chatty", "--stream"}) })
	elapsed := time.Since(start)

	chunks := streamText(t, envelopes(t, in))
	if len(chunks) == 0 {
		t.Fatalf("no stream envelopes arrived at all")
	}
	// A batching wrapper can send at most one chunk per window the run
	// spanned, plus the one its close flushes. A wrapper sending one
	// envelope per line sends all of them however long the run took.
	want := int(elapsed/batch) + 2
	if len(chunks) > want {
		t.Errorf("%d lines written %v apart arrived as %d envelopes over %v, want at most %d: a chunk is a %v window's worth of output, not a line",
			lines, writeEvery, len(chunks), elapsed, want, batch)
	}
	joined := strings.Join(chunks, "\n")
	if strings.ContainsRune(joined, 0x1b) {
		t.Errorf("streamed text carries an escape byte: %q", joined)
	}
	for _, want := range []string{"line 1", fmt.Sprintf("line %d", lines)} {
		if !strings.Contains(joined, want) {
			t.Errorf("streamed text = %q, want it to carry %q", joined, want)
		}
	}
	b, err := os.ReadFile(subrun.OutputPath(id))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.ContainsRune(string(b), 0x1b) {
		t.Errorf("output file = %q, want the command's own bytes, escapes and all", b)
	}
}

// TestCompletionNoticeFollowsTheFinalChunk pins the ordering rule the
// wire cannot: one connection per message and no sequencing, so "the run
// ended" arriving before the output it is the ending of is a parent told
// a build finished and then handed its middle. The wrapper sends nothing
// concurrently and closes the stream before it speaks, which is what this
// reads back.
func TestCompletionNoticeFollowsTheFinalChunk(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := streamParent(t, "root-inst", "ok\n")
	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "root-inst")
	// A batch interval longer than the whole run, so the only chunk there
	// is comes from the close - which is exactly the chunk the ordering
	// rule is about, and the one a wrapper that spoke before closing
	// would put after its own notice. The last line has no newline for
	// the same reason: it can only be flushed by the close.
	withStreamKnobs(t, 5*time.Second, 20*time.Millisecond, 100*time.Millisecond)

	id := startAsyncRun(t, "sh", "-c", `printf 'line 1\nline 2\nline 3\nline 4 unterminated'; exit 2`)
	captureStdout(t, func() { asyncRunCmd([]string{"--run-id", id, "--name", "chatty", "--stream"}) })

	got := envelopes(t, in)
	if len(got) < 2 {
		t.Fatalf("parent received %d envelopes, want at least one chunk and one notice: %+v", len(got), got)
	}
	for i, e := range got[:len(got)-1] {
		if e.Kind != msg.KindStream {
			t.Errorf("envelope %d is a %q, want every envelope before the last to be a chunk", i, e.Kind)
		}
	}
	last := got[len(got)-1]
	if last.Kind != msg.KindNotice {
		t.Fatalf("last envelope is a %q, want the completion notice", last.Kind)
	}
	if !strings.Contains(last.Text, "exit status 2") || last.From.Name != "chatty" {
		t.Errorf("notice = %+v, want it to name the run and its exit status", last)
	}
	// Every line the command wrote was acknowledged, so the notice has no
	// unstreamed count to report - the negative half of the count asserted
	// in TestWrapperDoesNotBlockOnADeadParent.
	if strings.Contains(last.Text, "not streamed") {
		t.Errorf("notice text = %q, want no unstreamed count: the parent acknowledged every line", last.Text)
	}
	if joined := strings.Join(streamText(t, got), "\n"); !strings.Contains(joined, "line 4 unterminated") {
		t.Errorf("chunks = %q, want even a last line the command left unterminated to have been streamed before the notice", joined)
	}
}

// TestWrapperDoesNotBlockOnADeadParent: the tee to the output file is the
// source of truth and the child never waits on an LLM. Both halves are a
// parent that cannot take the output, and they fail differently on
// purpose: an absent listener fails a send instantly, which no amount of
// blocking would show, so the stalled one - accepting the connection and
// never answering, which costs a sender the whole wire deadline - is the
// half with the teeth. What it measures is the *command's* own duration,
// read off the output file's last write, because the wrapper's own
// ending legitimately waits out a stalled send or two and would drown it.
//
// What that duration is compared against is measured here rather than
// written down: the same command through the same wrapper with no parent
// configured at all, which is the one arrangement that cannot block
// because there is no address to dial. A constant budget measures the
// machine instead of the wrapper, and on a loaded macOS runner the
// unblockable half of this test was the one that failed it.
func TestWrapperDoesNotBlockOnADeadParent(t *testing.T) {
	const lines = 60
	const writeEvery = 10 * time.Millisecond

	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "")
	withStreamKnobs(t, 20*time.Millisecond, 20*time.Millisecond, 100*time.Millisecond)
	_, baseline := runStreamingChild(t, lines, writeEvery)

	// A parent that cannot take the output may cost the command as much
	// again as it cost with no parent at all - room for the run-to-run
	// spread of a loaded machine, which is what a fixed figure here could
	// never be given.
	budget := 2 * baseline
	// The deadline a stalled parent costs a sender is scaled to the same
	// baseline and kept half as long again as that budget, so one blocked
	// send puts the command over it however slow the machine is. It has
	// to clear the budget rather than the baseline: a send made from the
	// copy path blocks *while* the command is running, so what such a
	// wrapper costs is one deadline, not a deadline on top of the run.
	// Scaled rather than fixed for the converse reason - a fixed deadline
	// is eventually small beside a slow machine's own noise, and the test
	// stops being able to see a wrapper that waits at all.
	stalledWire := max(3*baseline, 3*time.Second)

	t.Run("nothing listening", func(t *testing.T) {
		t.Setenv("KIDO_STATE_DIR", t.TempDir())
		t.Setenv("TMUX_PANE", "%1")
		withPanes(t, samePane)
		if err := state.Record("parent", state.Session{
			Agent: state.AgentPi, Pane: "%2", PID: 1, Status: state.Idle, Title: "orchestrator",
			Instance: "root-inst", Inbox: testutil.StaleSocket(t), Protocol: msg.V1,
		}); err != nil {
			t.Fatal(err)
		}
		t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "root-inst")
		withStreamKnobs(t, 20*time.Millisecond, 20*time.Millisecond, 100*time.Millisecond)

		id, child := runStreamingChild(t, lines, writeEvery)
		if child > budget {
			t.Errorf("the command took %v, want under %v (%v with no parent at all): a parent that cannot be reached must cost it nothing", child, budget, baseline)
		}
		if got := countLines(t, subrun.OutputPath(id)); got != lines {
			t.Errorf("output file has %d lines, want all %d: the file is the source of truth", got, lines)
		}
	})

	t.Run("listening and never answering", func(t *testing.T) {
		t.Setenv("KIDO_STATE_DIR", t.TempDir())
		in := streamParent(t, "root-inst", "")
		t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "root-inst")
		withStreamKnobs(t, 20*time.Millisecond, 20*time.Millisecond, 100*time.Millisecond)
		withInboxTimeout(t, stalledWire)

		id, child := runStreamingChild(t, lines, writeEvery)
		if child > budget {
			t.Errorf("the command took %v, want under %v (%v with no parent at all, and a %v wire deadline to block on): a stalled parent must not be waited on by the child",
				child, budget, baseline, stalledWire)
		}
		if got := countLines(t, subrun.OutputPath(id)); got != lines {
			t.Errorf("output file has %d lines, want all %d", got, lines)
		}

		// The stalled inbox reads what arrives and answers nothing, so the
		// notice is here to be read even though its sender gave up on it.
		var notice string
		for _, raw := range in.Received() {
			if env, ok := msg.Parse([]byte(raw)); ok && env.Kind == msg.KindNotice {
				notice = env.Text
			}
		}
		if notice == "" {
			t.Fatalf("no completion notice arrived at all; the inbox holds %d payloads", len(in.Received()))
		}
		want := fmt.Sprintf("%d lines not streamed", lines)
		if !strings.Contains(notice, want) {
			t.Errorf("notice text = %q, want %q: nothing was acknowledged, so nothing was streamed", notice, want)
		}
	})
}

// runStreamingChild runs a streaming wrapper over a command that writes
// lines lines, one every every, and reports how long the command itself
// took - the output file's last write is the command's last line, and a
// wrapper that made the child wait on a send delays every write after it.
func runStreamingChild(t *testing.T, lines int, every time.Duration) (string, time.Duration) {
	t.Helper()
	script := fmt.Sprintf("for i in $(seq 1 %d); do echo line $i; sleep %.3f; done", lines, every.Seconds())
	id := startAsyncRun(t, "sh", "-c", script)
	start := time.Now()
	captureStdout(t, func() { asyncRunCmd([]string{"--run-id", id, "--name", "chatty", "--stream"}) })
	fi, err := os.Stat(subrun.OutputPath(id))
	if err != nil {
		t.Fatal(err)
	}
	return id, fi.ModTime().Sub(start)
}

func countLines(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(b), "\n")
}
