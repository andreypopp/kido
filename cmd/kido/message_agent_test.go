package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// withPanes points listPanes at a fixed list for the duration of the test,
// so the message-sending commands never talk to a real tmux server.
func withPanes(t *testing.T, panes []tmux.Pane) {
	t.Helper()
	prev := listPanes
	listPanes = func() ([]tmux.Pane, error) { return panes, nil }
	t.Cleanup(func() { listPanes = prev })
}

// withSendPrompt replaces sendPrompt with a fake that fails with err and
// records its calls instead of talking to a real tmux server. The
// returned func reports the calls made so far.
func withSendPrompt(t *testing.T, err error) func() []string {
	t.Helper()
	prev := sendPrompt
	var calls []string
	sendPrompt = func(pane, text string) error {
		calls = append(calls, pane+": "+text)
		return err
	}
	t.Cleanup(func() { sendPrompt = prev })
	return func() []string { return calls }
}

// samePane is the one-session pane fixture most of these tests use: the
// caller at %1 and every target somewhere in the same session, "$1".
var samePane = []tmux.Pane{
	{PaneID: "%1", SessionID: "$1"},
	{PaneID: "%2", SessionID: "$1"},
	{PaneID: "%3", SessionID: "$1"},
}

// TestMessageV0RawText checks that a target with no advertised protocol
// (state.Session.Protocol zero) gets plain v0 text, byte for byte - the
// same contract kido prompt relies on, so an unupgraded receiver still
// sees exactly its prompt and not a JSON envelope.
func TestMessageV0RawText(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if code := messageAgentCmd([]string{"target"}, strings.NewReader("hello there")); code != 0 {
		t.Fatalf("message_agent = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 || msgs[0] != "hello there" {
		t.Fatalf("server got %q, want v0 raw text [%q]", msgs, "hello there")
	}
}

// TestMessageV1Envelope checks that a target advertising protocol 1 gets
// a v1 JSON envelope with the text intact, and the reply rule the split
// command surface introduced: --reply-to alone makes it a reply, both in
// the envelope's kind and in its ReplyTo. There used to be a --kind flag
// as well, and `--kind reply --reply-to ID` was the only correct
// spelling of one thing.
func TestMessageV1Envelope(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	if code := messageAgentCmd([]string{"--reply-to", "ask-1", "target"}, strings.NewReader("hi there")); code != 0 {
		t.Fatalf("message_agent = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("server got %d messages, want 1: %q", len(msgs), msgs)
	}
	env, ok := msg.Parse([]byte(msgs[0]))
	if !ok {
		t.Fatalf("payload %q did not parse as a v1 envelope", msgs[0])
	}
	if env.Kind != msg.KindReply || env.Text != "hi there" || env.ID == "" {
		t.Errorf("envelope = %+v, want kind reply, text %q, a non-empty id", env, "hi there")
	}
	if env.ReplyTo != "ask-1" {
		t.Errorf("envelope.ReplyTo = %q, want %q", env.ReplyTo, "ask-1")
	}
}

// TestMessageV1PlainKind is the other half of the rule above: without
// --reply-to the same command sends a plain message, correlating nothing.
func TestMessageV1PlainKind(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	if code := messageAgentCmd([]string{"target"}, strings.NewReader("hi there")); code != 0 {
		t.Fatalf("message_agent = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("server got %d messages, want 1: %q", len(msgs), msgs)
	}
	env, ok := msg.Parse([]byte(msgs[0]))
	if !ok {
		t.Fatalf("payload %q did not parse as a v1 envelope", msgs[0])
	}
	if env.Kind != msg.KindMessage || env.ReplyTo != "" {
		t.Errorf("envelope = %+v, want kind message and no ReplyTo", env)
	}
}

// TestNotifyParentSendsToTheInstanceInTheEnvironment pins what makes
// `kido notify_parent` take no target at all: the parent comes from
// KIDO_AGENT_PARENT_INSTANCE, matched against the live registry. The
// only record here is reachable by nothing else - its pane is in another
// tmux session, where resolveTarget's scope would refuse it, and no
// name or id argument is given - so a delivery can only have come from
// the instance in the environment. That is also the negative control
// for the round trip this replaced: pi's notify_parent used to read its
// own row out of the agent list, and the agent list cannot see this
// target.
func TestNotifyParentSendsToTheInstanceInTheEnvironment(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%9", SessionID: "$2"},
	})

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("parent", state.Session{
		Pane: "%9", PID: os.Getpid(), Status: state.Idle, Instance: "parent-inst",
		Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "parent-inst")
	if code := notifyParentCmd(nil, strings.NewReader("the answer is 42")); code != 0 {
		t.Fatalf("notify_parent = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("parent inbox got %q, want one envelope", msgs)
	}
	env, ok := msg.Parse([]byte(msgs[0]))
	if !ok {
		t.Fatalf("payload %q did not parse as a v1 envelope", msgs[0])
	}
	if env.Kind != msg.KindNotice || env.Text != "the answer is 42" {
		t.Errorf("envelope = %+v, want kind notice carrying the summary", env)
	}
}

// TestNotifyParentWithoutAParentRefuses: a root session has no parent to
// tell, which must read as a refusal rather than a silent success - and
// must send nothing, even though a perfectly addressable agent is sitting
// there with an inbox. The second case pins that the parent is never an
// argument: naming one is a usage error, not an address.
func TestNotifyParentWithoutAParentRefuses(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("peer", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Instance: "peer-inst",
		Inbox: in.Path, Protocol: msg.V1, Title: "peer",
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "")
	if code := notifyParentCmd(nil, strings.NewReader("nobody to tell")); code != 1 {
		t.Errorf("notify_parent with no parent in the environment = %d, want 1", code)
	}

	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "peer-inst")
	if code := notifyParentCmd([]string{"peer"}, strings.NewReader("named a target")); code != 1 {
		t.Errorf("notify_parent with an argument = %d, want 1", code)
	}

	if msgs := in.Received(); len(msgs) != 0 {
		t.Errorf("inbox got %q, want nothing sent", msgs)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Errorf("sendPrompt calls = %v, want none", calls)
	}
}

// TestNotifyParentGoneParent: the instance in the environment naming
// nobody live is the ordinary case of a parent that has since exited, and
// is an error naming the instance rather than a fallback to anything.
func TestNotifyParentGoneParent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "long-gone")
	if code := notifyParentCmd(nil, strings.NewReader("anybody there?")); code != 1 {
		t.Error("notify_parent to a gone parent = 0, want 1")
	}
	if calls := pastes(); len(calls) != 0 {
		t.Errorf("sendPrompt calls = %v, want none", calls)
	}
}

// TestMessageResolveByName checks that an exact, case-insensitive title
// match wins outright, even when it would also be a valid id prefix of
// something else.
func TestMessageResolveByName(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("abc123", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Title: "Worker-2",
	}); err != nil {
		t.Fatal(err)
	}

	if code := messageAgentCmd([]string{"worker-2"}, strings.NewReader("x")); code != 0 {
		t.Errorf("code = %d, want 0", code)
	}
	if msgs := in.Received(); len(msgs) != 1 {
		t.Fatalf("server got %q, want one message", msgs)
	}
}

// TestMessageResolveByPaneTitleFallback: buildAgents (agents.go) names a
// session with no reported Title after its pane's title, and that is the
// name a model reads off list_agents. matchTarget must accept that same
// name, or kido message_agent refuses a target by the very name kido list_agents
// just showed for it.
func TestMessageResolveByPaneTitleFallback(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%2", SessionID: "$1", Title: "worker-2"},
	})

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if code := messageAgentCmd([]string{"worker-2"}, strings.NewReader("hi")); code != 0 {
		t.Fatalf("code = %d, want 0: worker-2 is the name kido list_agents shows for this session", code)
	}
	if msgs := in.Received(); len(msgs) != 1 {
		t.Fatalf("server got %q, want one message", msgs)
	}
}

// TestMessageResolveAmbiguity checks the three addressing rules and their
// ambiguity errors: two sessions with the same title, an id prefix that
// matches two ids, and a target found nowhere at all.
func TestMessageResolveAmbiguity(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%2", SessionID: "$1"},
		{PaneID: "%3", SessionID: "$1"},
		{PaneID: "%4", SessionID: "$1"},
		{PaneID: "%5", SessionID: "$1"},
	})

	inA := testutil.StartInbox(t, "ok\n")
	inB := testutil.StartInbox(t, "ok\n")
	if err := state.Record("abc123", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: inA.Path}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("abd456", state.Session{Pane: "%3", PID: os.Getpid(), Status: state.Idle, Inbox: inB.Path}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("worker-x", state.Session{Pane: "%4", PID: os.Getpid(), Status: state.Idle, Title: "scout"}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("worker-y", state.Session{Pane: "%5", PID: os.Getpid(), Status: state.Idle, Title: "scout"}); err != nil {
		t.Fatal(err)
	}

	if code := messageAgentCmd([]string{"abc123"}, strings.NewReader("x")); code != 0 {
		t.Errorf("exact id: code = %d, want 0", code)
	}
	if code := messageAgentCmd([]string{"abc"}, strings.NewReader("x")); code != 0 {
		t.Errorf("unique prefix: code = %d, want 0", code)
	}
	if code := messageAgentCmd([]string{"ab"}, strings.NewReader("x")); code == 0 {
		t.Error("ambiguous id prefix: code = 0, want an error")
	}
	if code := messageAgentCmd([]string{"nope"}, strings.NewReader("x")); code == 0 {
		t.Error("no match: code = 0, want an error")
	}
	if code := messageAgentCmd([]string{"scout"}, strings.NewReader("x")); code == 0 {
		t.Error("ambiguous name: code = 0, want an error")
	}
}

// TestMessageOutOfSession checks that an agent that exists but lives in a
// different tmux session is reported as unaddressable, not "not found" -
// resolveTarget must name the reason rather than pretend it saw nothing.
func TestMessageOutOfSession(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%9", SessionID: "$2"},
	})

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("elsewhere", state.Session{
		Pane: "%9", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Title: "far-away",
	}); err != nil {
		t.Fatal(err)
	}

	code := messageAgentCmd([]string{"elsewhere"}, strings.NewReader("x"))
	if code == 0 {
		t.Fatal("code = 0, want an error: elsewhere is in another session")
	}
	if in.Received() != nil {
		t.Error("message reached the far-session inbox; it must not be addressable")
	}
}

// TestMessageNoInboxPastes checks the Claude-pane fallback: a live agent
// in scope that has reported no inbox at all still gets the message,
// pasted into its pane exactly as kido prompt would.
func TestMessageNoInboxPastes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, nil)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if code := messageAgentCmd([]string{"target"}, strings.NewReader("hi claude")); code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
	calls := pastes()
	if len(calls) != 1 || calls[0] != "%2: hi claude" {
		t.Fatalf("sendPrompt calls = %v, want one paste of the raw text into %%2", calls)
	}
}

// TestMessageInboxHardErrorNoFallback checks the AGENTS.md rule that a
// non-errInboxUnavailable failure must never fall back to a paste: the
// message may already have reached the agent, and pasting it again would
// double-send.
func TestMessageInboxHardErrorNoFallback(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	// A reply other than "ok" is a hard error from deliverInbox, not
	// errInboxUnavailable (see TestDeliverInboxBadReply).
	in := testutil.StartInbox(t, "nope\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if code := messageAgentCmd([]string{"target"}, strings.NewReader("x")); code == 0 {
		t.Fatal("code = 0, want an error: the inbox failure must not be swallowed")
	}
	if calls := pastes(); len(calls) != 0 {
		t.Errorf("sendPrompt was called %v, want no fallback on a hard inbox error", calls)
	}
}

// TestMessageEmptyStdin checks that empty input is rejected before kido
// resolves a target at all.
func TestMessageEmptyStdin(t *testing.T) {
	if code := messageAgentCmd([]string{"whoever"}, strings.NewReader("")); code != 1 {
		t.Errorf("code = %d, want 1", code)
	}
}

// TestMessageUsage checks argument-count errors: no target and more than
// one positional argument are both rejected.
func TestMessageUsage(t *testing.T) {
	if code := messageAgentCmd(nil, strings.NewReader("x")); code != 1 {
		t.Errorf("no target: code = %d, want 1", code)
	}
	if code := messageAgentCmd([]string{"a", "b"}, strings.NewReader("x")); code != 1 {
		t.Errorf("two targets: code = %d, want 1", code)
	}
}

// TestResolveTargetAmbiguousElsewhere checks the error for a name that
// matches nothing in scope and several agents outside it. matchTarget
// reports an ambiguity with a zero state.Session, so the out-of-session
// branch must not name its id: it would print an empty one and claim a
// single match where there were several.
func TestResolveTargetAmbiguousElsewhere(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%8", SessionID: "$2"},
		{PaneID: "%9", SessionID: "$2"},
	}
	states := map[string]state.Session{
		"twin-a": {ID: "twin-a", Pane: "%8", Title: "Twin"},
		"twin-b": {ID: "twin-b", Pane: "%9", Title: "Twin"},
	}

	_, err := resolveTarget(states, panes, "%1", "Twin")
	if err == nil {
		t.Fatal("resolveTarget succeeded, want an ambiguity error")
	}
	got := err.Error()
	for _, want := range []string{"twin-a", "twin-b", "several", "tmux session"} {
		if !strings.Contains(got, want) {
			t.Errorf("error %q does not mention %q", got, want)
		}
	}
	if strings.Contains(got, "()") {
		t.Errorf("error %q names an empty session id", got)
	}
}

// TestMessageRefusesSelf checks that an agent cannot address its own
// pane. list_agents reports the caller alongside its peers, so a model
// picking a name off that list can pick its own, and delivering would
// hand it its own message back as a fresh user turn.
func TestMessageRefusesSelf(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	if err := state.Record("me", state.Session{
		Pane: "%1", PID: os.Getpid(), Status: state.Idle, Title: "Self",
	}); err != nil {
		t.Fatal(err)
	}
	if code := messageAgentCmd([]string{"Self"}, strings.NewReader("talking to myself")); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none", calls)
	}
}

// TestMessageRefusesInvalidUTF8 pins that a message is refused rather
// than delivered differently by each path: the inbox marshals it into
// JSON, which substitutes U+FFFD for an invalid byte, while a paste
// writes the byte through untouched.
func TestMessageRefusesInvalidUTF8(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Title: "Alpha",
	}); err != nil {
		t.Fatal(err)
	}
	if code := messageAgentCmd([]string{"Alpha"}, strings.NewReader("bad:\xff\xfe:end")); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none", calls)
	}
}

// TestAskAgent checks that `kido ask_agent` sends an ask envelope with no
// ReplyTo, and that the caller-supplied --id, not a generated one, is
// what ends up on the wire - ask_agent (pi/kido-agents.ts) must know the
// id before sending, to register what it is waiting for.
func TestAskAgent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	if code := askAgentCmd([]string{"--id", "ask-7", "target"}, strings.NewReader("are you done?")); code != 0 {
		t.Fatalf("ask_agent = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("server got %d messages, want 1: %q", len(msgs), msgs)
	}
	env, ok := msg.Parse([]byte(msgs[0]))
	if !ok {
		t.Fatalf("payload %q did not parse as a v1 envelope", msgs[0])
	}
	if env.Kind != msg.KindAsk || env.ID != "ask-7" || env.ReplyTo != "" || env.Text != "are you done?" {
		t.Errorf("envelope = %+v, want kind ask, id ask-7, no ReplyTo, the question text", env)
	}
}

// TestMessageKindCannotBeMisstated is what is left of a table that used
// to reject three ways of naming a kind wrongly (a reply with no
// --reply-to, an ask with one, a --kind nobody defines). The kind is no
// longer said out loud at all: it comes from which command was run, so
// the only spelling those rules still have is a flag on a command that
// does not define it, and flag.FlagSet refuses that before anything is
// resolved or delivered. A live target is recorded anyway, so a pass
// cannot come from the target being unresolvable instead.
func TestMessageKindCannotBeMisstated(t *testing.T) {
	cases := []struct {
		name string
		run  func([]string, io.Reader) int
		args []string
		why  string
	}{
		{"ask with reply-to", askAgentCmd, []string{"--reply-to", "x", "target"}, "an ask starts a new correlation, it does not answer one"},
		{"message with an id", messageAgentCmd, []string{"--id", "x", "target"}, "only an ask assigns its own id, so its waiter can be registered first"},
		{"kind named explicitly", messageAgentCmd, []string{"--kind", "reply", "target"}, "the command is the kind; --kind no longer exists"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("KIDO_STATE_DIR", t.TempDir())
			t.Setenv("TMUX_PANE", "%1")
			withPanes(t, samePane)
			pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

			if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
				t.Fatal(err)
			}
			if code := c.run(c.args, strings.NewReader("x")); code != 1 {
				t.Fatalf("code = %d, want 1: %s", code, c.why)
			}
			if calls := pastes(); len(calls) != 0 {
				t.Fatalf("sendPrompt calls = %v, want none", calls)
			}
		})
	}
}

// TestMessageKindNonMessageRequiresV1 checks that an ask/reply/notice sent
// to a target that has not advertised protocol 1 is refused outright,
// rather than silently downgraded to v0 raw text that would strip the
// kind and id entirely.
func TestMessageKindNonMessageRequiresV1(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}
	if code := askAgentCmd([]string{"target"}, strings.NewReader("x")); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none", calls)
	}
	if msgs := in.Received(); len(msgs) != 0 {
		t.Fatalf("inbox got %v, want nothing delivered", msgs)
	}
}

// TestMessageAskRefusalDoesNotPaste checks that a "refused" wire answer -
// what a receiver sends when answering this ask would close a cycle (see
// AGENTS.md's Cycles section) - surfaces as an error without ever falling
// back to send-keys: the question was read and deliberately declined, not
// mis-delivered, so pasting it again would just hand the target the same
// cycle it refused.
func TestMessageAskRefusalDoesNotPaste(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	in := testutil.StartInbox(t, "refused\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	code := askAgentCmd([]string{"--id", "ask-9", "target"}, strings.NewReader("are you done?"))
	if code == 0 {
		t.Fatal("code = 0, want an error: the ask was refused")
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none: a refusal must never paste", calls)
	}
}

// TestMessageNoticeToADeadV1AgentDoesNotPaste is the case the
// advertised-protocol check above cannot see: a target that reported
// --inbox and --protocol 1 while it was alive and has since gone, leaving
// a stale socket path in its record. It passes the Protocol >= V1 gate,
// and deliverInboxOrPaste's answer to a socket nobody is listening on is
// to paste into the pane - which, for an agent that is no longer running,
// means typing the text at the shell the pane fell back to and pressing
// Enter. For a notice that text is model-authored (a subagent's completion
// notice is built from its own title and activity, pi/kido-agents.ts), so
// the paste would be a command line the model wrote, run in its parent's
// pane. The rule for a dead parent is that there is nobody to tell; this
// pins that it is not told by send-keys instead.
func TestMessageNoticeToADeadV1AgentDoesNotPaste(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, nil)

	// A path with nothing listening on it: exactly what a dead agent's
	// record still names. The instance is what makes the same record the
	// parent notify_parent resolves out of the environment.
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Instance: "target-inst",
		Inbox: filepath.Join(t.TempDir(), "gone.sock"), Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "target-inst")
	sends := map[string]func() int{
		"notice": func() int { return notifyParentCmd(nil, strings.NewReader("touch /tmp/pwned")) },
		"ask":    func() int { return askAgentCmd([]string{"target"}, strings.NewReader("touch /tmp/pwned")) },
		"reply": func() int {
			return messageAgentCmd([]string{"--reply-to", "ask-1", "target"}, strings.NewReader("touch /tmp/pwned"))
		},
	}
	for kind, run := range sends {
		if code := run(); code != 1 {
			t.Errorf("a %s to a dead v1 agent = %d, want 1", kind, code)
		}
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none: only a plain message may fall back to a paste", calls)
	}
}

// TestMessageNoInboxStillPastes is the negative control for the test
// above: the fallback itself must survive, since it is the only way an
// agent without an inbox at all (Claude Code) is reachable.
func TestMessageNoInboxStillPastes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, nil)

	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Inbox: filepath.Join(t.TempDir(), "gone.sock"), Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}
	if code := messageAgentCmd([]string{"target"}, strings.NewReader("hello")); code != 0 {
		t.Fatalf("message = %d, want 0", code)
	}
	if calls := pastes(); len(calls) != 1 {
		t.Fatalf("sendPrompt calls = %v, want exactly one paste", calls)
	}
}
