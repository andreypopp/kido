package e2e

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func (h *harness) agentRunMeta(id, pane, name, parent string) {
	h.t.Helper()
	dir := filepath.Join(h.stateDir, "runs", id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		h.t.Fatal(err)
	}
	meta, err := json.Marshal(map[string]any{
		"id": id, "name": name, "kind": "agent", "parentSession": parent,
		"depth": 1, "pane": pane, "pid": os.Getpid(), "cwd": h.dir,
		"startedAt": time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "meta.json"), meta, 0o644); err != nil {
		h.t.Fatal(err)
	}
}

// wedgedChild's inbox answers "ok" to anything and does nothing else: a
// pi extension that received the request but never acted on it, wedged
// the way a real one was once observed for hours after a laptop slept
// and its provider connection died.
func (h *harness) wedgedChild(session, sessionID string) (paneID, windowID string, in *inbox) {
	h.t.Helper()
	in, paneID = h.agentWithInbox(session, sessionID)
	h.agentRunMeta(sessionID, paneID, sessionID, "")
	return paneID, h.windowID(paneID), in
}

// A target that acknowledges the stop over its inbox but never actually
// goes is exactly the case Control.stop's escalation exists for.
func TestStopKillsAWedgedChildAfterEscalation(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	_, windowID, _ := h.wedgedChild("alpha", "wedged-e2e")

	out := h.runKido("alpha", "stop.out", "tool", "stop_run", "wedged-e2e")
	if !strings.Contains(out, "killed") {
		t.Errorf("kido tool stop_run output = %q, want it to say the window was killed", out)
	}
	if !strings.Contains(out, "rc=0") {
		t.Errorf("kido tool stop_run output = %q, want a successful exit: the escalation itself is not a failure", out)
	}
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be killed after the escalation timeout", windowID))
}

// Negative control: a target whose record goes away shortly after being
// asked to stop, standing in for pi's session_shutdown handler removing
// it, must never have its window killed.
func TestStopDoesNotKillAHealthyChild(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID, windowID, in := h.wedgedChild("alpha", "healthy-e2e")

	// in.Received() gates removal of the record on the stop request reaching
	// the target, avoiding a race with the freshly created window's startup.
	go func() {
		deadline := time.Now().Add(settle)
		for len(in.Received()) == 0 && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond)
		}
		h.agentStatus("healthy-e2e", paneID, "pi", "--remove")
	}()

	out := h.runKido("alpha", "stop.out", "tool", "stop_run", "healthy-e2e")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido tool stop_run output = %q, want a successful exit", out)
	}
	if strings.Contains(out, "killed") {
		t.Errorf("kido tool stop_run output = %q, want no escalation: the target stopped in time", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"a healthy child's window must never be killed")
}

// recordedRun spawns a run whose pane records itself as the agent of the
// run's own session id, the way pi's extension does, with flags passed to
// its `kido agent-status` (an --inbox, say).
func (h *harness) recordedRun(name string, flags ...string) (runID, windowID string) {
	h.t.Helper()
	title := name
	var args []string
	for i := 0; i < len(flags); i++ {
		if flags[i] == "--title" {
			i++
			title = flags[i]
		} else {
			args = append(args, flags[i])
		}
	}
	runID, windowID = h.spawnRun(name, fmt.Sprintf(
		`printf "\033]7501;state=idle:app=pi:title=%s\007"; %s agent-status --agent pi --session "$KIDO_AGENT_RUN_ID" --parent-session root-e2e %s; exec sleep 300`,
		base64.StdEncoding.EncodeToString([]byte(title)), kidoBin, strings.Join(args, " ")))
	record := filepath.Join(h.stateDir, runID+".json")
	h.waitFor(func() bool { _, err := os.Stat(record); return err == nil }, settle,
		msgf("run %s's own record %s", runID, record))
	return runID, windowID
}

// staleInbox is a socket path nothing listens on any more.
func staleInbox(t *testing.T) string {
	t.Helper()
	path := filepath.Join(socketDir(t), "stale.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	ln.Close()
	return path
}

// A stop that cannot ask (no inbox, or one nobody answers on) needs
// --force, and until given it touches nothing: the outcome is written once
// and for all, so it must not be written by a refusal. Forced, it kills
// the target's pane alone, never a pane the user split beside it.
func TestStopWithNoWayToAskNeedsForce(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	for _, c := range []struct {
		name, refusal string
		flags         []string
	}{
		{"mute-e2e", "has no inbox to ask nicely over; pass --force to kill its window instead", nil},
		{"stale-e2e", "could not be asked to stop (", []string{"--inbox", staleInbox(t)}},
	} {
		runID, windowID := h.recordedRun(c.name, c.flags...)
		paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
		bystander := h.in("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", windowID, "sh", "-c", "exec sleep 300")
		h.programStatus(bystander, "state=idle:app=pi", runID)
		h.agentStatus("decoy-"+c.name, bystander, "pi")

		out := h.runKido("alpha", c.name+"-unforced.out", "tool", "stop_run", runID)
		if !strings.Contains(out, c.refusal) || !strings.Contains(out, "pass --force") || !strings.Contains(out, "rc=1") {
			t.Errorf("%s: stop without --force = %q, want rc=1 and %q", c.name, out, c.refusal)
		}
		if got := h.runOutcomeNamed(c.name+"-unforced", runID); got != "running" || !h.paneExists(paneID) {
			t.Errorf("%s: after a refused stop outcome = %q, pane there = %v; want running and untouched", c.name, got, h.paneExists(paneID))
		}

		out = h.runKido("alpha", c.name+"-forced.out", "tool", "stop_run", "--force", runID)
		if !strings.Contains(out, "'s pane") || !strings.Contains(out, "rc=0") {
			t.Errorf("%s: stop --force = %q, want its pane killed and rc=0", c.name, out)
		}
		h.waitFor(func() bool { return !h.paneExists(paneID) }, settle, msgf("%s's pane %s to be killed", c.name, paneID))
		if !h.paneExists(bystander) || !h.windowExists(windowID) {
			t.Errorf("%s: the user's split %s or its window %s went with the target's pane", c.name, bystander, windowID)
		}
		if got := h.runOutcomeNamed(c.name+"-forced", runID); got != "stopped" {
			t.Errorf("%s: outcome after stop --force = %q, want stopped", c.name, got)
		}
	}
}

// interrupt_subagent and stop_run reach an agent's descendants only;
// a human's shell, being nobody's descendant, reaches anyone in its own
// tmux session and no further.
func TestInterruptAndStopReachOnlyDescendants(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	caller := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(caller, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", caller, "#{pane_title}"), "π - "))
	h.agentStatus("caller-e2e", caller, "pi")
	h.agentRunMeta("caller-e2e", caller, "caller-e2e", "")
	agent := func(session, id string, flags ...string) *inbox {
		in := startInbox(t, "ok\n")
		pane := h.newWindow(session, "", "sh", "-c", "exec sleep 300")
		h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
		h.agentStatus(id, pane, "pi", append([]string{"--inbox", in.Path}, flags...)...)
		h.agentRunMeta(id, pane, id, "")
		return in
	}
	child := agent("alpha", "child-e2e", "--parent-session", "caller-e2e")
	peer := agent("alpha", "peer-e2e")

	for i, c := range []struct{ verb, target, want string }{
		{"interrupt_subagent", "peer-e2e", "is not this agent's descendant\nrc=1"},
		{"interrupt_subagent", "caller-e2e", "is this agent\nrc=1"},
		{"stop_run", "peer-e2e", "is not this agent's descendant\nrc=1"},
		{"stop_run", "caller-e2e", "is this agent\nrc=1"},
		{"interrupt_subagent", "child-e2e", "\nrc=0"},
	} {
		out := h.typeScript(caller, fmt.Sprintf("reach-%d.out", i), kidoBin+" tool "+c.verb+" "+c.target)
		if !strings.Contains(out, c.want) {
			t.Errorf("%s %s from caller-e2e = %q, want %q", c.verb, c.target, out, c.want)
		}
	}
	if got := child.Received(); len(got) != 1 || !strings.Contains(got[0], `"kind":"interrupt"`) {
		t.Errorf("child's inbox = %q, want the one interrupt", got)
	}
	h.stableCount(peer, 0, "nothing may reach a peer that is not the caller's descendant")

	if out := h.runKido("alpha", "human.out", "tool", "interrupt_subagent", "peer-e2e"); !strings.Contains(out, "rc=0") {
		t.Errorf("interrupt_subagent peer-e2e from a human's shell = %q, want rc=0", out)
	}
	if got := peer.Received(); len(got) != 1 || !strings.Contains(got[0], `"kind":"interrupt"`) {
		t.Errorf("peer's inbox = %q, want the one interrupt the human sent", got)
	}

	h.newSession("beta")
	agent("beta", "elsewhere-e2e")
	if out := h.runKido("alpha", "elsewhere.out", "tool", "interrupt_subagent", "elsewhere-e2e"); !strings.Contains(out, "is in another tmux session, not this one") || !strings.Contains(out, "rc=1") {
		t.Errorf("interrupt_subagent into another tmux session = %q, want a refusal naming it", out)
	}
}

// Every way a target can take a stop request without going still ends in
// its pane killed, and the message says which way it was.
func TestStopSaysWhyItKilledAnUnwillingTarget(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	for _, c := range []struct{ id, reply, why string }{
		{"refuser-e2e", "refused\n", "refused the stop)"},
		{"mumbler-e2e", "what?\n", `answered "what?", want "ok")`},
		{"silent-e2e", "", "timed out)"},
	} {
		in := startInbox(t, c.reply)
		pane := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
		windowID := h.windowID(pane)
		h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
		h.agentStatus(c.id, pane, "pi", "--inbox", in.Path)
		h.agentRunMeta(c.id, pane, c.id, "")
		out := h.runKido("alpha", c.id+".out", "tool", "stop_run", c.id)
		for _, want := range []string{"did not accept the stop request (", c.why, "and was still there after 300ms; killed its pane", "rc=0"} {
			if !strings.Contains(out, want) {
				t.Errorf("stop_run %s = %q, want %q", c.id, out, want)
			}
		}
		h.waitFor(func() bool { return !h.windowExists(windowID) }, settle, msgf("%s's window %s to be killed", c.id, windowID))
	}
}

// A bash run is stopped through its wrapper pid; it is found
// through the parent in its meta, a finished one is no match, and a name
// two running runs share names neither. When its pane cannot be killed
// the stop is still recorded and its parent still told.
func TestStopBashRunFindsItsRunAndSpeaksForIt(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	in := startInbox(t, "ok\n")
	h.programStatus(caller, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", caller, "#{pane_title}"), "π - "))
	h.agentStatus("caller-e2e", caller, "pi", "--inbox", in.Path)
	shellAgent := func(id string, flags ...string) string {
		pane := h.newWindow("alpha", "")
		h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
		h.agentStatus(id, pane, "pi", append([]string{"--inbox", startInbox(t, "ok\n").Path}, flags...)...)
		return pane
	}
	started := 0
	runIn := func(pane, name string, command ...string) string {
		// Numbered, not named: "twin" and "Twin" are one file on macOS.
		started++
		out := h.typeScript(pane, fmt.Sprintf("start-%d.out", started), fmt.Sprintf("%s tool async_bash --name %s -- %s", kidoBin, name, strings.Join(command, " ")))
		if f := strings.Fields(out); len(f) == 5 {
			return f[2]
		}
		t.Fatalf("async_bash %s = %q", name, out)
		return ""
	}
	stop := func(tag string, args ...string) string {
		return h.typeScript(caller, tag+".out", kidoBin+" tool stop_run "+strings.Join(args, " "))
	}

	doomed := runIn(caller, "doomed", "sleep", "300")
	if out := stop("doomed", "@"+doomed[:8]); !strings.Contains(out, `stopped async run "doomed"`) || !strings.Contains(out, "rc=0") {
		t.Errorf("stop by @id prefix = %q, want success without --force", out)
	}
	if got := h.runInfo(doomed); got.Outcome != "stopped" || got.OutcomeText != "stopped by its parent" {
		t.Errorf("run doomed = %+v, want stopped by its parent", got)
	}

	peer := shellAgent("peer-e2e")
	stranger := runIn(peer, "stranger", "sleep", "300")
	if out := stop("stranger", "--force", "stranger"); !strings.Contains(out, `async run "stranger" is not this agent's descendant`) || !strings.Contains(out, "rc=1") {
		t.Errorf("stop of a peer's run = %q, want it refused", out)
	}
	if got := h.runInfo(stranger).Outcome; got != "running" {
		t.Errorf("run stranger outcome = %q, want running", got)
	}
	child := shellAgent("child-e2e", "--parent-session", "caller-e2e")
	runIn(child, "mine", "sleep", "300")
	if out := stop("mine", "--force", "mine"); !strings.Contains(out, `stopped async run "mine"`) || !strings.Contains(out, "rc=0") {
		t.Errorf("stop of a child's run = %q, want it stopped", out)
	}

	twin := shellAgent("twin-agent", "--parent-session", "caller-e2e")
	h.agentRunMeta("twin-agent", twin, "Twin", "caller-e2e")
	twins := []string{runIn(caller, "twin", "sleep", "300"), "twin-agent"}
	sort.Strings(twins)
	want := fmt.Sprintf(`"twin" matches several runs: %s, %s`, twins[0], twins[1])
	if out := stop("twin", "--force", "twin"); !strings.Contains(out, want) || !strings.Contains(out, "rc=1") {
		t.Errorf("stop twin = %q, want %q", out, want)
	}

	finished := runIn(caller, "child-e2e", "true")
	h.waitOutcome(finished)
	if out := stop("finished", finished); !strings.Contains(out, "has already ended") || !strings.Contains(out, "rc=1") {
		t.Errorf("stop ended run = %q, want a refusal", out)
	}

	// The run's window moved into a session of its own, its only pane: the
	// stop records the ending and tells the parent, but may not kill it.
	alone := runIn(caller, "alone", "sleep", "300")
	h.hideSidebar()
	h.killWrapper(alone)
	h.in("new-session", "-d", "-s", "lonely", "sh", "-c", "exec sleep 300")
	first := h.in("list-windows", "-t", "lonely", "-F", "#{window_id}")
	h.in("move-window", "-s", h.windowID(h.in("list-panes", "-a", "-F", "#{pane_id}", "-f", "#{==:#{@kido_run},"+alone+"}")), "-t", "lonely:")
	h.in("kill-window", "-t", first)
	before := len(in.Received())
	out := stop("alone", "--force", "alone")
	if !strings.Contains(out, `async run "alone" was recorded stopped, but its pane could not be killed: it is its session's only pane; killing it would destroy the session`) || !strings.Contains(out, "rc=1") {
		t.Errorf("stop of a session's only pane = %q, want it recorded but refused", out)
	}
	if info := h.runInfo(alone); info.Outcome != "stopped" || info.OutcomeText != "stopped by its parent" {
		t.Errorf("run alone = %q/%q, want the stop recorded", info.Outcome, info.OutcomeText)
	}
	h.waitFor(func() bool { return len(in.Received()) > before }, settle, msgf("the parent to be told run alone was stopped"))
	if got := in.Received()[before]; !strings.Contains(got, `async run \"alone\" stopped`) {
		t.Errorf("notice = %q, want it to say run alone was stopped", got)
	}
}
