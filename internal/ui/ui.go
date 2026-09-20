// Package ui is the Bubble Tea sidebar: sessions and their panes, with
// agent panes badged by the status the agent reported. Agents are not told
// apart on screen: a pi pane and a Claude Code pane are both an indicator
// and a title.
package ui

import (
	"maps"
	"slices"
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
	"kido/internal/state"
	"kido/internal/tmux"
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
}

// snapshot is everything the sidebar shows, taken off the UI goroutine.
type snapshot struct {
	current string // session the client is attached to
	active  string // the client's active pane
	focused bool   // the sidebar has the keyboard
	panes   []tmux.Pane
	states  map[string]state.Session
	ssh     map[int]string // pane pid -> ssh destination
	pi      map[int]bool   // pane pid -> pi runs in this pane
	probed  time.Time      // when the process table was last read
	err     error

	// probes remembers the last screen read of each waiting pane, so the
	// screen is read at most once per probeInterval rather than on every
	// tick. See screen.go.
	probes map[string]probe
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
	m := model{opts: opts, conn: conn, started: time.Now(), seen: map[string]time.Time{}}
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
		// Keep the control client attached to the same session as the
		// user's client, so tmux's per-attachment notifications
		// (%layout-change and friends) reach it too, not just the 100ms
		// tick. A no-op once they already agree; errors (the session is
		// gone) are left for the next tick to retry.
		conn.Follow(s.current)
	}
	if s.panes, s.err = listPanes(conn); s.err != nil {
		return s
	}
	s.active = tmux.ActivePane(s.panes, s.current)
	s.states, s.err = state.Load()
	s.ssh, s.pi = map[int]string{}, map[int]bool{}
	s.probed = prev.probed
	// The last sweep's answers stand until a pane asks something they do
	// not cover, and then only one fresh sweep is made per tick and at most
	// one per procsProbe: a faster tick must not mean more ps calls.
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
			if host, ok := scan.SSH[p.PanePID]; ok {
				s.ssh[p.PanePID] = host
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
		slices.Equal(a.panes, b.panes) && maps.Equal(a.states, b.states) &&
		maps.Equal(a.ssh, b.ssh) && maps.Equal(a.pi, b.pi)
}

func (m model) Init() tea.Cmd { return m.tick() }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ensureVisible()
	case snapshot:
		was := m.snap
		m.snap = msg
		m.track()
		if !msg.same(was) {
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
				m.jump()
			}
		case msg.Button == tea.MouseButtonWheelUp:
			m.top -= 3
			m.clampTop()
		case msg.Button == tea.MouseButtonWheelDown:
			m.top += 3
			m.clampTop()
		}
	case tea.KeyMsg:
		m.key(msg)
	}
	return m, nil
}

// key handles one key press.
func (m *model) key(msg tea.KeyMsg) {
	// Runes that arrive together (fast typing, send-keys) come as one
	// message; while searching they are all filter text, otherwise each
	// is a separate command.
	if msg.Type == tea.KeyRunes && !msg.Alt {
		if m.searching {
			m.setFilter(m.filter + string(msg.Runes))
			return
		}
		if len(msg.Runes) > 1 {
			for _, r := range msg.Runes {
				m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
			}
			return
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
		m.jump()
	case "esc", "ctrl+c":
		// Leave the search, or hand the keyboard back to the pane.
		if m.searching {
			m.searching = false
			m.setFilter("")
		} else if err := tmux.ReleaseSideFocus(m.opts.Client); err != nil {
			m.status = err.Error()
		} else {
			m.focus(m.snap.active)
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
}

// jump switches the client to the pane under the cursor, hands it the
// keyboard, and clears the filter with the pane still selected.
func (m *model) jump() {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return
	}
	pane := m.rows[m.cursor].paneID
	if err := tmux.Jump(m.opts.Client, pane); err != nil {
		m.status = err.Error()
		return
	}
	if m.searching {
		m.searching = false
		m.setFilter("")
		m.focus(pane)
	}
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

// track notes that the active pane is being looked at right now.
func (m *model) track() {
	if m.snap.active != "" {
		m.seen[m.snap.active] = time.Now()
	}
	for pane := range m.seen {
		if _, ok := m.snap.states[pane]; !ok {
			delete(m.seen, pane) // the session is gone
		}
	}
}

// done reports whether pane's agent session finished a turn since the
// pane was last looked at.
func (m *model) done(pane string) bool {
	s, ok := m.snap.states[pane]
	if !ok || s.Status != state.Idle || s.Ended.IsZero() {
		return false
	}
	seen, ok := m.seen[pane]
	if !ok {
		seen = m.started
	}
	return s.Ended.After(seen)
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

// ---- scrolling -------------------------------------------------------------

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

// ---- rows ------------------------------------------------------------------

var (
	stCurrent = lipgloss.NewStyle().Bold(true)
	stProc    = lipgloss.NewStyle().Foreground(lipgloss.Color("7"))
	stDim     = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	stCursor  = lipgloss.NewStyle().Reverse(true)
	stErr     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))

	stRunning = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	stWaiting = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true)
	stIdle    = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	stCompact = lipgloss.NewStyle().Foreground(lipgloss.Color("5"))
	stDone    = lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Bold(true)
	stUnknown = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
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

// indicators marks an agent pane by its status: the glyph alone says it is
// an agent session, the same for every agent.
var indicators = map[state.Status]string{
	state.Running:    stRunning.Render("●"),
	state.Waiting:    stWaiting.Render("◆"),
	state.Compacting: stCompact.Render("◌"),
	state.Idle:       stIdle.Render("○"),
	state.Unknown:    stUnknown.Render("?"),
}

var indicatorDone = stDone.Render("✓") // idle since finishing, not yet looked at

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

// paneLabel is the row text for a pane: its foreground command, or for an
// agent pane, a status indicator and the session title. Which agent it is
// makes no difference to the row.
func (m *model) paneLabel(p tmux.Pane) string {
	title, isAgent := m.agentTitleOf(p)
	if !isAgent {
		if host, ok := m.snap.ssh[p.PanePID]; ok {
			return stProc.Render("ssh ") + host
		}
		return stProc.Render(p.CurrentCommand)
	}
	s, reported := m.snap.states[p.PaneID]
	ind := indicators[state.Unknown]
	if reported {
		ind = indicators[s.Status]
	}
	if m.done(p.PaneID) {
		ind = indicatorDone
	}
	return ind + " " + title
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

	// Group by session, oldest first, then by window: tmux.OrderWindows is
	// kido's one true window order, shared with `kido switch-window` so the
	// two cannot drift apart.
	type sess struct {
		name    string
		windows [][]tmux.Pane
	}
	var order []*sess
	bySess := map[string]*sess{}
	for _, w := range tmux.OrderWindows(m.snap.panes) {
		name := w[0].SessionName
		s, ok := bySess[name]
		if !ok {
			s = &sess{name: name}
			bySess[name] = s
			order = append(order, s)
		}
		s.windows = append(s.windows, w)
	}
	if m.filter != "" {
		// A session matches when its name or a Claude pane's title
		// fuzzy-matches; best matches first, non-matching sessions drop
		// out. A session that matches via a pane keeps all its panes.
		var texts []string
		var owner []*sess
		for _, s := range order {
			texts = append(texts, s.name)
			owner = append(owner, s)
			for _, w := range s.windows {
				for _, p := range w {
					if title, ok := m.agentTitleOf(p); ok {
						texts = append(texts, title)
						owner = append(owner, s)
					}
				}
			}
		}
		best := map[*sess]int{}
		matched := map[*sess]bool{}
		for _, match := range fuzzy.Find(m.filter, texts) {
			s := owner[match.Index]
			if !matched[s] || match.Score > best[s] {
				best[s] = match.Score
			}
			matched[s] = true
		}
		var ranked []*sess
		for _, s := range order {
			if matched[s] {
				ranked = append(ranked, s)
			}
		}
		sort.SliceStable(ranked, func(i, j int) bool {
			return best[ranked[i]] > best[ranked[j]]
		})
		order = ranked
	}

	for _, s := range order {
		name := s.name
		if name == m.snap.current {
			name = stCurrent.Render(name)
		}
		m.rows = append(m.rows, row{text: name})

		for _, panes := range s.windows {
			for i, p := range panes {
				m.rows = append(m.rows, row{
					text:   glyph(i, len(panes)) + " " + m.paneLabel(p),
					paneID: p.PaneID,
				})
			}
		}
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
