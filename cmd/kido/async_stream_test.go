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

func withStreamKnobs(t *testing.T, batch, floor, ceiling time.Duration) {
	t.Helper()
	testutil.Swap(t, &streamBatchInterval, batch)
	testutil.Swap(t, &streamBackoffFloor, floor)
	testutil.Swap(t, &streamBackoffCap, ceiling)
}

// streamParent is noticeParent with a chosen reply: "ok\n" for a parent
// that answers, "" for one that accepts the connection and never does,
// which is the only failure that can actually make a sender wait.
func streamParent(t *testing.T, session, reply string) *testutil.Inbox {
	t.Helper()
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	in := testutil.StartInbox(t, reply)
	if err := state.Record(session, state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: 1, Status: state.Idle, Title: "orchestrator",
		Inbox: in.Path,
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

// TestStreamNeverPastes: a stream envelope is a build's output, and
// must never fall back to a paste into a shell that reclaimed a dead
// agent's pane. Carried by the last assertion: the pane was not typed
// into.
func TestStreamNeverPastes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	if err := state.Record("target", state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Title: "victim", Inbox: testutil.StaleSocket(t),
	}); err != nil {
		t.Fatal(err)
	}

	var code int
	stderr := capture(t, &os.Stderr, func() {
		code = send("async-run", sendSpec{kind: msg.KindStream, to: named{"victim"}}, strings.NewReader("line 1\nline 2"))
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

// TestStreamCoalescesAndStripsAnsi: lines written one at a time arrive
// as a handful of envelopes rather than one each, with escape sequences
// stripped from what travels while the output file keeps them. Lines are
// written *slowly* so a wrapper sending one envelope per line would not
// be masked by pipe coalescing, and the envelope count is judged against
// the number of batch windows the run actually spanned, so the assertion
// reads the wrapper's batching rather than the machine's speed.
func TestStreamCoalescesAndStripsAnsi(t *testing.T) {
	const lines = 20
	const writeEvery = 30 * time.Millisecond
	const batch = 2 * time.Second

	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := streamParent(t, "root-sess", "ok\n")
	withStreamKnobs(t, batch, 20*time.Millisecond, 100*time.Millisecond)

	script := fmt.Sprintf(`for i in $(seq 1 %d); do printf '\033[32mline %%s\033[0m\n' $i; sleep %.3f; done`, lines, writeEvery.Seconds())
	id := startAsyncRun(t, "chatty", "root-sess", "sh", "-c", script)
	start := time.Now()
	capture(t, &os.Stdout, func() { asyncRunCmd([]string{"--run-id", string(id), "--stream"}) })
	elapsed := time.Since(start)

	chunks := streamText(t, envelopes(t, in))
	if len(chunks) == 0 {
		t.Fatalf("no stream envelopes arrived at all")
	}
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
// ended" arriving before the output it is the ending of would tell a
// parent a build finished and then hand it the middle.
func TestCompletionNoticeFollowsTheFinalChunk(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := streamParent(t, "root-sess", "ok\n")
	withStreamKnobs(t, 5*time.Second, 20*time.Millisecond, 100*time.Millisecond)

	id := startAsyncRun(t, "chatty", "root-sess", "sh", "-c", `printf 'line 1\nline 2\nline 3\nline 4 unterminated'; exit 2`)
	capture(t, &os.Stdout, func() { asyncRunCmd([]string{"--run-id", string(id), "--stream"}) })

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
	if strings.Contains(last.Text, "not streamed") {
		t.Errorf("notice text = %q, want no unstreamed count: the parent acknowledged every line", last.Text)
	}
	if joined := strings.Join(streamText(t, got), "\n"); !strings.Contains(joined, "line 4 unterminated") {
		t.Errorf("chunks = %q, want even a last line the command left unterminated to have been streamed before the notice", joined)
	}
}

// TestWrapperDoesNotBlockOnADeadParent: the tee to the output file is
// the source of truth and the child never waits on an LLM. Measures the
// *command's* own duration, read off the output file's last write,
// against a baseline run with no parent configured at all - a constant
// budget would measure the machine instead of the wrapper.
func TestWrapperDoesNotBlockOnADeadParent(t *testing.T) {
	const lines = 60
	const writeEvery = 10 * time.Millisecond

	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	withStreamKnobs(t, 20*time.Millisecond, 20*time.Millisecond, 100*time.Millisecond)
	_, baseline := runStreamingChild(t, "", lines, writeEvery)

	budget := 2 * baseline
	stalledWire := max(3*baseline, 3*time.Second)

	t.Run("nothing listening", func(t *testing.T) {
		t.Setenv("KIDO_STATE_DIR", t.TempDir())
		t.Setenv("TMUX_PANE", "%1")
		withPanes(t, samePane)
		if err := state.Record("root-sess", state.Session{
			Agent: state.AgentPi, Pane: "%2", PID: 1, Status: state.Idle, Title: "orchestrator",
			Inbox: testutil.StaleSocket(t),
		}); err != nil {
			t.Fatal(err)
		}
		withStreamKnobs(t, 20*time.Millisecond, 20*time.Millisecond, 100*time.Millisecond)

		id, child := runStreamingChild(t, "root-sess", lines, writeEvery)
		if child > budget {
			t.Errorf("the command took %v, want under %v (%v with no parent at all): a parent that cannot be reached must cost it nothing", child, budget, baseline)
		}
		if got := countLines(t, subrun.OutputPath(id)); got != lines {
			t.Errorf("output file has %d lines, want all %d: the file is the source of truth", got, lines)
		}
	})

	t.Run("listening and never answering", func(t *testing.T) {
		t.Setenv("KIDO_STATE_DIR", t.TempDir())
		in := streamParent(t, "root-sess", "")
		withStreamKnobs(t, 20*time.Millisecond, 20*time.Millisecond, 100*time.Millisecond)
		testutil.Swap(t, &msg.InboxTimeout, stalledWire)

		id, child := runStreamingChild(t, "root-sess", lines, writeEvery)
		if child > budget {
			t.Errorf("the command took %v, want under %v (%v with no parent at all, and a %v wire deadline to block on): a stalled parent must not be waited on by the child",
				child, budget, baseline, stalledWire)
		}
		if got := countLines(t, subrun.OutputPath(id)); got != lines {
			t.Errorf("output file has %d lines, want all %d", got, lines)
		}

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

// runStreamingChild reports how long the command itself took: the
// output file's last write is the command's last line, and a wrapper
// that made the child wait on a send delays every write after it.
func runStreamingChild(t *testing.T, parent string, lines int, every time.Duration) (subrun.ID, time.Duration) {
	t.Helper()
	script := fmt.Sprintf("for i in $(seq 1 %d); do echo line $i; sleep %.3f; done", lines, every.Seconds())
	id := startAsyncRun(t, "chatty", parent, "sh", "-c", script)
	start := time.Now()
	capture(t, &os.Stdout, func() { asyncRunCmd([]string{"--run-id", string(id), "--stream"}) })
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
