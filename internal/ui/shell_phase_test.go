package ui

import (
	"strings"
	"testing"
	"time"

	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
)

// TestShellIndicator drives the running indicator's debounce on a
// controlled clock: each step says what tmux reports of the pane and how
// much time has passed since the last one, and asserts what the row draws
// and whether the model still wants a rebuild on the next quiet tick.
//
// tmux's own timestamps are whole seconds, so none of this can be read off
// them; what is being tested is kido's observation of the pane, which is
// why the steps are milliseconds apart and the pane fields barely move.
func TestShellIndicator(t *testing.T) {
	const (
		idle = -1 // no command has finished in this pane yet
		ok   = 0
		fail = 1
	)
	type step struct {
		adv     int    // milliseconds since the previous step
		run     bool   // tmux reports a command running
		stat    int    // exit status of the last finished command
		want    string // the indicator drawn, "" for none
		pending bool   // a later tick could change the row by itself
	}
	for _, tc := range []struct {
		name string
		// onPane puts the client in this pane, which is what makes
		// shellOutcome find nothing (a command finishing under the user's
		// eyes is never "since the last visit") and so lets the hold show.
		onPane bool
		steps  []step
	}{{
		// 50ms of running never reaches the screen, and with the user in
		// the pane the outcome does not either: the row never changes.
		name:   "short command draws nothing",
		onPane: true,
		steps: []step{
			{adv: 0, stat: idle},
			{adv: 50, run: true, stat: idle, pending: true},
			{adv: 50, run: true, stat: idle, pending: true},
			{adv: 50, stat: ok},
		},
	}, {
		// A second of running: green after 200ms, held for 500ms once it
		// stops, then blank.
		name:   "long command draws running, then holds",
		onPane: true,
		steps: []step{
			{adv: 0, stat: idle},
			{adv: 100, run: true, stat: idle, pending: true},
			{adv: 100, run: true, stat: idle, pending: true},
			{adv: 100, run: true, stat: idle, want: "running"},
			{adv: 700, run: true, stat: idle, want: "running"},
			{adv: 100, stat: ok, want: "running", pending: true},
			{adv: 400, stat: ok, want: "running", pending: true},
			{adv: 100, stat: ok},
		},
	}, {
		// The user is elsewhere, so the checkmark is there the tick the
		// command ends: no hold, no delay.
		name: "clean exit elsewhere replaces the green at once",
		steps: []step{
			{adv: 0, stat: idle},
			{adv: 100, run: true, stat: idle, pending: true},
			{adv: 300, run: true, stat: idle, want: "running"},
			{adv: 100, stat: ok, want: "done", pending: true},
			{adv: 500, stat: ok, want: "done"},
		},
	}, {
		name: "failed exit elsewhere replaces the green at once",
		steps: []step{
			{adv: 0, stat: idle},
			{adv: 100, run: true, stat: idle, pending: true},
			{adv: 300, run: true, stat: idle, want: "running"},
			{adv: 100, stat: fail, want: "failed", pending: true},
			{adv: 500, stat: fail, want: "failed"},
		},
	}, {
		// Two commands typed back to back: the second starts while the
		// first one's hold is still green, inherits it, and the row stays
		// green throughout rather than blanking for 200ms in between.
		name:   "a second command inside the hold keeps the green",
		onPane: true,
		steps: []step{
			{adv: 0, stat: idle},
			{adv: 100, run: true, stat: idle, pending: true},
			{adv: 300, run: true, stat: idle, want: "running"},
			{adv: 100, stat: ok, want: "running", pending: true},
			{adv: 100, run: true, stat: ok, want: "running"},
			{adv: 50, stat: ok, want: "running", pending: true},
			{adv: 500, stat: ok},
		},
	}, {
		// Once the hold has expired the next run is on its own again and
		// has to last 200ms like any other.
		name:   "a command after the hold starts blank again",
		onPane: true,
		steps: []step{
			{adv: 0, stat: idle},
			{adv: 100, run: true, stat: idle, pending: true},
			{adv: 300, run: true, stat: idle, want: "running"},
			{adv: 100, stat: ok, want: "running", pending: true},
			{adv: 600, stat: ok},
			{adv: 100, run: true, stat: ok, pending: true},
			{adv: 200, run: true, stat: ok, want: "running"},
		},
	}, {
		// A pane the user is not watching already wears a checkmark when
		// the next command starts. tmux clears the exit status on 133;C
		// (stat goes back to idle below), so the outcome is unreadable
		// from the moment the command starts: the row must keep showing
		// it until the new run is drawn rather than blanking for 200ms.
		name: "a new command keeps the outcome until it is drawn",
		steps: []step{
			{adv: 0, stat: idle},
			{adv: 100, run: true, stat: idle, pending: true},
			{adv: 300, run: true, stat: idle, want: "running"},
			{adv: 100, stat: ok, want: "done", pending: true},
			{adv: 600, stat: ok, want: "done"},
			{adv: 100, run: true, stat: idle, want: "done", pending: true},
			{adv: 200, run: true, stat: idle, want: "running"},
		},
	}} {
		t.Run(tc.name, func(t *testing.T) {
			const pane = "%1"
			base := time.Unix(1700000000, 0)
			clock := base
			m := &model{
				// started well before the run, so a command finishing
				// while the user is elsewhere counts as unseen.
				started: base.Add(-time.Hour),
				seen:    map[string]time.Time{},
				phases:  map[string]shellPhase{},
				now:     func() time.Time { return clock },
			}
			for i, s := range tc.steps {
				clock = clock.Add(time.Duration(s.adv) * time.Millisecond)
				p := tmux.Pane{
					PaneID: pane,
					// Non-zero: the shell has the OSC 133 integration.
					LastPromptTime: base.Unix() - 1,
					CommandRunning: s.run,
					// Whole seconds, as tmux reports them: every step of
					// this test lands in the same one.
					CommandStartTime: base.Unix(),
					CommandStatusOK:  s.stat >= 0,
					CommandEndTime:   clock.Unix(),
				}
				if s.stat > 0 {
					p.CommandStatus = s.stat
				}
				if s.stat < 0 {
					p.CommandEndTime = 0
				}
				m.at = m.now()
				m.snap = snapshot{panes: []tmux.Pane{p}}
				if tc.onPane {
					m.snap.active = pane
				}
				m.track()
				want := ""
				switch s.want {
				case "running":
					want = indicator(state.Running)
				case "done":
					want = indicatorDone()
				case "failed":
					want = indicatorFailed()
				}
				if got := m.shellIndicator(m.phases[p.PaneID]); got != want {
					t.Errorf("step %d (+%dms): indicator = %q, want %q (%s)",
						i, s.adv, got, want, s.want)
				}
				if got := m.shellPending(); got != s.pending {
					t.Errorf("step %d (+%dms): pending = %v, want %v",
						i, s.adv, got, s.pending)
				}
			}
		})
	}
}

// TestShellPhaseForgetsDeadPanes checks the garbage collection: a phase is
// dropped when its pane is gone, the way seen is, so a long-lived sidebar
// does not accumulate one record per pane ever opened.
func TestShellPhaseForgetsDeadPanes(t *testing.T) {
	now := time.Unix(1700000000, 0)
	m := &model{
		started: now, seen: map[string]time.Time{},
		phases: map[string]shellPhase{},
		now:    func() time.Time { return now },
	}
	m.at = m.now()
	m.snap = snapshot{active: "%1", panes: []tmux.Pane{
		{PaneID: "%1", LastPromptTime: now.Unix(), CommandRunning: true,
			CommandStartTime: now.Unix()},
	}}
	m.track()
	if _, ok := m.phases["%1"]; !ok {
		t.Fatal("no phase recorded for the running pane")
	}
	m.snap = snapshot{panes: nil}
	m.track()
	if len(m.phases) != 0 {
		t.Errorf("phases = %v, want empty after the pane is gone", m.phases)
	}
}

// TestShellDebounceRedraws drives Update with a snapshot that never
// changes, which is what a pane sitting on one long command looks like to
// tmux, and expects the row to pick up the delay and the hold anyway.
//
// This is the regression the shellPending gate exists for: with the gate
// gone (or read after the tick instead of before it) every assertion below
// still describes a correct shellIndicator, and the row freezes on screen
// because rebuild is never called.
func TestShellDebounceRedraws(t *testing.T) {
	const pane = "%1"
	base := time.Unix(1700000000, 0)
	clock := base
	m := model{
		started: base.Add(-time.Hour),
		seen:    map[string]time.Time{},
		phases:  map[string]shellPhase{},
		now:     func() time.Time { return clock },
	}
	m.at = m.now()

	// The client sits in the pane, so a finished command leaves no
	// outcome and the hold is what the row shows.
	snap := func(running bool) snapshot {
		p := tmux.Pane{
			SessionName: "alpha", WindowID: "@1", PaneID: pane,
			CurrentCommand: "zsh", LastPromptTime: base.Unix() - 1,
			CommandRunning: running, CommandStartTime: base.Unix(),
		}
		if !running {
			p.CommandStatusOK, p.CommandEndTime = true, base.Unix()
		}
		return snapshot{current: "alpha", active: pane, panes: []tmux.Pane{p}}
	}
	tick := func(d time.Duration, running bool) {
		clock = clock.Add(d)
		next, _ := m.Update(snap(running))
		m = next.(model)
	}
	green := func() bool {
		for _, r := range m.rows {
			if r.paneID == pane {
				return strings.Contains(r.text, indicator(state.Running))
			}
		}
		t.Fatalf("no row for %s: %v", pane, m.rows)
		return false
	}

	tick(0, true)
	if green() {
		t.Error("the row is green before the run is shellRunDelay old")
	}
	tick(shellRunDelay, true)
	if !green() {
		t.Error("the row is not green after the run turned shellRunDelay old")
	}
	tick(time.Second, false) // the command stops: the hold takes over
	if !green() {
		t.Error("the row is not green while the hold is on")
	}
	tick(shellRunHold-50*time.Millisecond, false)
	if !green() {
		t.Error("the row went blank before the hold ran out")
	}
	tick(100*time.Millisecond, false)
	if green() {
		t.Error("the row is still green after the hold ran out")
	}
}

// TestInteractivePaneLabel checks the bypass: a pane whose foreground
// command owns the terminal draws no indicator however long it has been
// "running", while an ordinary command in the same state draws the green
// one. The panes are driven through track() on a controlled clock,
// because the running glyph only appears once the debounce has drawn it.
// TestInteractiveLeavesNoHold pins the fix for a row flashing green for
// half a second when an editor is quit: while the program held the
// terminal the pane must never look like a run the debounce has drawn, or
// the hold paints it on the way back to the prompt.
func TestInteractiveLeavesNoHold(t *testing.T) {
	const pane = "%1"
	base := time.Unix(1700000000, 0)
	clock := base
	m := &model{
		started: base.Add(-time.Hour),
		seen:    map[string]time.Time{},
		phases:  map[string]shellPhase{},
		now:     func() time.Time { return clock },
	}
	step := func(d time.Duration, alternate, running bool) string {
		clock = clock.Add(d)
		m.at = m.now()
		p := tmux.Pane{
			PaneID: pane, CurrentCommand: "nvim", AlternateOn: alternate,
			LastPromptTime: base.Unix() - 1, CommandRunning: running,
			CommandStartTime: base.Unix(),
		}
		m.snap = snapshot{panes: []tmux.Pane{p}}
		m.track()
		return m.paneLabel(p)
	}
	// An editor open for a while: the pane says nothing throughout.
	for _, d := range []time.Duration{0, 300 * time.Millisecond, time.Second} {
		if got := step(d, true, true); got != field("")+stProc.Render("nvim") {
			t.Fatalf("while the editor is open: paneLabel = %q", got)
		}
	}
	// It exits: tmux drops the alternate screen and the running flag in
	// the same tick. Nothing may be drawn on the way out.
	for _, d := range []time.Duration{100 * time.Millisecond, 200 * time.Millisecond, 400 * time.Millisecond} {
		if got := step(d, false, false); got != field("")+stProc.Render("nvim") {
			t.Errorf("+%v after the editor exits: paneLabel = %q, want no indicator", d, got)
		}
	}
}

func TestInteractivePaneLabel(t *testing.T) {
	const pid = 4242
	base := time.Unix(1700000000, 0)
	clock := base
	m := &model{
		started: base.Add(-time.Hour),
		seen:    map[string]time.Time{},
		phases:  map[string]shellPhase{},
		now:     func() time.Time { return clock },
	}
	// One integrated shell pane with a command running in it. Only the
	// command, and whether it has taken the alternate screen, vary below.
	pane := func(command string, alternate bool) tmux.Pane {
		return tmux.Pane{
			PaneID:           "%1",
			PanePID:          pid,
			CurrentCommand:   command,
			AlternateOn:      alternate,
			LastPromptTime:   base.Unix() - 1,
			CommandRunning:   true,
			CommandStartTime: base.Unix(),
		}
	}
	label := func(p tmux.Pane, ssh map[int]procs.SSHSession) string {
		m.at = m.now()
		m.snap = snapshot{panes: []tmux.Pane{p}, ssh: ssh}
		m.track()
		return m.paneLabel(p)
	}
	// Past the debounce delay, so a plain command is drawn as running.
	warm := func(p tmux.Pane, ssh map[int]procs.SSHSession) string {
		clock = base
		m.phases = map[string]shellPhase{}
		label(p, ssh)
		clock = clock.Add(500 * time.Millisecond)
		return label(p, ssh)
	}
	running := indicator(state.Running)
	for _, tc := range []struct {
		name string
		pane tmux.Pane
		ssh  map[int]procs.SSHSession
		want string
	}{{
		name: "a program on the alternate screen says nothing",
		pane: pane("nvim", true),
		want: field("") + stProc.Render("nvim"),
	}, {
		// The case a list of command names cannot reach: the pager has
		// the screen, but the pane reports the process group leader.
		name: "a pager under another command still says nothing",
		pane: pane("git", true),
		want: field("") + stProc.Render("git"),
	}, {
		name: "an ordinary command still runs",
		pane: pane("cargo", false),
		want: field(running) + stProc.Render("cargo"),
	}, {
		name: "an ssh shell says nothing",
		pane: pane("ssh", false),
		ssh:  map[int]procs.SSHSession{pid: {Host: "build-box", Interactive: true}},
		want: field("") + stProc.Render("ssh ") + "build-box",
	}, {
		name: "ssh running a remote command is a job",
		pane: pane("ssh", false),
		ssh:  map[int]procs.SSHSession{pid: {Host: "build-box"}},
		want: field(running) + stProc.Render("ssh ") + "build-box",
	}, {
		// A remote full-screen program takes this pane's alternate
		// screen too, even though ssh itself carries a command.
		name: "a remote editor says nothing",
		pane: pane("ssh", true),
		ssh:  map[int]procs.SSHSession{pid: {Host: "build-box"}},
		want: field("") + stProc.Render("ssh ") + "build-box",
	}} {
		t.Run(tc.name, func(t *testing.T) {
			if got := warm(tc.pane, tc.ssh); got != tc.want {
				t.Errorf("paneLabel = %q, want %q", got, tc.want)
			}
		})
	}
}
