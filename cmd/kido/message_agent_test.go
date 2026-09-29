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

func withPanes(t *testing.T, panes []tmux.Pane) {
	t.Helper()
	testutil.Swap(t, &listPanes, func() ([]tmux.Pane, error) { return panes, nil })
}

func withSendPrompt(t *testing.T, err error) func() []string {
	t.Helper()
	var calls []string
	testutil.Swap(t, &sendPrompt, func(pane, text string) error {
		calls = append(calls, pane+": "+text)
		return err
	})
	return func() []string { return calls }
}

func withAskingCaller(t *testing.T) {
	t.Helper()
	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("caller", state.Session{
		Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle,
		Title: "asker", Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}
}

var samePane = []tmux.Pane{
	{PaneID: "%1", SessionID: "$1"},
	{PaneID: "%2", SessionID: "$1"},
	{PaneID: "%3", SessionID: "$1"},
}

// TestMessageV1Envelope: a target gets a v1 JSON envelope with the text
// intact, and --reply-to alone makes it a reply, both in the envelope's
// kind and in its ReplyTo.
func TestMessageV1Envelope(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
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

func TestMessageV1PlainKind(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
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

// TestNotifyParentSendsToTheSessionInTheEnvironment: the parent comes
// from KIDO_AGENT_PARENT_SESSION, matched against the live registry. The
// only record here is reachable by nothing else - its pane is in another
// tmux session, out of resolveTarget's scope - so a delivery can only
// have come from the session id in the environment.
func TestNotifyParentSendsToTheSessionInTheEnvironment(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%9", SessionID: "$2"},
	})

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("parent-sess", state.Session{
		Pane: "%9", PID: os.Getpid(), Status: state.Idle,
		Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("KIDO_AGENT_PARENT_SESSION", "parent-sess")
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
// tell, and the parent is never an argument: naming one is a usage
// error, not an address.
func TestNotifyParentWithoutAParentRefuses(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("peer-sess", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Inbox: in.Path, Title: "peer",
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("KIDO_AGENT_PARENT_SESSION", "")
	if code := notifyParentCmd(nil, strings.NewReader("nobody to tell")); code != 1 {
		t.Errorf("notify_parent with no parent in the environment = %d, want 1", code)
	}

	t.Setenv("KIDO_AGENT_PARENT_SESSION", "peer-sess")
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

func TestNotifyParentGoneParent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	t.Setenv("KIDO_AGENT_PARENT_SESSION", "long-gone")
	if code := notifyParentCmd(nil, strings.NewReader("anybody there?")); code != 1 {
		t.Error("notify_parent to a gone parent = 0, want 1")
	}
	if calls := pastes(); len(calls) != 0 {
		t.Errorf("sendPrompt calls = %v, want none", calls)
	}
}

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

// TestMessageResolveByPaneTitleFallback: buildAgents names a session
// with no reported Title after its pane's title, and that is the name a
// model reads off list_agents. matchTarget must accept that same name,
// or kido message_agent refuses a target by the very name kido
// list_agents just showed for it.
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
		t.Fatalf("code = %d, want 0", code)
	}
	if msgs := in.Received(); len(msgs) != 1 {
		t.Fatalf("server got %q, want one message", msgs)
	}
}

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

// TestMessageInboxHardErrorNoFallback: a non-msg.ErrInboxUnavailable
// failure must never fall back to a paste.
func TestMessageInboxHardErrorNoFallback(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

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

func TestMessageEmptyStdin(t *testing.T) {
	if code := messageAgentCmd([]string{"whoever"}, strings.NewReader("")); code != 1 {
		t.Errorf("code = %d, want 1", code)
	}
}

func TestMessageUsage(t *testing.T) {
	if code := messageAgentCmd(nil, strings.NewReader("x")); code != 1 {
		t.Errorf("no target: code = %d, want 1", code)
	}
	if code := messageAgentCmd([]string{"a", "b"}, strings.NewReader("x")); code != 1 {
		t.Errorf("two targets: code = %d, want 1", code)
	}
}

// TestResolveTargetAmbiguousElsewhere: matchTarget reports an ambiguity
// with a zero state.Session, so the out-of-session branch must not name
// its id, or it would print an empty one.
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
// JSON, substituting U+FFFD for an invalid byte, while a paste writes
// the byte through untouched.
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

// TestAskAgent checks that `kido ask_agent` sends an ask envelope with
// no ReplyTo, and that the caller-supplied --id, not a generated one, is
// what ends up on the wire.
func TestAskAgent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	withAskingCaller(t)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
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

// TestMessageKindCannotBeMisstated: the kind comes from which command
// was run, so a flag naming a kind on a command that does not define it
// is refused by flag.FlagSet before anything is resolved or delivered. A
// live target is recorded anyway, so a pass cannot come from the target
// being unresolvable instead.
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

// TestMessageKindNonMessageRequiresInbox: an ask/reply/notice sent to a
// target with no inbox at all is refused outright, rather than falling
// back to a paste that would strip the kind and id entirely.
func TestMessageKindNonMessageRequiresInbox(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	withAskingCaller(t)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle,
	}); err != nil {
		t.Fatal(err)
	}
	if code := askAgentCmd([]string{"target"}, strings.NewReader("x")); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none", calls)
	}
}

// TestMessageAskRefusalDoesNotPaste: a "refused" wire answer surfaces
// as an error without ever falling back to send-keys, since the
// question was read and deliberately declined, not mis-delivered.
func TestMessageAskRefusalDoesNotPaste(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	withAskingCaller(t)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	in := testutil.StartInbox(t, "refused\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
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

// TestMessageNoticeToADeadV1AgentDoesNotPaste is the case the inbox
// check above cannot see: a target that reported --inbox while alive and
// has since gone, leaving a stale socket path in its record.
// deliverInboxOrPaste's answer to a socket nobody is listening on is
// normally to paste into the pane, but a notice's text is model-authored
// and pasting it would run it as a command line in the parent's pane.
func TestMessageNoticeToADeadV1AgentDoesNotPaste(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	withAskingCaller(t)
	pastes := withSendPrompt(t, nil)

	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Inbox: filepath.Join(t.TempDir(), "gone.sock"),
	}); err != nil {
		t.Fatal(err)
	}

	t.Setenv("KIDO_AGENT_PARENT_SESSION", "target")
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
// above: the fallback itself must survive.
func TestMessageNoInboxStillPastes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, nil)

	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Inbox: filepath.Join(t.TempDir(), "gone.sock"),
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

// TestAskAgentRefusesACallerWithNoReplyPath: an ask demands a correlated
// answer, which arrives on the asker's own inbox or not at all, so a
// caller with no reply path (no state record, or a record with no kido
// inbox) is refused here before anything is sent. The third assertion
// is the point of the test: the target's inbox got nothing.
func TestAskAgentRefusesACallerWithNoReplyPath(t *testing.T) {
	cases := []struct {
		name  string
		setUp func(t *testing.T)
	}{
		{"no record for the caller's pane", func(*testing.T) {}},
		{"a record with no inbox", func(t *testing.T) {
			if err := state.Record("caller", state.Session{
				Agent: state.AgentClaude, Pane: "%1", PID: os.Getpid(), Status: state.Idle,
			}); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("KIDO_STATE_DIR", t.TempDir())
			t.Setenv("TMUX_PANE", "%1")
			withPanes(t, samePane)
			pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))
			c.setUp(t)

			in := testutil.StartInbox(t, "ok\n")
			if err := state.Record("target", state.Session{
				Agent: state.AgentPi, Pane: "%2", PID: os.Getpid(), Status: state.Idle,
				Title: "victim", Inbox: in.Path,
			}); err != nil {
				t.Fatal(err)
			}

			var code int
			stderr := capture(t, &os.Stderr, func() {
				code = askAgentCmd([]string{"--id", "t1", "victim"}, strings.NewReader("are you done?"))
			})
			if code != 1 {
				t.Fatalf("ask_agent = %d, want 1: the caller cannot be answered", code)
			}
			if !strings.Contains(stderr, "kido message_agent") {
				t.Errorf("stderr = %q, want it to point at kido message_agent", stderr)
			}
			if msgs := in.Received(); len(msgs) != 0 {
				t.Errorf("target's inbox got %q, want nothing: an unanswerable question must not interrupt anyone", msgs)
			}
			if calls := pastes(); len(calls) != 0 {
				t.Errorf("sendPrompt calls = %v, want none", calls)
			}
		})
	}
}

// TestAskAgentFromAnAgentWithAnInboxStillSends is the negative control
// for the refusal above.
func TestAskAgentFromAnAgentWithAnInboxStillSends(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	withAskingCaller(t)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Title: "peer", Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if code := askAgentCmd([]string{"--id", "t2", "peer"}, strings.NewReader("are you done?")); code != 0 {
		t.Fatalf("ask_agent from an agent with an inbox = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("target's inbox got %d messages, want the question: %q", len(msgs), msgs)
	}
	if env, ok := msg.Parse([]byte(msgs[0])); !ok || env.Kind != msg.KindAsk || env.ID != "t2" {
		t.Errorf("payload %q, want the ask envelope with id t2", msgs[0])
	}
}
