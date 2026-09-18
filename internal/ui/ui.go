// Package ui is the Bubble Tea sidebar: sessions and their panes, with
// Claude Code panes badged by their hook-reported status.
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
	probed  time.Time      // when the process table was last read
	err     error
}

// sshProbe is the shortest gap between two reads of the process table.
// Panes running ssh are looked up there, and at a 100ms tick an
// unresolvable one would otherwise mean ten ps calls a second.
const sshProbe = time.Second

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

	// A Claude session whose turn ended after its pane was last looked at
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

// take gathers a snapshot. prev is the last one: its ssh map spares the
// process table, which is only re-read when a pane runs ssh that the map
// does not cover and the last read is old enough.
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
	s.ssh = map[int]string{}
	s.probed = prev.probed
	hosts, read := prev.ssh, false
	for _, p := range s.panes {
		if p.CurrentCommand != "ssh" {
			continue
		}
		if _, ok := hosts[p.PanePID]; !ok && !read && time.Since(s.probed) >= sshProbe {
			hosts, read = procs.SSHHosts(), true
			s.probed = time.Now()
		}
		if host, ok := hosts[p.PanePID]; ok {
			s.ssh[p.PanePID] = host
		}
	}
	s.states, s.err = state.Load()
	return s
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
		slices.Equal(a.panes, b.panes) && maps.Equal(a.states, b.states) && maps.Equal(a.ssh, b.ssh)
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

// done reports whether pane's Claude session finished a turn since the
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

// wants reports whether pane's Claude session needs the user: it is
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

	// Glyphs grouping a window's panes: a dot for a lone pane, else a
	// bracket spanning the window's rows.
	glyphLone, glyphFirst, glyphMid, glyphLast = stDim.Render("·"), stDim.Render("┌"), stDim.Render("├"), stDim.Render("└")
)

func glyph(i, n int) string {
	switch {
	case n == 1:
		return glyphLone
	case i == 0:
		return glyphFirst
	case i == n-1:
		return glyphLast
	default:
		return glyphMid
	}
}

// indicators mark a Claude Code pane by its status; the glyph alone says
// it is an agent session.
var (
	indicators = map[state.Status]string{
		state.Running:    stRunning.Render("●"),
		state.Waiting:    stWaiting.Render("◆"),
		state.Compacting: stCompact.Render("◌"),
		state.Idle:       stIdle.Render("○"),
		state.Unknown:    stUnknown.Render("?"),
	}
	indicatorDone = stDone.Render("✓") // idle since finishing, not yet looked at
)

// claudeTitle extracts the session name from the pane title Claude Code
// sets, e.g. "✳ Tmux config" → "Tmux config". Falls back to "-".
func claudeTitle(title string) string {
	t := strings.TrimLeftFunc(title, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	if t == "" {
		return "-"
	}
	return t
}

// claudeTitleOf returns pane p's Claude Code title and true when it is a
// Claude Code pane (one a hook reported, or one running claude without hook
// data); otherwise "", false.
func (m *model) claudeTitleOf(p tmux.Pane) (string, bool) {
	_, hooked := m.snap.states[p.PaneID]
	if !hooked && p.CurrentCommand != "claude" {
		return "", false
	}
	return claudeTitle(p.Title), true
}

// paneLabel is the row text for a pane: its foreground command, or for a
// Claude Code pane, a status indicator and the session title.
func (m *model) paneLabel(p tmux.Pane) string {
	title, isClaude := m.claudeTitleOf(p)
	if !isClaude {
		if host, ok := m.snap.ssh[p.PanePID]; ok {
			return stProc.Render("ssh ") + host
		}
		return stProc.Render(p.CurrentCommand)
	}
	s, hooked := m.snap.states[p.PaneID]
	ind := indicators[state.Unknown]
	if hooked {
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

	// Group by session, oldest first, then by window in tmux's order.
	type sess struct {
		name    string
		created int64
		panes   []tmux.Pane
	}
	var order []*sess
	bySess := map[string]*sess{}
	for _, p := range m.snap.panes {
		s, ok := bySess[p.SessionName]
		if !ok {
			s = &sess{name: p.SessionName, created: p.SessionCreated}
			bySess[p.SessionName] = s
			order = append(order, s)
		}
		s.panes = append(s.panes, p)
	}
	sort.SliceStable(order, func(i, j int) bool {
		if order[i].created != order[j].created {
			return order[i].created < order[j].created
		}
		return order[i].name < order[j].name
	})
	if m.filter != "" {
		// A session matches when its name or a Claude pane's title
		// fuzzy-matches; best matches first, non-matching sessions drop
		// out. A session that matches via a pane keeps all its panes.
		var texts []string
		var owner []*sess
		for _, s := range order {
			texts = append(texts, s.name)
			owner = append(owner, s)
			for _, p := range s.panes {
				if title, ok := m.claudeTitleOf(p); ok {
					texts = append(texts, title)
					owner = append(owner, s)
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

		var windows [][]tmux.Pane
		for _, p := range s.panes {
			n := len(windows)
			if n == 0 || windows[n-1][0].WindowIndex != p.WindowIndex {
				windows = append(windows, nil)
				n++
			}
			windows[n-1] = append(windows[n-1], p)
		}
		for _, panes := range windows {
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
