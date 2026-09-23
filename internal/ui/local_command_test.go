package ui

import (
	"testing"
	"time"

	"kido/internal/tmux"
)

// localModel is a model with one plain integrated shell pane and a clock
// the test drives, the ssh-less analogue of sshModel.
func localModel(clock *time.Time) *model {
	base := *clock
	return &model{
		started: base.Add(-time.Hour),
		seen:    map[string]time.Time{},
		phases:  map[string]shellPhase{},
		now:     func() time.Time { return *clock },
	}
}

func (m *model) localTick(p tmux.Pane) {
	m.at = m.now()
	m.snap = snapshot{panes: []tmux.Pane{p}}
	m.track()
}

// TestLocalRowShowsCommandLine covers the label a plain integrated shell
// gets while a command runs in it: the command line the shell reported
// with its 133;C replaces #{pane_current_command} rather than qualifying
// it, since there is no destination here to keep alongside it the way ssh
// keeps its host.
func TestLocalRowShowsCommandLine(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := localModel(&clock)

	p := tmux.Pane{
		PaneID: "%1", CurrentCommand: "make",
		LastPromptTime: base.Unix() - 1, CommandStartTime: base.Unix(),
		CommandRunning: true, CommandLine: "make -j8 test",
	}
	m.localTick(p)
	if got, want := m.paneLabel(p), field(m.shellIndicator(m.phases["%1"]))+stProc.Render("make -j8 test"); got != want {
		t.Errorf("label = %q, want %q", got, want)
	}

	// It finishes. tmux keeps the command line until the next 133;C, so
	// only the shell status tells an idle pane from a busy one.
	clock = clock.Add(time.Second)
	done := tmux.Pane{
		PaneID: "%1", CurrentCommand: "zsh",
		LastPromptTime: base.Unix() + 2, CommandStartTime: base.Unix(),
		CommandRunning: false, CommandStatusOK: true, CommandEndTime: base.Unix() + 1,
		CommandStatus: 0, CommandLine: "make -j8 test",
	}
	m.localTick(done)
	if got, want := m.paneLabel(done), field(indicatorDone())+stProc.Render("zsh"); got != want {
		t.Errorf("label = %q, want %q: the finished command line must not linger", got, want)
	}
}

// TestLocalRowWithoutCommandLineIsUnchanged is what every tmux without the
// pane_command_line patch reports: the field arrives empty on a pane that
// is in every other way a running, integrated shell, and the row must be
// exactly the one kido drew before the field existed.
func TestLocalRowWithoutCommandLineIsUnchanged(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := localModel(&clock)

	p := tmux.Pane{
		PaneID: "%1", CurrentCommand: "make",
		LastPromptTime: base.Unix() - 1, CommandStartTime: base.Unix(),
		CommandRunning: true,
	}
	m.localTick(p)
	if got, want := m.paneLabel(p), field(m.shellIndicator(m.phases["%1"]))+stProc.Render("make"); got != want {
		t.Errorf("label = %q, want %q", got, want)
	}
}

// TestLocalRowInteractiveHasNoCommandLine is the deliberate choice not to
// show a full-screen program's arguments: interactivePane already means
// "kido has nothing to say about this pane", and a command line under an
// editor would contradict that on the very row that says so most loudly.
func TestLocalRowInteractiveHasNoCommandLine(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := localModel(&clock)

	p := tmux.Pane{
		PaneID: "%1", CurrentCommand: "nvim", AlternateOn: true,
		LastPromptTime: base.Unix() - 1, CommandStartTime: base.Unix(),
		CommandRunning: true, CommandLine: "nvim internal/ui/ui.go",
	}
	m.localTick(p)
	if got, want := m.paneLabel(p), field("")+stProc.Render("nvim"); got != want {
		t.Errorf("label = %q, want %q: an interactive pane keeps no command line", got, want)
	}
}

// TestLocalRowIdleHasNoCommandLine: tmux keeps the last command line
// after the shell returns to a prompt, and the row must not show it once
// the shell is idle.
func TestLocalRowIdleHasNoCommandLine(t *testing.T) {
	base := time.Unix(1700000000, 0)
	clock := base
	m := localModel(&clock)

	p := tmux.Pane{
		PaneID: "%1", CurrentCommand: "zsh",
		LastPromptTime: base.Unix(), CommandStartTime: base.Unix() - 1,
		CommandRunning: false, CommandStatusOK: true, CommandEndTime: base.Unix() - 1,
		CommandStatus: 0, CommandLine: "make -j8 test",
	}
	m.localTick(p)
	if got := m.paneLabel(p); got != field(indicatorDone())+stProc.Render("zsh") {
		t.Errorf("label = %q, want the plain shell label, no command line while idle", got)
	}
}
