package e2e

import (
	"fmt"
	"strings"
	"testing"
)

func TestRpcPrompt(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	same := h.agentPaneHere("alpha:", "✳ Same")
	other := h.promptPane("alpha", "✳ Other")
	h.subagentWindow("alpha", "excluded", "excluded-e2e", "")
	plain := h.newWindow("alpha", "plain")
	session := h.in("display-message", "-p", "-t", caller, "#{session_id}")
	callerWindow := h.windowID(caller)
	otherWindow := h.windowID(other)

	f := h.startFeed("alpha")

	f.send(fmt.Sprintf(`{"id":1,"prompt":{"pane":%q}}`, caller))
	f.waitReply(fmt.Sprintf(
		`{"reply":{"id":1,"prompt":{"candidates":[{"pane":%q,"session":%q,"window":%q,"title":%q},{"pane":%q,"session":%q,"window":%q,"title":%q}]}}}`,
		same, session, callerWindow, "✳ Same",
		other, session, otherWindow, "✳ Other"))

	f.send(fmt.Sprintf(`{"id":2,"prompt":{"pane":%q,"target":%q,"text":"hello-paste"}}`, caller, same))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":2,"prompt":{"delivered":{"pane":%q,"via":"paste"}}}}`, same))
	h.waitPaneText(same, "got: hello-paste")

	in := startInbox(t, "ok\n")
	inboxPane := h.piPane("alpha", "✳ Inbox")
	h.setPiOptions(inboxPane, "prompt-inbox-e2e", "✳ Inbox", in.Path, "")
	f.send(fmt.Sprintf(`{"id":3,"prompt":{"pane":%q,"target":%q,"text":"hello-inbox"}}`, caller, inboxPane))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":3,"prompt":{"delivered":{"pane":%q,"via":"inbox"}}}}`, inboxPane))
	h.waitInbox(in, "hello-inbox")

	f.send(fmt.Sprintf(`{"id":4,"prompt":{"pane":%q,"target":%q,"text":"not-a-candidate"}}`, caller, plain))
	f.waitReply(fmt.Sprintf(
		`{"reply":{"id":4,"error":"pane \"%s\" is not a candidate of pane \"%s\"","kind":"invalid"}}`,
		plain, caller))

	f.send(fmt.Sprintf(`{"id":5,"prompt":{"pane":%q,"target":%q,"text":""}}`, caller, same))
	f.waitReply(`{"reply":{"id":5,"error":"no prompt given","kind":"invalid"}}`)

	refused := h.promptPane("alpha", "✳ Refused")
	h.setPiOptions(refused, "prompt-"+refused, h.paneTitle(refused), staleSocket(t), "")
	f.send(fmt.Sprintf(`{"id":6,"prompt":{"pane":%q,"target":%q,"text":"must-not-arrive"}}`, caller, refused))
	f.waitReply(fmt.Sprintf(
		`{"reply":{"id":6,"error":"%s is not accepting messages","kind":"refused"}}`,
		"✳ Refused"))
	if got := h.paneText(refused); strings.Contains(got, "got: must-not-arrive") {
		t.Errorf("a refused prompt was pasted into %s: %q", refused, got)
	}
}
