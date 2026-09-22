// Package ui is the Bubble Tea sidebar: sessions and their panes, with
// agent panes badged by the status the agent reported. Agents are not told
// apart on screen: a pi pane and a Claude Code pane are both an indicator
// and a title.
package ui

import (
	"maps"
	"sort"
	"strings"
	"time"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
	"github.com/sahilm/fuzzy"

	"kido/internal/procs"
	"kido/internal/reap"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
	"kido/internal/tree"
)

// Options configures the sidebar.
type Options struct {
	// Interval is how often the sidebar re-reads tmux and the state
	// files. A tick is a write and a read on the control connection, not a
	// process, so it can be short; tmux changes arrive as notifications in
	// between, and the tick is what catches the things tmux does not
	// report (a pane's command changing, the side-status-focus flag).
	Interval time.Duration
	Client   string // tmux client the sidebar belongs to

	// Standalone runs kido as a one-shot picker rather than as a client's
	// side status line: q, Esc and C-c quit, and picking a pane jumps and
	// then quits. It is set when $TMUX_SIDE_CLIENT is empty, which the
	// fork sets only for the side-status-command job, so a popup (`tmux
	// display-popup -E "kido -client '#{client_name}'"`) and a plain pane
	// both run standalone. Without it there is no way out of the program:
	// the sidebar hands the keyboard back to the pane instead of exiting,
	// which only means anything when kido owns a side column.
	Standalone bool
}

// snapshot is everything the sidebar shows, taken off the UI goroutine.
type snapshot struct {
	current string // session the client is attached to
	active  string // the client's active pane
	focused bool   // the sidebar has the keyboard
	panes   []tmux.Pane
	states  map[string]state.Session
	ssh     map[int]procs.SSHSession // pane pid -> what its ssh is doing
	pi      map[int]bool             // pane pid -> pi runs in this pane
	probed  time.Time                // when the process table was last read
	err     error

	// probes remembers the last screen read of each waiting pane, so the
	// screen is read at most once per probeInterval rather than on every
	// tick. See screen.go.
	probes map[string]probe

	// lingering carries the name and outcome of a subagent window whose
	// state record is already gone but whose @kido_subagent mark still
	// names its run - the sweep's ~30s read window (docs/design.md,
	// "Window lifecycle"). Both live in files under internal/subrun, not
	// in tmux or the state directory, so they must be read here and
	// carried in the snapshot rather than read from paneLabel: rendering
	// is a pure function of the snapshot, and same() must see a changed
	// outcome the same way it sees a changed pane - reading the files at
	// render time would let two "equal" snapshots draw differently, and
	// an outcome recorded after the record was already gone (a slow
	// run-outcome call outracing the removal report, a kill-window that
	// has to retry) would never redraw.
	lingering map[string]lingering
}

// lingering is one lingering subagent window's label, keyed by run id.
type lingering struct {
	name      string
	outcome   subrun.Result
	outcomeOK bool // whether an outcome has been recorded at all
}

// lingeringSubagents reads the name and outcome of every subagent window
// this snapshot's panes show as marked but with no state record for the
// pane the mark is on - the only panes lingeringLabel ever needs this
// for, so a run's files are read at most once per tick per such window,
// and never for a live agent pane or a plain shell.
func lingeringSubagents(panes []tmux.Pane, states map[string]state.Session) map[string]lingering {
	var out map[string]lingering
	for _, p := range panes {
		if p.Subagent == "" {
			continue
		}
		if _, reported := states[p.PaneID]; reported {
			continue
		}
		runID := tmux.SubagentRunID(p.Subagent)
		if runID == "" {
			continue
		}
		if _, ok := out[runID]; ok {
			continue
		}
		meta, err := subrun.ReadMeta(runID)
		if err != nil {
			// A run directory that is missing or unreadable is not this
			// pane's business to explain; paneLabel falls back to the plain
			// pane command the way it always has.
			continue
		}
		if out == nil {
			out = map[string]lingering{}
		}
		l := lingering{name: meta.Name}
		if o, ok, err := subrun.ReadOutcome(runID); err == nil && ok {
			l.outcome, l.outcomeOK = o.Result, true
		}
		out[runID] = l
	}
	return out
}

// probe is one read of a waiting session's screen: whether its input box
// was back, meaning the user dismissed the question or denied the
// permission without Claude Code saying so. The dismissal happened at an
// unknown time after the hook reported the prompt, so that report time
// stands in for Stop's Ended: it survives a kido restart, whereas the
// time kido noticed would make every old dismissal look freshly done.
//
// The verdict is never final: it is recomputed on the next probe, so a
// dialog that painted late cannot leave a genuinely waiting pane showing
// idle for good. Because Ended comes from the report time alone, a
// recomputed verdict is identical to the old one and the snapshot does
// not churn.
type probe struct {
	reported  time.Time // the state file's TS this was decided for
	read      time.Time // when the screen was last read
	dismissed bool      // the input box was back
}

// promptGrace is how long a session must have been waiting before kido
// reads its screen: the hook fires just before Claude Code paints the
// dialog, and until it does the screen still shows the input box.
const promptGrace = 500 * time.Millisecond

// probeInterval is the shortest gap between two reads of the same
// waiting pane's screen. Every read is a capture-pane down the one
// control connection, and at a 100ms tick a pane sitting on a real
// dialog would otherwise mean ten screen dumps a second.
const probeInterval = time.Second

// shellRunDelay is how long kido must have observed a command running in a
// shell pane before it draws the green running indicator. A command that
// finishes inside it is never drawn as running at all: at a 100ms tick, a
// short one would otherwise flash the glyph for a single frame.
const shellRunDelay = 200 * time.Millisecond

// shellRunHold is how long the running indicator stays on a pane whose
// command has stopped, when nothing else has taken its place. It only ever
// applies to a run that was drawn (one that lasted shellRunDelay), so the
// hold can only lengthen a green that is already on screen, never create
// one; and only when shellOutcome has nothing to show, which is precisely
// when the user is sitting in that pane. Everywhere else the ✓ or the red
// ▌ replaces the green at once.
const shellRunHold = 500 * time.Millisecond

// procsProbe is the shortest gap between two reads of the process table.
// Panes running ssh, and panes that might be running pi, are looked up
// there, and at a 100ms tick an unresolvable one would otherwise mean ten
// ps calls a second.
const procsProbe = time.Second

type row struct {
	text   string
	paneID string // non-empty for selectable rows
}

type model struct {
	opts      Options
	conn      *tmux.Conn // control-mode connection; queries fall back to exec
	snap      snapshot
	rows      []row
	cursor    int // index into rows; on a selectable row when any exist
	top       int // first row shown; moves only when the cursor leaves the view
	width     int
	height    int
	status    string // error shown on the last line
	filter    string // fuzzy filter on session names; "" unless searching
	searching bool   // "/" pressed: typing edits the filter
	gPend     bool   // a "g" was typed: "gg" goes to the top

	// An agent session whose turn ended after its pane was last looked at
	// is "done" until the user visits it. seen records the last time each
	// pane was the active one; started stands in for panes never seen.
	started time.Time
	seen    map[string]time.Time

	// phases debounces the shell running indicator, keyed by PaneID. It is
	// kido's own observation of each pane rather than anything tmux
	// reports: tmux's OSC 133 timestamps are whole seconds, far too coarse
	// for the sub-second thresholds, so what counts is when the 100ms tick
	// first saw a command start and stop.
	phases map[string]shellPhase

	// now is the clock, injectable so tests can drive the phases above;
	// at is the one reading taken for the update being handled, so every
	// deadline in a frame is measured against the same instant.
	now func() time.Time
	at  time.Time
}

// shellPhase is what the last tick observed of one shell pane's command
// activity, and when that observation last changed.
type shellPhase struct {
	running bool      // a command was running at the last observation
	since   time.Time // when running last flipped, in kido's own clock
	// drawn records that the current run (or, once it has stopped, the
	// last one) lasted shellRunDelay and so reached the screen. The hold
	// reads it: keeping "running" up for 500ms after a 50ms command that
	// was never drawn would create a blink instead of removing one.
	drawn bool
	// held is the pane's outcome (see shellOutcome): live while it sits
	// idle, and then the one it was showing when a run started, kept for
	// the window before that run is drawn. tmux clears
	// pane_command_status on 133;C, so the outcome is gone from the
	// moment a command starts and cannot be recovered: without this the
	// row would blank for shellRunDelay at the start of every command on
	// a pane the user is not watching, which is the blink the delay was
	// added to remove.
	held   int
	heldOK bool
}

// Run starts the sidebar and blocks until it exits.
func Run(opts Options) error {
	// kido's stdout is a tmux pane by construction, but termenv treats a CI
	// env var (which tmux passes into the job) as proof of no TTY and would
	// strip every style. Force the basic profile unless the user opted out.
	if !termenv.DefaultOutput().EnvNoColor() {
		lipgloss.SetColorProfile(termenv.ANSI)
	}
	conn := tmux.Connect(opts.Client)
	defer conn.Close()
	m := model{
		opts: opts, conn: conn,
		seen: map[string]time.Time{}, phases: map[string]shellPhase{},
		now: time.Now,
	}
	m.at = m.now()
	m.started = m.at
	m.snap = take(conn, opts.Client, snapshot{})
	m.track()
	m.rebuild()
	m.focus(m.snap.active)
	_, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	return err
}

// take gathers a snapshot. prev is the last one: its ssh and pi maps spare
// the process table, which is only re-read when a pane asks something they
// do not answer (an unresolved ssh destination, a pane that could be pi)
// and the last read is old enough.
func take(conn *tmux.Conn, client string, prev snapshot) snapshot {
	var s snapshot
	s.current, s.focused = clientState(conn, client)
	if conn != nil && s.current != "" {
		conn.Follow(s.current)
	}
	if s.panes, s.err = listPanes(conn); s.err != nil {
		return s
	}
	s.active = tmux.ActivePane(s.panes, s.current)
	s.states, s.err = state.Load()
	s.ssh, s.pi = map[int]procs.SSHSession{}, map[int]bool{}
	s.probed = prev.probed
	// At most one fresh sweep per tick, and at most one per procsProbe: a
	// faster tick must not mean more ps calls.
	scan, read := procs.Scan{SSH: prev.ssh, Pi: prev.pi}, false
	sweep := func() {
		if !read && time.Since(s.probed) >= procsProbe {
			scan, read = procs.Sweep(), true
			s.probed = time.Now()
		}
	}
	for _, p := range s.panes {
		switch {
		case p.CurrentCommand == "ssh":
			if _, ok := scan.SSH[p.PanePID]; !ok {
				sweep()
			}
			if sess, ok := scan.SSH[p.PanePID]; ok {
				s.ssh[p.PanePID] = sess
			}
		case procs.MaybePi(p.CurrentCommand):
			if _, reported := s.states[p.PaneID]; reported {
				// The agent already says what this pane is; the process
				// table is only asked about panes that have said nothing,
				// so an install the sweep cannot match costs no ps calls.
				continue
			}
			if !scan.Pi[p.PanePID] {
				sweep()
			}
			if scan.Pi[p.PanePID] {
				s.pi[p.PanePID] = true
			}
		}
	}
	reapSubagentWindows(s.panes, s.states)
	s.lingering = lingeringSubagents(s.panes, s.states)
	s.probes = dismissals(conn, prev.probes, s.states)
	for pane, p := range s.probes {
		if !p.dismissed {
			continue
		}
		sess := s.states[pane]
		sess.Status, sess.Ended = state.Idle, p.reported
		s.states[pane] = sess
	}
	return s
}

// dismissals reads the screen of every session the hooks report as
// waiting and reports, per pane, whether it is back at its input box:
// the user dismissed the question or denied the permission, which Claude
// Code reports through no hook of its own. prev carries the last read of
// each pane; one younger than probeInterval, taken for the same report,
// is reused, so a pane costs at most one capture-pane a second however
// often the sidebar ticks. Anything else - a newer report, a stale read,
// a pane that was not waiting before - is read afresh and the verdict
// recomputed rather than carried over.
func dismissals(conn *tmux.Conn, prev map[string]probe, states map[string]state.Session) map[string]probe {
	var out map[string]probe
	keep := func(pane string, p probe) {
		if out == nil {
			out = map[string]probe{}
		}
		out[pane] = p
	}
	now := time.Now()
	for pane, s := range states {
		// Claude Code only: atInputPrompt reads a Claude Code screen (see
		// screen.go), and the gap it stands in for is Claude Code's own.
		// Another agent reports its own transitions, so reading its screen
		// would be a capture-pane a second spent on a guess that cannot
		// apply.
		if s.Agent != state.AgentClaude {
			continue
		}
		// Waiting only: every other status has a hook behind it and needs
		// no guessing. It is the dismissal gap documented in the events
		// table in internal/hook/hook.go that this stands in for, so do
		// not loosen this to Running.
		if s.Status != state.Waiting {
			continue
		}
		if p, ok := prev[pane]; ok && p.reported.Equal(s.TS) && now.Sub(p.read) < probeInterval {
			keep(pane, p)
			continue
		}
		if now.Sub(s.TS) < promptGrace {
			continue
		}
		// A screen kido cannot read leaves the pane waiting, and the
		// attempt is recorded all the same so a failing capture does not
		// retry at tick rate.
		lines, err := capturePane(conn, pane)
		keep(pane, probe{reported: s.TS, read: now, dismissed: err == nil && atInputPrompt(lines)})
	}
	return out
}

// clientState and listPanes ask the control connection, falling back to
// running tmux while it is down (a reconnect gap must not blank the
// sidebar).
func clientState(conn *tmux.Conn, client string) (string, bool) {
	if conn != nil {
		if session, focused, err := conn.ClientState(client); err == nil {
			return session, focused
		}
	}
	return tmux.ClientState(client)
}

func listPanes(conn *tmux.Conn) ([]tmux.Pane, error) {
	if conn != nil {
		if panes, err := conn.ListPanes(); err == nil {
			return panes, nil
		}
	}
	return tmux.ListPanes()
}

// killWindow is tmux.KillWindow, indirected so a test can watch what the
// reaper closes without a tmux server.
var killWindow = tmux.KillWindow

// reapSubagentWindows closes the subagent windows this snapshot shows as
// finished. Called from take, on the snapshot goroutine, and deliberately
// not from state.Load, which `kido prompt` calls too. The standalone
// picker shares take and so sweeps as well; a second poll is as harmless
// as a second sidebar.
func reapSubagentWindows(panes []tmux.Pane, states map[string]state.Session) {
	if len(panes) == 0 {
		return
	}
	sessions := make([]state.Session, 0, len(states))
	for _, s := range states {
		sessions = append(sessions, s)
	}
	for _, windowID := range reap.Sweep(panes, sessions, time.Now()) {
		killWindow(windowID) //nolint:errcheck // best effort; the window may already be gone
	}
}

func capturePane(conn *tmux.Conn, pane string) ([]string, error) {
	if conn != nil {
		if lines, err := conn.CapturePane(pane); err == nil {
			return lines, nil
		}
	}
	return tmux.CapturePane(pane)
}

// tick takes the next snapshot in the background: after the interval, or
// as soon as tmux reports a change, whichever comes first.
func (m model) tick() tea.Cmd {
	conn, client, d, prev := m.conn, m.opts.Client, m.opts.Interval, m.snap
	return func() tea.Msg {
		var notify <-chan struct{}
		if conn != nil {
			notify = conn.Notify()
		}
		timer := time.NewTimer(d)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-notify:
		}
		return take(conn, client, prev)
	}
}

// same reports whether two snapshots would render identically.
func (a snapshot) same(b snapshot) bool {
	return a.current == b.current && a.active == b.active && a.focused == b.focused &&
		a.err == nil && b.err == nil &&
		samePanes(a.panes, b.panes) && sameStates(a.states, b.states) &&
		maps.Equal(a.ssh, b.ssh) && maps.Equal(a.pi, b.pi) && maps.Equal(a.lingering, b.lingering)
}

// sameStates is maps.Equal for state.Session with TS excluded through
// drawnSession, the Session analogue of samePanes/drawnPart: the
// heartbeat changes TS every ~30s with nothing else moving, and would
// otherwise force a rebuild per running agent on that timer.
func sameStates(a, b map[string]state.Session) bool {
	return maps.EqualFunc(a, b, func(x, y state.Session) bool {
		return drawnSession(x) == drawnSession(y)
	})
}

// drawnSession is s without TS. TS still reaches one row, the stalled
// indicator, and stallPending reads it directly for that.
func drawnSession(s state.Session) state.Session {
	s.TS = time.Time{}
	return s
}

// samePanes compares two pane lists by what the sidebar actually draws and
// orders by, not by the whole tmux.Pane: a tmux.Pane also carries fields
// only `kido snapshot` reads, and comparing those made a cd in any pane, or
// a drag-resize rewriting a layout string, force a full rebuild that
// produced an identical screen.
//
// It compares by exclusion, not by listing the fields that matter: a field
// left out of such a list does not fail anything, it just freezes the row
// on screen. Zeroing the few fields that reach no row inverts that, so a
// new tmux.Pane field is compared by default.
func samePanes(a, b []tmux.Pane) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if drawnPart(a[i]) != drawnPart(b[i]) {
			return false
		}
	}
	return true
}

// drawnPart is p without the fields the sidebar neither draws nor orders
// by, so two panes that would render identically compare equal.
//
// WindowIndex, WindowName, WindowLayout and CurrentPath reach no row - a
// renumbering reorders the pane list itself, which samePanes' positional
// comparison catches anyway. Active's only drawn consequence is
// snapshot.active, which same() compares separately: a pane switch inside a
// session the client is not attached to changes nothing on screen.
//
// Dead, DeadTime and SessionAttached are left in, though no row draws
// them: each changes at most a handful of times in a pane's life, so
// keeping them costs an occasional redundant redraw, and dropping them
// would risk a stale pane list reaching the reaper. Subagent is left in
// for a stronger reason now: orderWindowsByTree reads it to place a
// window once its agent record is gone, so a change to it must redraw
// too. In practice it never changes after kido spawn sets it once at
// window creation, and a window's first appearance already forces a
// rebuild on its own, but excluding it here would be the same silent
// staleness this comment warns about for the others.
func drawnPart(p tmux.Pane) tmux.Pane {
	p.WindowIndex, p.WindowName, p.WindowLayout, p.CurrentPath = 0, "", "", ""
	p.Active = false
	return p
}

func (m model) Init() tea.Cmd { return m.tick() }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ensureVisible()
	case snapshot:
		was := m.snap
		// The second reason to rebuild: the running indicator's delay and
		// hold are driven by kido's own clock, not by anything tmux
		// reports, so a pane whose deadline falls in a tick where the
		// snapshot is unchanged has to be redrawn all the same, or it
		// freezes mid-transition until tmux happens to say something else.
		// It is deliberately read before the tick is folded in, of the
		// frame currently on screen.
		pending := m.shellPending() || m.stallPending()
		now := m.now()
		// The sidebar is the only thing in kido that ticks continuously,
		// so it is what notices a sleep and rebases state.Stalled, on
		// disk so `kido agents` sees the same rebase.
		if state.DetectPause(m.at, now) {
			state.RecordPause(now) //nolint:errcheck // best effort; a failed write just costs one sidebar's detection reaching the others
		}
		m.at = now
		m.snap = msg
		m.track()
		if !msg.same(was) || pending {
			m.rebuild()
		}
		// Follow the user: a pane switch in tmux, or the keyboard going
		// back to the pane (prefix k, a click elsewhere) both put the
		// selection on the active pane.
		if (msg.active != was.active || (was.focused && !msg.focused)) &&
			msg.active != "" {
			m.focus(msg.active)
		}
		return m, m.tick()
	case tea.MouseMsg:
		switch {
		case msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft:
			if i := m.rowAt(msg.Y); i >= 0 {
				m.cursor = i
				// Two steps: m is a value receiver, so the copy returned
				// must be made after jump has mutated it.
				cmd := m.jump()
				return m, cmd
			}
		case msg.Button == tea.MouseButtonWheelUp:
			m.top -= 3
			m.clampTop()
		case msg.Button == tea.MouseButtonWheelDown:
			m.top += 3
			m.clampTop()
		}
	case tea.KeyMsg:
		cmd := m.key(msg)
		return m, cmd
	}
	return m, nil
}

// key handles one key press, returning the command it asks for (only ever
// tea.Quit, and only in standalone mode).
func (m *model) key(msg tea.KeyMsg) tea.Cmd {
	// Runes that arrive together (fast typing, send-keys) come as one
	// message; while searching they are all filter text, otherwise each
	// is a separate command.
	if msg.Type == tea.KeyRunes && !msg.Alt {
		if m.searching {
			m.setFilter(m.filter + string(msg.Runes))
			return nil
		}
		if len(msg.Runes) > 1 {
			var cmd tea.Cmd
			for _, r := range msg.Runes {
				// The first key that asks to quit wins; the rest of the
				// batch is still handled, so the state the program exits
				// with is the state every key left behind.
				if c := m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}}); c != nil && cmd == nil {
					cmd = c
				}
			}
			return cmd
		}
	}
	pend := m.gPend
	m.gPend = false
	switch msg.String() {
	case "ctrl+j", "ctrl+n", "down":
		m.move(1)
	case "ctrl+k", "ctrl+p", "up":
		m.move(-1)
	case "shift+down":
		m.switchWindow(true)
	case "shift+up":
		m.switchWindow(false)
	case "enter":
		return m.jump()
	case "esc", "ctrl+c":
		// Leave the search, or hand the keyboard back to the pane - or,
		// standalone, quit. The search is always left first, so Esc means
		// the same thing in both modes: undo the search, then leave.
		switch {
		case m.searching:
			m.searching = false
			m.setFilter("")
		case m.opts.Standalone:
			return tea.Quit
		default:
			if err := tmux.ReleaseSideFocus(m.opts.Client); err != nil {
				m.status = err.Error()
			} else {
				m.focus(m.snap.active)
			}
		}
	case "q":
		// Standalone only: in the side column there is nothing to quit to,
		// and "q" would be a keystroke the user cannot take back.
		if m.opts.Standalone {
			return tea.Quit
		}
	case "backspace":
		if r := []rune(m.filter); len(r) > 0 {
			m.setFilter(string(r[:len(r)-1]))
		} else {
			m.searching = false // nothing left to erase: leave the search
		}
	case "/":
		m.searching = true
		m.setFilter("")
	case "j":
		m.move(1)
	case "k":
		m.move(-1)
	case "n":
		m.nextAttention(1)
	case "N":
		m.nextAttention(-1)
	case "g": // "gg" goes to the top
		if pend {
			m.cursor = -1
			m.move(1)
		} else {
			m.gPend = true
		}
	case "G", "end":
		m.cursor = len(m.rows)
		m.move(-1)
	case "home":
		m.cursor = -1
		m.move(1)
	}
	return nil
}

// jump switches the client to the pane under the cursor, hands it the
// keyboard, and clears the filter with the pane still selected. Standalone,
// it also asks to quit once the jump went through: picking a pane is the
// whole of a one-shot picker's job, and quitting is what closes the popup.
// A failed jump leaves the program up with the error on the status line,
// so the user can see it and try something else.
func (m *model) jump() tea.Cmd {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return nil
	}
	pane := m.rows[m.cursor].paneID
	if err := tmux.Jump(m.opts.Client, pane); err != nil {
		m.status = err.Error()
		return nil
	}
	if m.searching {
		m.searching = false
		m.setFilter("")
		m.focus(pane)
	}
	if m.opts.Standalone {
		return tea.Quit
	}
	return nil
}

// switchWindow moves the client to the adjacent window in kido's order, the
// same as `kido switch-window`, without releasing the sidebar's keyboard
// focus. The cursor is not moved here: the switch happens through tmux, and
// the snapshot only catches up on the next poll, at which point the normal
// Update path (msg.active != was.active) snaps the selection to the new
// active pane, the same as it does when the sidebar loses focus.
func (m *model) switchWindow(next bool) {
	if err := tmux.SwitchWindow(m.opts.Client, next); err != nil {
		m.status = err.Error()
	}
}

func (m *model) setFilter(f string) {
	m.filter = f
	m.rebuild()
}

// track notes that the active pane is being looked at right now, and
// records what this tick observed of every integrated shell pane.
//
// Both maps are per pane, not per agent session: a plain shell pane is in
// seen too, because shellOutcome dates a command's outcome against the last
// visit the same way done() dates a turn's end. So a remembered pane is
// forgotten when the pane itself is gone, not when an agent record is -
// dropping shell panes here would leave every failed row stuck red. phases
// is garbage-collected against the same live pane list for the same reason.
func (m *model) track() {
	if m.snap.active != "" {
		m.seen[m.snap.active] = m.at
	}
	if m.snap.err != nil {
		return // no pane list to compare against: forget nothing, observe nothing
	}
	live := make(map[string]bool, len(m.snap.panes))
	for _, p := range m.snap.panes {
		live[p.PaneID] = true
		if running, ok := p.ShellStatus(); ok {
			// A program holding the terminal is not a run, so it never
			// becomes one the debounce has drawn - otherwise quitting an
			// editor left the hold painting the row green for half a
			// second on the way back to the prompt.
			running = running && !m.interactivePane(p)
			prev := m.phases[p.PaneID]
			ph := m.observe(prev, running)
			// The outcome is readable only while the pane is idle, so
			// take it then and carry it through the run that follows
			// (see shellPhase.held).
			if running {
				ph.held, ph.heldOK = prev.held, prev.heldOK
			} else {
				ph.held, ph.heldOK = m.shellOutcome(p)
			}
			m.phases[p.PaneID] = ph
		}
	}
	for pane := range m.seen {
		if !live[pane] {
			delete(m.seen, pane) // the pane is gone
		}
	}
	for pane := range m.phases {
		if !live[pane] {
			delete(m.phases, pane)
		}
	}
}

// observe folds this tick's reading of a pane into its phase. A pane seen
// for the first time starts stopped-and-undrawn, so a command already
// running when kido starts takes shellRunDelay to appear, the same as one
// that starts under it.
//
// A run that starts while the previous run's hold is still on screen
// inherits its drawn flag, so the green never blanks between two commands
// typed back to back: the hold exists to stop exactly that gap, and a
// second command would otherwise punch a shellRunDelay hole in it.
func (m *model) observe(prev shellPhase, running bool) shellPhase {
	switch {
	case running == prev.running:
		if running && !prev.drawn && m.at.Sub(prev.since) >= shellRunDelay {
			prev.drawn = true
		}
		return prev
	case running:
		return shellPhase{running: true, since: m.at,
			drawn: prev.drawn && m.at.Sub(prev.since) < shellRunHold}
	default:
		// Stopped: keep drawn as it is, because the hold is what reads it.
		return shellPhase{running: false, since: m.at, drawn: prev.drawn}
	}
}

// stallPending reports whether any Running session's state.Stalled
// verdict would read differently now than it did as of the frame on
// screen (m.at). A session going stalled is driven purely by kido's own
// clock, so without this one crossing the threshold in a quiet tick
// would freeze as "running" until something unrelated changed.
func (m *model) stallPending() bool {
	now := m.now()
	for _, s := range m.snap.states {
		if s.Status != state.Running {
			continue
		}
		if state.Stalled(s, m.at) != state.Stalled(s, now) {
			return true
		}
	}
	return false
}

// shellPending reports whether any pane is inside a clock-driven window -
// running but not yet drawn, or stopped and still held - and so would
// change what it draws on a later tick with nothing in the snapshot
// moving. Update rebuilds on it: without that a pane whose 200ms or 500ms
// deadline expires in a quiet tick would freeze mid-transition until tmux
// happened to report something unrelated.
func (m *model) shellPending() bool {
	for _, ph := range m.phases {
		if ph.running && !ph.drawn {
			return true
		}
		if !ph.running && ph.drawn && m.at.Sub(ph.since) < shellRunHold {
			return true
		}
	}
	return false
}

// seenAt is when the user last looked at pane, or when kido started for
// one never visited under it - so anything that happened since then counts
// as unseen. Both until-visited rules, done() and shellOutcome(), date
// their event against it.
func (m *model) seenAt(pane string) time.Time {
	if t, ok := m.seen[pane]; ok {
		return t
	}
	return m.started
}

// done reports whether pane's agent session finished a turn since the
// pane was last looked at.
func (m *model) done(pane string) bool {
	s, ok := m.snap.states[pane]
	if !ok || s.Status != state.Idle || s.Ended.IsZero() {
		return false
	}
	return s.Ended.After(m.seenAt(pane))
}

// shellOutcome reports the exit status of the last command that finished in
// pane p since the user last looked at it, and whether there was one. It is
// the shell counterpart of done: the row stays marked until the pane is
// visited, not until the next prompt.
//
// m.seen is refreshed every tick while a pane is active, so a command run
// and watched never leaves a mark; only one that finished while the user
// was elsewhere does, which is why marking every successful command this
// way is not noise.
//
// A pane running a command right now has no outcome: the status on record
// belongs to a command this one has superseded, and the one that matters is
// the one the pane is left sitting on. Whether anything is drawn in its
// place while it runs is shellIndicator's call, not this function's.
func (m *model) shellOutcome(p tmux.Pane) (status int, ok bool) {
	running, integrated := p.ShellStatus()
	if !integrated || running {
		return 0, false // no OSC 133 integration, or busy right now
	}
	if !p.CommandStatusOK || p.CommandEndTime == 0 {
		return 0, false
	}
	// A status on record is not proof a command ran: an integration whose
	// precmd emits 133;D unconditionally reports one at the shell's very
	// first prompt, carrying whatever exit status the rc files left
	// behind, with no 133;C before it - and every freshly opened pane
	// would wear a checkmark until it was visited. kido's own script does
	// not do that (shell/zsh/integration.zsh), but a remote host's or
	// another terminal's might, and only 133;C sets
	// pane_command_start_time, so a zero there means nothing has run.
	if p.CommandStartTime == 0 {
		return 0, false
	}
	// tmux reports whole unix seconds, seenAt a wall-clock instant. The
	// comparison is strict so that a command failing in a pane the user is
	// looking at (seen is refreshed every tick, so it is at or past the
	// truncated end time) never lights up; the price is that a failure in
	// the very second the user left the pane is missed.
	if !time.Unix(p.CommandEndTime, 0).After(m.seenAt(p.PaneID)) {
		return 0, false
	}
	return p.CommandStatus, true
}

// shellIndicator is the indicator for an integrated shell pane, debounced
// against kido's own observations of it (see shellPhase). "" draws nothing.
// Only shell panes go through it: an agent pane's status comes from hooks,
// which report transitions rather than a flag sampled every 100ms, and does
// not flicker. It reads the phase alone, which track() has already brought
// up to date for this tick.
//
// In order:
//
//  1. a run that has lasted shellRunDelay is green, and wins over any past
//     outcome, which is the status of a command this one has superseded;
//  2. otherwise the outcome shows: at once when the command has just
//     finished, and carried unchanged through a run too young to be drawn
//     rather than blanking for 200ms. No hold, no delay - this is the pane
//     the user is not looking at, and a ✓ or a red ▌ landing a tick late
//     there would be a lie about what the pane is doing now;
//  3. otherwise a run that was drawn and has just stopped keeps its green
//     for shellRunHold. Step 2 having found nothing means the user is
//     sitting in this pane (seenAt is refreshed every tick for the active
//     pane, so a command finishing there is never "since the last visit"),
//     so the hold only ever smooths the pane being watched.
func (m *model) shellIndicator(ph shellPhase) string {
	switch {
	case ph.running && ph.drawn:
		return indicator(state.Running)
	case ph.heldOK:
		return outcomeIndicator(ph.held)
	case ph.drawn && m.at.Sub(ph.since) < shellRunHold:
		return indicator(state.Running)
	}
	return ""
}

// wants reports whether pane's agent session needs the user: it is
// waiting on a prompt, or done and not yet looked at.
func (m *model) wants(pane string) bool {
	return m.snap.states[pane].Status == state.Waiting || m.done(pane)
}

// nextAttention moves the cursor to the next row that wants the user, in
// the given direction, wrapping around.
func (m *model) nextAttention(delta int) {
	n := len(m.rows)
	i := m.cursor
	for range n {
		i = (i + delta + n) % n
		if m.wants(m.rows[i].paneID) {
			m.cursor = i
			m.ensureVisible()
			return
		}
	}
}

// indexOf returns the row of paneID, or -1.
func (m *model) indexOf(paneID string) int {
	for i, r := range m.rows {
		if r.paneID != "" && r.paneID == paneID {
			return i
		}
	}
	return -1
}

// focus puts the cursor on paneID if it is listed.
func (m *model) focus(paneID string) {
	if i := m.indexOf(paneID); i >= 0 {
		m.cursor = i
		m.ensureVisible()
	}
}

// move steps the cursor to the next selectable row in the given direction.
func (m *model) move(delta int) {
	for i := m.cursor + delta; i >= 0 && i < len(m.rows); i += delta {
		if m.rows[i].paneID != "" {
			m.cursor = i
			m.ensureVisible()
			return
		}
	}
}

// scrollMargin is how many rows to keep visible beyond the cursor: the
// view starts moving when the cursor gets this close to an edge.
const scrollMargin = 3

// viewRows is how many rows fit above the bottom line, which is always
// reserved (for the search prompt or an error) so the frame never changes
// height: Bubble Tea's renderer drops a row when a frame shrinks while its
// other lines stay the same.
func (m *model) viewRows() int {
	if m.height > 1 {
		return m.height - 1
	}
	return len(m.rows)
}

func (m *model) clampTop() {
	if max := len(m.rows) - m.viewRows(); m.top > max {
		m.top = max
	}
	if m.top < 0 {
		m.top = 0
	}
}

// ensureVisible scrolls just enough to keep the cursor inside the view
// with scrollMargin rows of context, as far as the list allows.
func (m *model) ensureVisible() {
	h := m.viewRows()
	margin := scrollMargin
	if margin > (h-1)/2 {
		margin = (h - 1) / 2 // tiny views: keep the cursor centred at worst
	}
	if m.cursor-margin < m.top {
		m.top = m.cursor - margin
	} else if m.cursor+margin >= m.top+h {
		m.top = m.cursor + margin - h + 1
	}
	m.clampTop()
}

// rowAt maps a screen line to a selectable row index, or -1.
func (m *model) rowAt(y int) int {
	i := m.top + y
	if i < 0 || i >= len(m.rows) || m.rows[i].paneID == "" {
		return -1
	}
	return i
}

var (
	stCurrent = lipgloss.NewStyle().Bold(true)
	stProc    = lipgloss.NewStyle().Foreground(lipgloss.Color("7"))
	stDim     = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	stCursor  = lipgloss.NewStyle().Reverse(true)
	stErr     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))

	stRunning = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	stWaiting = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true)
	stCompact = lipgloss.NewStyle().Foreground(lipgloss.Color("5"))
	stDone    = lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true)
	stUnknown = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	stStalled = lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
)

// glyph renders one tree glyph grouping a window's panes: a dot for a lone
// pane, else a bracket spanning the window's rows. The glyphs are dim like
// the rest of the tree structure.
func glyph(i, n int) string {
	switch {
	case n == 1:
		return stDim.Render("·")
	case i == 0:
		return stDim.Render("┌")
	case i == n-1:
		return stDim.Render("└")
	default:
		return stDim.Render("├")
	}
}

// continuation is what stands in the column of a window whose rows a
// nested subagent has interrupted: a stem while panes of that window are
// still to come below the interruption, and nothing once the last one has
// been drawn. See appendWindows for why a window's column is carried on
// rather than restarted.
func continuation(i, n int) string {
	if i < n-1 {
		return stDim.Render("│")
	}
	return " "
}

// indicators marks an agent pane by its status: the glyph alone says it is
// an agent session, the same for every agent. Idle is deliberately empty -
// a pane with nothing to say shows nothing - and field() keeps the column
// the label starts at the same all the same.
//
// The glyphs are held unrendered and styled by indicator() on the fly: a
// lipgloss style decides its colour profile the first time it renders, and
// Run forces the profile after this package is initialised, so a string
// rendered up here would come out unstyled wherever termenv sees no TTY (a
// CI environment variable is enough to convince it of that).
var indicators = map[state.Status]struct {
	style lipgloss.Style
	glyph string
}{
	state.Running:    {stRunning, "▌"},
	state.Waiting:    {stWaiting, "◆"},
	state.Compacting: {stCompact, "◌"},
	state.Idle:       {},
	state.Unknown:    {stUnknown, "?"},
}

// indicator is the glyph for an agent status, styled; "" for idle and for
// anything unknown.
func indicator(s state.Status) string {
	i, ok := indicators[s]
	if !ok || i.glyph == "" {
		return ""
	}
	return i.style.Render(i.glyph)
}

// indicatorDone is an agent idle since finishing a turn, not yet looked at;
// indicatorFailed a shell whose last command exited nonzero, likewise not
// yet looked at. Both are rendered on demand, for the reason above.
func indicatorDone() string   { return stDone.Render("✓") }
func indicatorFailed() string { return stErr.Render("▌") }

// indicatorGone marks a lingering subagent window: its process is dead and
// its record is already gone, so field("") - the "kido knows nothing about
// this pane" tell a plain uninstrumented shell earns - would say the wrong
// thing about a row kido actually knows more about than a live one (its
// name, and often its outcome). × is used nowhere else, so it cannot be
// confused with a live status, and it is dimmed the same as the row's own
// text, rendered on demand for the same package-init reason as the rest of
// this table.
func indicatorGone() string { return stDim.Render("×") }

// indicatorStalled marks a session state.Stalled reports as wedged,
// rendered on demand for the same reason as indicatorDone.
func indicatorStalled() string { return stStalled.Render("!") }

// field is the indicator column: one glyph and one space, or two spaces
// when there is no indicator, so every label starts at the same column
// whatever the pane is doing. Agent rows and shell rows with OSC 133 both
// go through it; a shell without the integration gets no field at all, and
// the missing offset is the tell that kido knows nothing about it.
func field(ind string) string {
	if ind == "" {
		return "  "
	}
	return ind + " "
}

// piPrefix is what pi puts before the title it sets: "π - <session> -
// <cwd>", or "π - <cwd>" when the session is unnamed. Only the marker is
// dropped; what the agent chose to name itself is shown whole.
const piPrefix = "π - "

// agentTitle extracts the session name from the pane title an agent sets,
// e.g. "✳ Tmux config" → "Tmux config" for Claude Code and "π - kido -
// internal" → "kido - internal" for pi. Anything else is left as it is.
// Falls back to "-".
//
// pi's marker is a letter as far as unicode is concerned, so it needs its
// own prefix test; Claude Code's keeps the older rule of trimming leading
// punctuation and symbols, which is what every Claude Code title kido has
// ever shown went through.
func agentTitle(title string) string {
	t, ok := strings.CutPrefix(title, piPrefix)
	if !ok {
		t = strings.TrimLeftFunc(title, func(r rune) bool {
			return !unicode.IsLetter(r) && !unicode.IsDigit(r)
		})
	}
	if t == "" {
		return "-"
	}
	return t
}

// agentTitleOf returns pane p's agent title and true when it is an agent
// pane (one that reported, one running claude, or one running pi without
// having reported); otherwise "", false.
//
// A recorded Title (from kido agent-status --title) wins over the pane
// title: it is the exact name the agent reported, not something kido must
// guess at by stripping a marker off whatever the agent painted in the
// terminal title, and splitting on a fixed marker cannot be fooled by a
// session name that happens to contain one. Claude Code never records a
// Title, so its rows keep going through agentTitle(p.Title) unchanged. An
// agent that reports no title (or hasn't reported at all yet) falls back
// to the pane title the same way.
func (m *model) agentTitleOf(p tmux.Pane) (string, bool) {
	if !state.IsAgentPane(m.snap.states, m.snap.pi, p) {
		return "", false
	}
	if s, ok := m.snap.states[p.PaneID]; ok && s.Title != "" {
		return s.Title, true
	}
	return agentTitle(p.Title), true
}

// interactivePane reports whether a program has taken pane p's terminal,
// so kido has nothing to say about it: it runs for as long as the user is
// working in it, and "a command is running" is not news. tmux answers that
// directly - taking the screen means switching to the alternate buffer -
// and answers it for the innermost program, where pane_current_command
// would name the process group leader (git, for a pager; sudo, for an
// editor under it). An ssh sitting at a remote shell takes no alternate
// buffer of its own, so it is decided from its arguments instead; a
// full-screen program on the far side still shows here.
func (m *model) interactivePane(p tmux.Pane) bool {
	if sess, ok := m.snap.ssh[p.PanePID]; ok && sess.Interactive {
		return true
	}
	return p.AlternateOn
}

// lingeringLabel is the row text for a lingering subagent window's pane -
// one carrying tmux.SubagentOption whose run has no live record for this
// pane (see lingeringSubagents, which does the file reads this only looks
// up) - or "", false when p is not one. Dimming the whole label, name and
// outcome alike, says "not interactive" the same way stDim already does
// for the tree's own stems and an agent's activity text; the × in the
// field column is what actually says "dead", since a dim row inside an
// already-dim nested block does not otherwise stand out at a glance.
func (m *model) lingeringLabel(p tmux.Pane) (string, bool) {
	runID := tmux.SubagentRunID(p.Subagent)
	if runID == "" {
		return "", false
	}
	l, ok := m.snap.lingering[runID]
	if !ok {
		return "", false
	}
	label := field(indicatorGone()) + stDim.Render(l.name)
	if l.outcomeOK {
		label += "  " + stDim.Render(string(l.outcome))
	}
	return label, true
}

// paneLabel is the row text for a pane: its foreground command, or an
// agent pane's session title, both behind the same two-column indicator
// field. Which agent it is makes no difference to the row.
func (m *model) paneLabel(p tmux.Pane) string {
	title, isAgent := m.agentTitleOf(p)
	if !isAgent {
		if label, ok := m.lingeringLabel(p); ok {
			return label
		}
		text := stProc.Render(p.CurrentCommand)
		if sess, ok := m.snap.ssh[p.PanePID]; ok {
			text = stProc.Render("ssh ") + sess.Host
		}
		// A shell with kido's OSC 133 integration (shell/zsh, installed
		// by `kido setup-zsh`) gets the same indicators an agent pane
		// has: running, done, or the last command having failed. A shell
		// without it says nothing, and its row stays exactly as it always
		// was, field and all.
		if _, ok := p.ShellStatus(); !ok {
			return text
		}
		if m.interactivePane(p) {
			// The field stays, so the row still lines up with the other
			// integrated shells; only the glyph goes.
			return field("") + text
		}
		return field(m.shellIndicator(m.phases[p.PaneID])) + text
	}
	ind := indicator(state.Unknown) // an agent pane that has not reported
	var activity string
	if s, reported := m.snap.states[p.PaneID]; reported {
		ind = indicator(s.Status)
		activity = s.Activity
		if state.Stalled(s, m.at) {
			ind = indicatorStalled()
		}
	}
	if m.done(p.PaneID) {
		ind = indicatorDone()
	}
	label := field(ind) + title
	if activity != "" {
		label += "  " + stDim.Render(activity)
	}
	return label
}

// windowAgent is the pane of w whose record has a place in the spawn
// tree and that record, or the zero pane and Session for a window with
// none. The pane matters and not just the record: a subagent's window is
// drawn under the row of the pane its parent runs in, not under the
// parent's window.
func windowAgent(w []tmux.Pane, states map[string]state.Session) (tmux.Pane, state.Session) {
	for _, p := range w {
		if s, ok := states[p.PaneID]; ok && (s.Instance != "" || s.ParentInstance != "") {
			return p, s
		}
	}
	return tmux.Pane{}, state.Session{}
}

// markParentOf is the parent instance carried in w's window mark
// (tmux.SubagentOption), read by orderWindowsByTree only once windowAgent
// finds no record at all: it is the fallback, not the source of truth.
func markParentOf(w []tmux.Pane) string {
	for _, p := range w {
		if id := tmux.SubagentParentInstance(p.Subagent); id != "" {
			return id
		}
	}
	return ""
}

// windowPlacement is where one window sits in the sidebar tree: its
// panes, how deep the walk put it, and the pane row it hangs off - the
// pane of the agent that spawned it, or "" for a window drawn as a root.
type windowPlacement struct {
	panes  []tmux.Pane
	depth  int
	anchor string // pane id of the spawning agent; "" for a root
}

// orderWindowsByTree places a session's windows in the spawn tree: a
// subagent's window follows the pane of whatever agent spawned it,
// recursively. Both the anchor and the depth come from this walk, never
// from the agent's reported Depth: a subagent whose parent is in another
// session, or gone, still reports depth 1, and must not be drawn under a
// row it has no edge to.
//
// The parent normally comes from the agent's own state record
// (ParentInstance); a window whose record is gone - a finished subagent
// lingering for the sweep - falls back to its window mark instead, so it
// keeps its place in the tree for the whole linger rather than un-nesting
// to the left margin the instant its record is removed. See markParentOf.
func orderWindowsByTree(windows [][]tmux.Pane, states map[string]state.Session) []windowPlacement {
	byInstance := map[string]string{} // instance -> window id of the window holding it
	anchors := map[string]string{}    // window id -> pane its agent runs in
	for _, w := range windows {
		p, s := windowAgent(w, states)
		if s.Instance == "" {
			continue
		}
		byInstance[s.Instance] = w[0].WindowID
		anchors[w[0].WindowID] = p.PaneID
	}
	parentOf := func(w []tmux.Pane) string {
		_, s := windowAgent(w, states)
		parentInstance := s.ParentInstance
		if s.Instance == "" && s.ParentInstance == "" {
			// No agent record at all for this window - the common case is a
			// subagent that reported --remove on exit while its window still
			// lingers for the sweep. The mark outlives the record, so fall
			// back to it. A window with any record instead follows the
			// record even when it disagrees with the mark: a live subagent
			// can move or be reparented (kido spawn --resume), and the mark
			// is written once at window creation and never rewritten to
			// match.
			parentInstance = markParentOf(w)
		}
		return byInstance[parentInstance]
	}
	ordered := tree.Order(windows,
		func(w []tmux.Pane) string { return w[0].WindowID },
		parentOf)

	// Order emits a window after its parent, or as a root with no parent
	// yet seen (a ring, or a parent outside this session), so one pass
	// suffices and a cycle cannot recurse. A window whose parent is not
	// already placed is a root, anchor and all: the anchor is only ever
	// an edge the walk itself found.
	out := make([]windowPlacement, 0, len(ordered))
	depth := make(map[string]int, len(ordered))
	for _, w := range ordered {
		pl := windowPlacement{panes: w}
		if d, ok := depth[parentOf(w)]; ok {
			pl.depth, pl.anchor = d+1, anchors[parentOf(w)]
		}
		depth[w[0].WindowID] = pl.depth
		out = append(out, pl)
	}
	return out
}

// appendWindows draws one session's windows, each window's panes joined
// into a column by the ┌ ├ └ glyphs, with a subagent's window nested
// directly under the row of the pane that spawned it.
//
// Nesting cuts the parent window's column in two, so the column is
// carried on down the left of the child's rows with a │ stem rather than
// restarted: a three-pane window with a subagent hanging off its middle
// pane reads as one bracket with an indented block inside it, which is
// what it is. The stem stops as soon as the parent has no rows left
// below, so a child of the last pane hangs free.
//
// The price is that a window hoisted under a parent's pane no longer
// appears in tmux's own window order - a subagent's window can sit above
// a lower-numbered one, and a parent's own later panes sit below a whole
// foreign window. That is deliberate: the spawn tree is what the sidebar
// is for, and tmux's order is still one ⇧↓ away.
func (m *model) appendWindows(placements []windowPlacement) {
	byAnchor := map[string][]int{}
	for i, pl := range placements {
		if pl.anchor != "" {
			byAnchor[pl.anchor] = append(byAnchor[pl.anchor], i)
		}
	}
	drawn := make([]bool, len(placements))
	var emit func(i int, prefix string)
	emit = func(i int, prefix string) {
		if drawn[i] {
			return
		}
		drawn[i] = true
		panes := placements[i].panes
		for j, p := range panes {
			m.rows = append(m.rows, row{
				text:   prefix + glyph(j, len(panes)) + " " + m.paneLabel(p),
				paneID: p.PaneID,
			})
			nested := prefix + continuation(j, len(panes)) + " "
			for _, k := range byAnchor[p.PaneID] {
				emit(k, nested)
			}
		}
	}
	// A window whose anchor row was never drawn - an anchor pane that has
	// gone, a ring the walk broke - is drawn as a root here rather than
	// dropped: a missing row is an agent nobody can see.
	for i := range placements {
		emit(i, "")
	}
}

func (m *model) rebuild() {
	prev := ""
	if m.cursor >= 0 && m.cursor < len(m.rows) {
		prev = m.rows[m.cursor].paneID
	}
	m.rows = m.rows[:0]

	if m.snap.err != nil {
		m.rows = append(m.rows, row{text: stErr.Render(m.snap.err.Error())})
		m.cursor = -1
		return
	}

	order := tmux.OrderSessions(m.snap.panes)
	if m.filter != "" {
		// A session matches when its name, a Claude pane's title, or an
		// ssh pane's destination fuzzy-matches; best matches first,
		// non-matching sessions drop out. A session that matches via a
		// pane keeps all its panes. Plain foreground commands are not
		// searchable text.
		var texts []string
		var owner []int // index into order
		for i, s := range order {
			texts = append(texts, s.Name)
			owner = append(owner, i)
			for _, w := range s.Windows {
				for _, p := range w {
					if title, ok := m.agentTitleOf(p); ok {
						texts = append(texts, title)
						owner = append(owner, i)
					} else if sess, ok := m.snap.ssh[p.PanePID]; ok {
						texts = append(texts, sess.Host)
						owner = append(owner, i)
					}
				}
			}
		}
		best := map[int]int{}
		matched := map[int]bool{}
		for _, match := range fuzzy.Find(m.filter, texts) {
			i := owner[match.Index]
			if !matched[i] || match.Score > best[i] {
				best[i] = match.Score
			}
			matched[i] = true
		}
		var ranked []int // indices into order, so the score stays with the session
		for i := range order {
			if matched[i] {
				ranked = append(ranked, i)
			}
		}
		sort.SliceStable(ranked, func(a, b int) bool {
			return best[ranked[a]] > best[ranked[b]]
		})
		sessions := make([]tmux.Session, 0, len(ranked))
		for _, i := range ranked {
			sessions = append(sessions, order[i])
		}
		order = sessions
	}

	for _, s := range order {
		name := s.Name
		if name == m.snap.current {
			name = stCurrent.Render(name)
		}
		m.rows = append(m.rows, row{text: name})

		m.appendWindows(orderWindowsByTree(s.Windows, m.snap.states))
	}

	if m.cursor = m.indexOf(prev); m.cursor < 0 {
		m.move(1)
	}
	m.clampTop()
}

func (m model) View() string {
	var b strings.Builder
	h := m.viewRows()
	for i := m.top; i < len(m.rows) && i-m.top < h; i++ {
		line := m.rows[i].text
		if m.width > 0 {
			line = ansi.Truncate(line, m.width, "…")
		}
		if i == m.cursor {
			// Invert the whole row; drop inner colours so the inversion
			// is uniform across it.
			line = stCursor.Width(m.width).Render(ansi.Strip(line))
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	for n := len(m.rows) - m.top; n < h; n++ {
		b.WriteByte('\n') // keep the bottom line in place below short lists
	}
	switch {
	case m.status != "":
		b.WriteString(stErr.Render(m.status))
	case m.searching:
		b.WriteString(stDim.Render("/") + m.filter)
	}
	return b.String()
}

// outcomeIndicator is the glyph for a finished command's exit status.
func outcomeIndicator(status int) string {
	if status == 0 {
		return indicatorDone()
	}
	return indicatorFailed()
}
