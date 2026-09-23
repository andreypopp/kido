package ui

import (
	"strings"
	"testing"
	"time"

	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
)

const sshHost = "deploy@build-box"

// sshModel is a model with one interactive ssh pane and a clock the test
// drives, the same shape TestShellIndicator uses.
func sshModel(clock *time.Time) *model {
	base := *clock
	return &model{
		// started well before the run, so a command finishing while the
		// user is elsewhere counts as unseen and leaves an outcome.
		started:   base.Add(-time.Hour),
		seen:      map[string]time.Time{},
		phases:    map[string]shellPhase{},
		sshRemote: map[string]bool{},
		now:       func() time.Time { return *clock },
	}
}

// sshPane is the local pane's view of an ssh session: prompt and command
// timestamps as tmux reports them, in whole seconds.
func sshPane(prompt, start int64, running bool, status int) tmux.Pane {
	p := tmux.Pane{
		SessionName: "alpha", WindowID: "@1", PaneID: "%1",
		CurrentCommand: "ssh", PanePID: 4242,
		LastPromptTime: prompt, CommandStartTime: start, CommandRunning: running,
	}
	if !running && status >= 0 {
		p.CommandStatusOK, p.CommandEndTime = true, start+1
		p.CommandStatus = status
	}
	return p
}

func (m *model) sshTick(p tmux.Pane) {
	m.at = m.now()
	m.snap = snapshot{
		current: "alpha", panes: []tmux.Pane{p},
		ssh: map[int]procs.SSHSession{
			p.PanePID: {Host: sshHost, Interactive: true},
		},
	}
	m.track()
}

// TestSSHRemoteShellReports drives the gate over one ssh session whose far
// side has kido's integration: the remote shell's own OSC 133 markers land
// on the local pane, so once a prompt has been marked after the ssh
// started the row reports remote commands like any other integrated shell
// - while still naming the destination.
func TestSSHRemoteShellReports(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := sshModel(&clock)

	// The local shell marked its prompt, then marked ssh as started.
	// Nothing has come back from the far side yet.
	m.sshTick(sshPane(base.Unix()-1, base.Unix(), true, -1))
	if !m.interactivePane(m.snap.panes[0]) {
		t.Fatal("a bare ssh with no reply from the far side is not interactive")
	}
	if got := m.paneLabel(m.snap.panes[0]); strings.Contains(got, indicator(state.Running)) {
		t.Errorf("label = %q, want no running indicator before the far side reports", got)
	}

	// The remote shell's first prompt: 133;A after the ssh started.
	clock = clock.Add(time.Second)
	idle := sshPane(base.Unix()+1, base.Unix(), false, -1)
	m.sshTick(idle)
	if m.interactivePane(idle) {
		t.Fatal("a reporting far side must not be suppressed")
	}
	if got := m.paneLabel(idle); !strings.Contains(got, sshHost) {
		t.Errorf("label = %q, want the destination kept", got)
	}

	// A remote command starts. Its own 133;C overwrites the ssh launch's
	// start time, so only the latch tells this from the pane above.
	clock = clock.Add(time.Second)
	run := sshPane(base.Unix()+1, base.Unix()+2, true, -1)
	m.sshTick(run)
	if m.interactivePane(run) {
		t.Fatal("the far side's reporting must survive its own command starting")
	}
	clock = clock.Add(shellRunDelay)
	m.sshTick(run)
	if got := m.shellIndicator(m.phases["%1"]); got != indicator(state.Running) {
		t.Errorf("indicator = %q, want running during a remote command", got)
	}

	// It finishes cleanly, with the user elsewhere.
	clock = clock.Add(time.Second)
	done := sshPane(base.Unix()+4, base.Unix()+2, false, 0)
	m.sshTick(done)
	if got := m.shellIndicator(m.phases["%1"]); got != indicatorDone() {
		t.Errorf("indicator = %q, want done after the remote command", got)
	}
}

// TestSSHWithoutRemoteIntegrationStaysQuiet is the negative control: a far
// side that never marks a prompt leaves the local pane reporting a command
// that has run since the ssh started and never ends, which is exactly the
// permanently-busy row the suppression exists for.
func TestSSHWithoutRemoteIntegrationStaysQuiet(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := sshModel(&clock)
	// The prompt before the ssh and the ssh itself land in the same
	// second, which is as close as tmux's whole-second timestamps can put
	// them.
	p := sshPane(base.Unix(), base.Unix(), true, -1)
	for range 10 {
		clock = clock.Add(time.Second)
		m.sshTick(p)
		if !m.interactivePane(p) {
			t.Fatal("a far side with no integration must stay suppressed")
		}
		if got := m.shellIndicator(m.phases["%1"]); got != "" {
			t.Fatalf("indicator = %q, want none", got)
		}
	}
}

// TestSSHRemoteSameSecondPrompt pins the cost of reading the prompt time
// strictly: a connection fast enough to reach its first remote prompt in
// the second the ssh started in says nothing tmux can report, so that
// session's first command is still suppressed - and the prompt after it
// lands in a later second and reports from there on.
//
// The alternative, accepting a prompt marked in that same second, would
// latch on every ssh to a host with no integration at all: its local
// prompt and its ssh share a second just as readily, and the row would
// then be green for as long as the connection lasted.
func TestSSHRemoteSameSecondPrompt(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := sshModel(&clock)

	// Prompt and ssh in one second, then the far side's first prompt,
	// which carries that same second.
	start := sshPane(base.Unix(), base.Unix(), true, -1)
	m.sshTick(start)
	clock = clock.Add(300 * time.Millisecond)
	m.sshTick(start)
	if !m.interactivePane(start) {
		t.Fatal("a prompt in the ssh's own second must not be read as the far side")
	}

	// The first remote command, and the prompt that follows it a second
	// later: from here the pane reports.
	clock = clock.Add(time.Second)
	m.sshTick(sshPane(base.Unix(), base.Unix()+1, true, -1))
	clock = clock.Add(time.Second)
	after := sshPane(base.Unix()+2, base.Unix()+1, false, 0)
	m.sshTick(after)
	if m.interactivePane(after) {
		t.Fatal("the prompt after the first remote command must be read as the far side")
	}
}

// TestSSHRemoteLatchDropped pins the latch's lifetime: it is a reading of
// one ssh session, so a pane that has gone back to its local shell - or
// started a second ssh to a host with no integration - is judged again
// from nothing.
func TestSSHRemoteLatchDropped(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := sshModel(&clock)
	m.sshTick(sshPane(base.Unix()+1, base.Unix(), false, -1))
	if !m.sshRemote["%1"] {
		t.Fatal("the far side's prompt was not latched")
	}

	// The ssh exited: the pane is a local shell again.
	clock = clock.Add(time.Second)
	m.at = m.now()
	m.snap = snapshot{current: "alpha", panes: []tmux.Pane{{
		SessionName: "alpha", WindowID: "@1", PaneID: "%1",
		CurrentCommand: "zsh", PanePID: 4242,
		LastPromptTime: base.Unix() + 2,
	}}}
	m.track()
	if m.sshRemote["%1"] {
		t.Fatal("the latch outlived the ssh session it was read from")
	}

	// A second ssh, this one to a host that reports nothing.
	clock = clock.Add(time.Second)
	next := sshPane(base.Unix()+2, base.Unix()+3, true, -1)
	m.sshTick(next)
	if !m.interactivePane(next) {
		t.Fatal("a second ssh inherited the first one's reading")
	}
}

// TestSSHRemoteForgetsDeadPanes is the garbage collection phases has: a
// latch is dropped when its pane is gone.
func TestSSHRemoteForgetsDeadPanes(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := sshModel(&clock)
	m.sshTick(sshPane(base.Unix()+1, base.Unix(), false, -1))
	if len(m.sshRemote) != 1 {
		t.Fatalf("sshRemote = %v, want the pane latched", m.sshRemote)
	}
	m.snap = snapshot{panes: nil}
	m.track()
	if len(m.sshRemote) != 0 {
		t.Errorf("sshRemote = %v, want empty after the pane is gone", m.sshRemote)
	}
}
