package e2e

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// kidoAs runs kido from the test binary as if typed in pane: TMUX names
// the inner server, so kido sees its panes, and the caller is whatever
// record the test gave that pane, or none. stdout and stderr come back
// together, the trailing newline trimmed.
func (h *harness) kidoAs(pane, input string, env []string, args ...string) (string, int) {
	h.t.Helper()
	sock := h.in("display-message", "-p", "#{socket_path}")
	cmd := exec.Command(kidoBin, args...)
	cmd.Env = cleanEnv(append(append([]string{
		"TMUX=" + sock + ",0,0", "TMUX_PANE=" + pane, "KIDO_STATE_DIR=" + h.stateDir,
	}, h.caller(pane)...), env...)...)
	cmd.Stdin = strings.NewReader(input)
	out, err := cmd.CombinedOutput()
	code := 0
	if exit := (*exec.ExitError)(nil); errors.As(err, &exit) {
		code = exit.ExitCode()
	} else if err != nil {
		h.t.Fatalf("kido %v: %v", args, err)
	}
	return strings.TrimSuffix(string(out), "\n"), code
}

// expectKido runs kidoAs and requires exactly want on its output, with
// exit 0 for a delivery line and 1 for anything kido refused.
func (h *harness) expectKido(pane, input string, env []string, want string, args ...string) {
	h.t.Helper()
	code := 1
	if !strings.HasPrefix(want, "kido ") {
		code = 0
	}
	if got, rc := h.kidoAs(pane, input, env, args...); got != want || rc != code {
		h.t.Errorf("kido %v:\n got (rc=%d) %q\nwant (rc=%d) %q", args, rc, got, code, want)
	}
}

// firstPane is the pane a session was created with: the caller in these
// tests, which has no record until a test reports one for it.
func (h *harness) firstPane(session string) string {
	h.t.Helper()
	return h.in("display-message", "-p", "-t", session+":", "#{pane_id}")
}

// idleAgent opens a window that does nothing and reports a pi session on
// it. Its pane title is blanked, since tmux titles a new pane after the
// host and the helper uses that title for its OSC root record.
func (h *harness) idleAgent(session, id, title string, extra ...string) string {
	h.t.Helper()
	p := h.newWindow(session, "", "sh", "-c", "exec sleep 300")
	h.in("select-pane", "-t", p, "-T", "")
	h.programStatus(p, "state=idle:app=pi", title)
	h.agentStatus(id, p, extra...)
	return p
}

func envelopes(in *inbox) []map[string]any {
	var out []map[string]any
	for _, raw := range in.Received() {
		var m map[string]any
		if err := json.Unmarshal([]byte(raw), &m); err != nil {
			out = append(out, map[string]any{"v0": raw})
			continue
		}
		out = append(out, m)
	}
	return out
}

func field(m map[string]any, path ...string) string {
	var v any = m
	for _, k := range path {
		o, _ := v.(map[string]any)
		v = o[k]
	}
	s, _ := v.(string)
	return s
}

func TestMessageAgentResolvesByNameTitleIdAndPrefix(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	caller := h.firstPane("alpha")
	h.programStatus(caller, "state=idle:app=pi", "Self")
	h.agentStatus("me", caller)
	in := startInbox(t, "ok\n")
	h.idleAgent("alpha", "abc123", "Worker-2", "--inbox", in.Path)
	h.idleAgent("alpha", "abd456", "", "--inbox", in.Path)
	h.idleAgent("alpha", "worker-x", "scout")
	h.idleAgent("alpha", "worker-y", "scout")
	h.idleAgent("alpha", "untitled", "worker-6", "--inbox", in.Path)
	h.idleAgent("beta", "elsewhere", "far-away", "--inbox", in.Path)
	h.idleAgent("beta", "twin-a", "Twin")
	h.idleAgent("beta", "twin-b", "Twin")

	for _, c := range []struct{ to, want string }{
		{"worker-2", "delivered to Worker-2 by inbox"},
		{"@worker-2", "delivered to Worker-2 by inbox"},
		{"worker-6", "delivered to worker-6 by inbox"},
		{"abc123", "delivered to Worker-2 by inbox"},
		{"abd", "delivered to π -  by inbox"},
		{"ab", `kido tool message_agent: "ab" matches several agents by id: abc123 (Worker-2), abd456 (π - )`},
		{"nope", `kido tool message_agent: no agent session matches "nope"`},
		{"scout", `kido tool message_agent: "scout" matches several agents by name: worker-x (scout), worker-y (scout)`},
		{"Self", "kido tool message_agent: Self is this agent"},
		// Resolution tries the caller's own tmux session first, then says
		// why a match elsewhere is out of reach.
		{"elsewhere", "kido tool message_agent: elsewhere (elsewhere) is in another tmux session, not this one"},
		{"Twin", `kido tool message_agent: "Twin" matches several agents by name: twin-a (Twin), twin-b (Twin), none in this tmux session`},
	} {
		h.expectKido(caller, "x", nil, c.want, "tool", "message_agent", "--", c.to)
	}
	h.expectKido(caller, "bad:\xff\xfe:end", nil, "kido tool message_agent: message is not valid UTF-8",
		"tool", "message_agent", "--", "Worker-2")
	if got := len(in.Received()); got != 5 {
		t.Errorf("inbox received %d payloads, want the 5 deliveries: %q", got, in.Received())
	}
}

var freshID = regexp.MustCompile(`^[0-9a-f]{32}$`)

func TestMessageAgentSendsEnvelopesFromTheCaller(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	h.programStatus(caller, "state=idle:app=pi", "asker")
	h.agentStatus("caller", caller, "--inbox", startInbox(t, "ok\n").Path)
	in := startInbox(t, "ok\n")
	h.idleAgent("alpha", "target", "peer", "--inbox", in.Path)

	h.expectKido(caller, "hi there", nil, "delivered to peer by inbox", "tool", "message_agent", "--reply-to", "ask-1", "--", "peer")
	h.expectKido(caller, "hi there", nil, "delivered to peer by inbox", "tool", "message_agent", "--", "peer")
	h.expectKido(caller, "are you done?", nil, "delivered to peer by inbox", "tool", "ask_agent", "--id", "ask-7", "--", "peer")

	// An answer arrives on the asker's own inbox or not at all; the
	// target getting nothing is the point.
	mute := h.idleAgent("alpha", "mute", "mute")
	h.expectKido(mute, "are you done?", nil,
		"kido tool ask_agent: mute has no inbox for an answer to arrive on, and only a long-lived process has one; nothing sent - use kido tool message_agent instead, which is one-way and needs no reply",
		"tool", "ask_agent", "--id", "t1", "--", "peer")

	got := envelopes(in)
	if len(got) != 3 {
		t.Fatalf("inbox received %q, want 3 envelopes", in.Received())
	}
	for i, want := range []struct{ kind, id, replyTo, text string }{
		{"reply", "", "ask-1", "hi there"},
		{"message", "", "", "hi there"},
		{"ask", "ask-7", "", "are you done?"},
	} {
		e := got[i]
		id := field(e, "id")
		if field(e, "kind") != want.kind || field(e, "replyTo") != want.replyTo || field(e, "text") != want.text ||
			(want.id == "" && !freshID.MatchString(id)) || (want.id != "" && id != want.id) ||
			field(e, "from", "session") != "caller" || field(e, "from", "name") != "asker" || field(e, "from", "pane") != caller {
			t.Errorf("envelope %d = %v, want kind %s, id %q (fresh if empty), replyTo %q, text %q, from (caller, asker, %s)",
				i, e, want.kind, want.id, want.replyTo, want.text, caller)
		}
	}
}

func TestMessagePastesOnlyWithoutAnInbox(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	pane := h.piPane("alpha", "π - pastee")

	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("target", pane)
	h.expectKido(caller, "hi claude", nil, "pasted into pastee's pane", "tool", "message_agent", "--", "target")
	h.waitPaneText(pane, "got: hi claude")

	stale := staleSocket(t)
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("target", pane, "--inbox", stale)
	h.expectKido(caller, "hello", nil, "kido tool message_agent: pastee is not accepting messages", "tool", "message_agent", "--", "target")

	if err := os.Remove(stale); err != nil {
		t.Fatal(err)
	}
	run := "target"
	h.agentRunMeta(run, pane, "pastee", "")
	h.expectKido(caller, "hello", nil,
		"kido tool message_agent: pastee is not accepting messages; after it exits, resume it with spawn_subagent(resume: "+run+") and resend",
		"tool", "message_agent", "--", "target")
	h.programStatus(caller, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", caller, "#{pane_title}"), "π - "))
	h.agentStatus("caller", caller, "--inbox", startInbox(t, "ok\n").Path)
	h.expectKido(caller, "hello", nil,
		"kido tool ask_agent: pastee is not accepting messages; after it exits, resume it with spawn_subagent(resume: "+run+") and resend",
		"tool", "ask_agent", "--", "target")
	if got := h.paneText(pane); strings.Contains(got, "got: hello") {
		t.Errorf("a message to a closed inbox was pasted: %q", got)
	}

	nope := startInbox(t, "nope\n")
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("target", pane, "--inbox", nope.Path)
	h.expectKido(caller, "never pasted", nil,
		fmt.Sprintf(`kido tool message_agent: inbox %s: answered "nope", want "ok"`, nope.Path),
		"tool", "message_agent", "--", "target")
	if got := h.paneText(pane); strings.Contains(got, "never pasted") {
		t.Errorf("a message the inbox may have taken was pasted as well: %q", got)
	}
}

// A non-message kind must never fall back to a paste: a notice's text is
// model-authored, and pasted it would run as a command line in the
// parent's pane.
func TestAskReplyAndNoticeNeverPaste(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	h.programStatus(caller, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", caller, "#{pane_title}"), "π - "))
	h.agentStatus("caller", caller, "--inbox", startInbox(t, "ok\n").Path)
	pane := h.piPane("alpha", "π - victim")

	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("target", pane)
	h.expectKido(caller, "x", nil,
		"kido tool ask_agent: victim has no inbox to send a ask to; only a plain message can be sent as v0 text",
		"tool", "ask_agent", "--", "target")

	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("target", pane, "--inbox", staleSocket(t))
	for _, c := range []struct {
		env  []string
		args []string
	}{
		{nil, []string{"tool", "ask_agent", "--", "target"}},
		{nil, []string{"tool", "message_agent", "--reply-to", "ask-1", "--", "target"}},
		{[]string{"KIDO_AGENT_PARENT_SESSION=target"}, []string{"tool", "notify_parent"}},
	} {
		want := fmt.Sprintf("kido %s: victim is not accepting messages", strings.Join(c.args[:2], " "))
		h.expectKido(caller, "touch /tmp/pwned", c.env, want, c.args...)
	}

	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("target", pane, "--inbox", startInbox(t, "refused\n").Path)
	h.expectKido(caller, "touch /tmp/pwned", nil, "kido tool ask_agent: victim refused the ask", "tool", "ask_agent", "--", "target")

	if got := h.paneText(pane); strings.Contains(got, "got:") {
		t.Errorf("an ask, reply or notice was pasted into the target's pane: %q", got)
	}
}

// A steer reaches a descendant however deep; nothing reaches a peer, an
// ancestor or the caller.
func TestSteerReachesDescendantsOnly(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := startInbox(t, "ok\n")
	caller := h.firstPane("alpha")
	h.idleAgent("alpha", "root", "root", "--inbox", in.Path)
	h.programStatus(caller, "state=idle:app=pi", "caller")
	h.agentStatus("caller", caller, "--inbox", in.Path, "--parent-session", "root")
	h.idleAgent("alpha", "child", "child", "--inbox", in.Path, "--parent-session", "caller")
	h.idleAgent("alpha", "grandchild", "grandchild", "--inbox", in.Path, "--parent-session", "child")
	h.idleAgent("alpha", "peer", "peer", "--inbox", in.Path)

	for _, c := range []struct{ to, want string }{
		{"child", "delivered to child by inbox"},
		{"grandchild", "delivered to grandchild by inbox"},
		{"peer", "kido tool steer_subagent: peer is not this agent's descendant"},
		{"root", "kido tool steer_subagent: root is not this agent's descendant"},
		{"caller", "kido tool steer_subagent: caller is this agent"},
	} {
		h.expectKido(caller, "stop and do X instead", nil, c.want, "tool", "steer_subagent", "--", c.to)
	}
	got := envelopes(in)
	if len(got) != 2 {
		t.Fatalf("inboxes received %q, want the 2 steers", in.Received())
	}
	for _, e := range got {
		if field(e, "kind") != "steer" || field(e, "text") != "stop and do X instead" {
			t.Errorf("envelope %v, want a steer carrying the text", e)
		}
	}
}

// The parent is the session its environment names, even one in another
// tmux session, out of a named lookup's reach.
func TestNotifyParentReachesTheSessionItsEnvironmentNames(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	caller := h.firstPane("alpha")
	in := startInbox(t, "ok\n")
	h.idleAgent("beta", "parent-sess", "boss", "--inbox", in.Path)

	h.expectKido(caller, "the answer is 42", []string{"KIDO_AGENT_PARENT_SESSION=parent-sess"},
		"delivered to boss by inbox", "tool", "notify_parent")
	h.expectKido(caller, "nobody to tell", nil,
		"kido tool notify_parent: this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent",
		"tool", "notify_parent")
	h.expectKido(caller, "anybody there?", []string{"KIDO_AGENT_PARENT_SESSION=long-gone"},
		`kido tool notify_parent: no live process holds session "long-gone"; the parent is gone, nothing sent`,
		"tool", "notify_parent")

	got := envelopes(in)
	if len(got) != 1 || field(got[0], "kind") != "notice" || field(got[0], "text") != "the answer is 42"+parentGuidance {
		t.Errorf("parent inbox received %q, want one notice carrying the text and how to act on it", in.Received())
	}
}

// parentGuidance is what every notify_parent notice tells the parent: the
// report does not end the child, so the parent decides.
const parentGuidance = "\n\nThe child stays alive after it reports. End it with stop_run when you need nothing more from it. To continue it, use message_agent."

const maxNotice = 4000

func TestNotifyParentKeepsAReportOverTheCap(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	in := startInbox(t, "ok\n")
	h.idleAgent("alpha", "parent-sess", "parent", "--inbox", in.Path)
	const run = "run-cap-e2e"
	report := filepath.Join(h.stateDir, "runs", run, "report")
	if err := os.MkdirAll(filepath.Dir(report), 0o755); err != nil {
		t.Fatal(err)
	}
	env := func(run string) []string {
		return []string{"KIDO_AGENT_PARENT_SESSION=parent-sess", "KIDO_AGENT_RUN_ID=" + run}
	}
	notify := func(run, text string) string {
		t.Helper()
		before := len(in.Received())
		h.expectKido(caller, text, env(run), "delivered to parent by inbox", "tool", "notify_parent")
		got := envelopes(in)
		if len(got) != before+1 {
			t.Fatalf("parent inbox received %q, want one more notice", in.Received())
		}
		return field(got[before], "text")
	}

	short := "the merge is done; two conflicts, both in README.md"
	if n := notify(run, short); n != short+parentGuidance {
		t.Errorf("a report under the cap arrived as %q, want it byte for byte followed by the guidance", n)
	}
	if kept, err := os.ReadFile(report); err != nil || string(kept) != short {
		t.Errorf("a report under the cap kept %q (%v), want the whole report in %s", kept, err, report)
	}

	long := strings.Repeat("findings and more findings. ", 200) + "CONCLUSION: ship it"
	n := notify(run, long)
	kept, _ := os.ReadFile(report)
	if string(kept) != long || len(n) > maxNotice || !strings.Contains(n, "\n\nfull report: "+report) ||
		!strings.HasPrefix(n, long[:100]) || !strings.HasSuffix(n, parentGuidance) {
		t.Errorf("a report over the cap: kept %d of %d bytes, notice of %d bytes %q; want it kept whole, the notice within %d bytes, starting with the report, naming %s and ending with the guidance",
			len(kept), len(long), len(n), n, maxNotice, report)
	}

	if n := notify(run, strings.Repeat("日", 3000)); !utf8.ValidString(n) || strings.ContainsRune(n, utf8.RuneError) {
		t.Errorf("the head of a multi-byte report was not cut on a rune boundary: %q", n)
	}

	// A status notice is not a report: no guidance, no report file, and the
	// report a real one left stays as it was.
	before := len(in.Received())
	h.expectKido(caller, "idle now", env(run), "delivered to parent by inbox", "tool", "notify_parent", "--status")
	got := envelopes(in)
	if len(got) != before+1 || field(got[before], "text") != "idle now" {
		t.Errorf("a status notice arrived as %q, want the status text alone", in.Received())
	}
	if kept, _ := os.ReadFile(report); string(kept) == "idle now" {
		t.Error("a status notice replaced the run's report")
	}

	if n := notify("", strings.Repeat("x", 4500)); len(n) > maxNotice || strings.Contains(n, "full report:") || !strings.HasSuffix(n, parentGuidance) {
		t.Errorf("a report with no run is %d bytes %q, want it within %d bytes, naming no file and keeping the guidance", len(n), n, maxNotice)
	}
}

// writeRecord writes a run's record directly, and marks its pane as the
// claim does, for the fields agent-status cannot set: a chosen report time.
// Its pid is the test binary's, alive for the whole run. A "parent" in
// extra is the parent its run meta names.
func (h *harness) writeRecord(id, pane string, ts time.Time, extra map[string]any) {
	h.t.Helper()
	rec := map[string]any{"pane": pane, "pid": os.Getpid(), "ts": ts.UTC().Format("2006-01-02T15:04:05Z")}
	status, title := "idle", ""
	for k, v := range extra {
		switch k {
		case "status":
			status = v.(string)
		case "title":
			title = v.(string)
		case "parent":
		default:
			rec[k] = v
		}
	}
	parent, _ := extra["parent"].(string)
	h.agentRunMeta(id, pane, "", parent)
	if title == "" {
		title = strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - ")
	}
	state := map[string]string{"running": "working", "waiting": "blocked", "idle": "idle"}[status]
	h.programStatus(pane, "state="+state+":app=pi", title)
	b, err := json.Marshal(rec)
	if err != nil {
		h.t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(h.stateDir, "runs", id), 0o700); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(h.stateDir, "runs", id, "pi.json"), b, 0o644); err != nil {
		h.t.Fatal(err)
	}
	h.in("set-option", "-p", "-t", pane, "@kido_run", id)
	h.callers.Store(pane, id)
}

type listedAgent struct {
	ID, Name, Pane, Window, Status, Parent, Cwd, Model string
	Depth                                              int
	Self, CanMessage, CanReply, Stalled                bool
}

func parseAgents(t *testing.T, out string) []listedAgent {
	t.Helper()
	var agents []listedAgent
	if err := json.Unmarshal([]byte(out), &agents); err != nil {
		t.Fatalf("kido tool list_runs --json: %v\n%s", err, out)
	}
	return agents
}

// jsonKeys is the keys, in order, of the first agent in `kido tool list_runs
// --json`, which share/pi/kido-agents.ts reads.
func jsonKeys(t *testing.T, out string) []string {
	t.Helper()
	var agents []json.RawMessage
	if err := json.Unmarshal([]byte(out), &agents); err != nil || len(agents) == 0 {
		t.Fatalf("kido tool list_runs --json: %v\n%s", err, out)
	}
	dec := json.NewDecoder(bytes.NewReader(agents[0]))
	var keys []string
	if _, err := dec.Token(); err != nil {
		t.Fatal(err)
	}
	for dec.More() {
		k, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, k.(string))
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			t.Fatal(err)
		}
	}
	return keys
}

// The claim marks the pane it reports from and never clears a mark, so a
// session that moved leaves its old pane marked; only the pane its record
// names is its own.
func TestAStaleMarkIsNoAgent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	h.programStatus(caller, "state=idle:app=pi", "caller")
	h.agentStatus("caller", caller)
	from := h.piPane("alpha", "π - moving")
	h.agentStatus("mover", from)
	to := h.piPane("alpha", "π - moved")
	h.agentStatus("mover", to)
	if mark := h.in("display-message", "-p", "-t", from, "#{@kido_run}"); mark != "mover" {
		t.Fatalf("old pane's mark = %q, want it left as mover", mark)
	}
	out, rc := h.kidoAs(caller, "", nil, "get-agent", "--context")
	if rc != 0 {
		t.Fatalf("get-agent --context: rc=%d %s", rc, out)
	}
	var panes []string
	for _, a := range parseAgents(t, out) {
		if a.ID == "mover" {
			panes = append(panes, a.Pane)
		}
	}
	if len(panes) != 1 || panes[0] != to {
		t.Fatalf("mover's panes = %v, want only %s", panes, to)
	}
}

func TestListRunsScopesOrdersAndDecorates(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	caller := h.firstPane("alpha")
	pane := func(session string) string { return h.newWindow(session, "", "sh", "-c", "exec sleep 300") }
	t0 := time.Now().Add(-time.Hour).Truncate(time.Second)
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
	parent := func(p string) map[string]any { return map[string]any{"parent": p} }

	h.writeRecord("root", caller, at(0), map[string]any{
		"status": "running", "title": "alpha-root", "inbox": "/nonexistent.sock", "model": "m1",
	})
	child2, child1 := pane("alpha"), pane("alpha")
	h.writeRecord("child2", child2, at(2), parent("root"))
	h.writeRecord("child1", child1, at(1), parent("root"))
	h.agentRunMeta("child2", child2, "child2", "root")
	h.agentRunMeta("child1", child1, "child1", "root")
	// The session id breaks a tie in ts, so identical state always lists
	// in one order.
	h.writeRecord("ccc", pane("alpha"), at(-1), nil)
	h.writeRecord("bbb", pane("alpha"), at(-1), nil)
	// A ring of bogus parent edges is reachable from no root, and
	// list_runs is the only way to discover an agent at all: each comes
	// out once.
	h.writeRecord("cyc-a", pane("alpha"), at(3), parent("cyc-b"))
	h.writeRecord("cyc-b", pane("alpha"), at(4), parent("cyc-a"))
	h.writeRecord("selfish", pane("alpha"), at(5), parent("selfish"))
	h.writeRecord("orphan", pane("alpha"), at(6), parent("someone-else"))
	h.writeRecord("far", pane("beta"), at(0), nil)

	out, rc := h.kidoAs(caller, "", nil, "tool", "list_runs", "--json")
	if rc != 0 {
		t.Fatalf("kido tool list_runs --json: rc=%d %s", rc, out)
	}
	if got, want := strings.Join(jsonKeys(t, out), " "),
		"id name named pane window status activity parent depth self cwd canMessage canReply model sinceReport stalled kind relationship"; got != want {
		t.Errorf("list_runs --json keys = %q, want %q", got, want)
	}
	var order []string
	for _, a := range parseAgents(t, out) {
		order = append(order, a.ID+"<"+a.Parent)
		if a.ID == "root" {
			t.Error("the caller must not list itself")
		}
		if a.Self || a.CanMessage || a.CanReply {
			t.Errorf("%s = %+v, want neither self nor reachable", a.ID, a)
		}
	}
	if got, want := strings.Join(order, " "),
		"bbb< ccc< child1<root child2<root"; got != want {
		t.Errorf("list_runs order (id<parent) = %q, want %q", got, want)
	}
}

// canReply is false only for a run whose recorded tools leave out
// message_agent; --session answers from no pane at all.
func TestListRunsSessionFlagAndCanReply(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	beta := h.in("display-message", "-p", "-t", "beta:", "#{session_id}")
	t0 := time.Now().Add(-time.Hour).Truncate(time.Second)
	for i, c := range []struct {
		id    string
		tools []string
	}{
		{"no-record", nil},
		{"empty-tools", []string{}},
		{"no-message-tool", []string{"read", "bash"}},
		{"has-message-tool", []string{"read", "message_agent"}},
	} {
		h.writeRecord(c.id, h.newWindow("beta", "", "sh", "-c", "exec sleep 300"),
			t0.Add(time.Duration(i)*time.Second), map[string]any{"inbox": "/nonexistent.sock"})
		if c.tools != nil {
			meta, _ := json.Marshal(map[string]any{"id": c.id, "name": "", "kind": "agent",
				"pane": "", "pid": 0, "cwd": "", "tools": c.tools, "startedAt": "2023-11-14T22:13:20Z"})
			if err := os.WriteFile(filepath.Join(h.stateDir, "runs", c.id, "meta.json"), meta, 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	h.writeRecord("here", h.firstPane("alpha"), t0, nil)

	out, rc := h.kidoAs("", "", nil, "tool", "list_runs", "--json", "--session", beta)
	if rc != 0 {
		t.Fatalf("kido tool list_runs --session %s from no pane: rc=%d %s", beta, rc, out)
	}
	var got []string
	for _, a := range parseAgents(t, out) {
		got = append(got, fmt.Sprintf("%s:%v", a.ID, a.CanReply))
	}
	if want := "no-record:true empty-tools:true no-message-tool:false has-message-tool:true"; strings.Join(got, " ") != want {
		t.Errorf("list_runs --session %s = %q, want %q", beta, strings.Join(got, " "), want)
	}

	h.expectKido("", "", nil,
		"kido tool list_runs: no tmux session for pane \"\"; pass --session\nusage: kido tool list_runs [--session ID] [--json]",
		"tool", "list_runs", "--json")
	// get-agent --context shares the refusal but not list_runs' usage line.
	h.expectKido("", "", nil,
		"kido get-agent: no tmux session for pane \"\"; pass --session",
		"get-agent", "--context")
}

// A plain message to a running agent waits for its turn to end, so the
// line says so rather than "delivered"; the steer_subagent hint goes only
// to a caller that could steer the target. A reply goes to an asker that
// reports running while its ask blocks, and is read at once.
func TestMessageAgentSaysAMessageToARunningAgentWaits(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := startInbox(t, "ok\n")
	caller := h.firstPane("alpha")
	h.programStatus(caller, "state=idle:app=pi", "caller")
	h.agentStatus("caller", caller, "--inbox", in.Path)
	h.idleAgent("alpha", "idle-child", "idle-child", "--inbox", in.Path, "--parent-session", "caller")
	busy := func(id, status string, extra ...string) {
		p := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
		h.in("select-pane", "-t", p, "-T", "")
		h.programStatus(p, "state="+status+":app=pi", id)
		h.agentStatus(id, p, append([]string{"--inbox", in.Path}, extra...)...)
	}
	busy("busy-peer", "working")
	busy("busy-child", "working", "--parent-session", "caller")
	busy("working-grandchild", "working", "--parent-session", "busy-child")

	for _, c := range []struct{ to, want string }{
		{"idle-child", "delivered to idle-child by inbox"},
		{"busy-peer", "queued for busy-peer: it is running and reads this when its current turn ends"},
		{"busy-child", "queued for busy-child: it is running and reads this when its current turn ends; to reach it now, use steer_subagent"},
		{"working-grandchild", "queued for working-grandchild: it is running and reads this when its current turn ends; to reach it now, use steer_subagent"},
	} {
		h.expectKido(caller, "new evidence", nil, c.want, "tool", "message_agent", "--", c.to)
	}
	h.expectKido(caller, "the answer", nil, "delivered to busy-peer by inbox", "tool", "message_agent", "--reply-to", "ask-1", "--", "busy-peer")
	h.expectKido(caller, "a question", nil, "delivered to busy-peer by inbox", "tool", "ask_agent", "--", "busy-peer")
}
