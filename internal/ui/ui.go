// Package ui is the Bubble Tea sidebar: sessions and their panes, with
// Claude Code panes badged by their hook-reported status.
package ui

import (
	"sort"
	"strings"
	"time"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/sahilm/fuzzy"

	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
)

// Options configures the sidebar.
type Options struct {
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
	err     error
}

type row struct {
	text      string
	paneID    string // non-empty for selectable rows
	attention bool   // a Claude session waiting on you, or done unseen
}

type model struct {
	opts      Options
	snap      snapshot
	rows      []row
	cursor    int // index into rows; on a selectable row when any exist
	top       int // first row shown; moves only when the cursor leaves the view
	width     int
	height    int
	status    string // error shown on the last line
	filter    string // fuzzy filter on session names; empty shows all
	searching bool   // "/" pressed: typing edits the filter
	gPend     bool   // a "g" was typed: "gg" goes to the top

	// Claude panes seen working; when one goes idle while it is not the
	// active pane it counts as done until the user visits it.
	busy map[string]bool
	done map[string]bool
}

// Run starts the sidebar and blocks until it exits.
func Run(opts Options) error {
	m := model{opts: opts, snap: take(opts.Client), busy: map[string]bool{}, done: map[string]bool{}}
	m.track()
	m.rebuild()
	m.focus(m.snap.active)
	_, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	return err
}

func take(client string) snapshot {
	var s snapshot
	s.current, s.focused = tmux.ClientState(client)
	if s.panes, s.err = tmux.ListPanes(); s.err != nil {
		return s
	}
	s.active = tmux.ActivePane(s.panes, s.current)
	var sshPanes []int
	for _, p := range s.panes {
		if p.CurrentCommand == "ssh" {
			sshPanes = append(sshPanes, p.PanePID)
		}
	}
	s.ssh = procs.SSHHosts(sshPanes)
	s.states, s.err = state.Load()
	return s
}

// tick waits, then takes a snapshot in the background.
func (m model) tick() tea.Cmd {
	client, d := m.opts.Client, m.opts.Interval
	return tea.Tick(d, func(time.Time) tea.Msg { return take(client) })
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
		m.rebuild()
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
		// Runes that arrive together (fast typing, send-keys) come as one
		// message; outside a search each is a separate command.
		if !m.searching && msg.Type == tea.KeyRunes && len(msg.Runes) > 1 {
			var mm tea.Model = m
			var cmd tea.Cmd
			for _, r := range msg.Runes {
				mm, cmd = mm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
			}
			return mm, cmd
		}
		key := msg.String()
		// Keys that work the same whether or not a search is being typed.
		switch key {
		case "ctrl+j", "ctrl+n", "down":
			m.move(1)
			return m, nil
		case "ctrl+k", "ctrl+p", "up":
			m.move(-1)
			return m, nil
		case "enter":
			m.jump()
			return m, nil
		}
		if m.searching {
			switch key {
			case "esc", "ctrl+c":
				m.searching = false
				m.setFilter("")
			case "backspace":
				if r := []rune(m.filter); len(r) > 0 {
					m.setFilter(string(r[:len(r)-1]))
				} else {
					m.searching = false // nothing left to erase: leave search
				}
			default:
				if msg.Type == tea.KeyRunes && !msg.Alt {
					m.setFilter(m.filter + string(msg.Runes))
				}
			}
			return m, nil
		}
		// "gg" goes to the top.
		if m.gPend {
			m.gPend = false
			if key == "g" {
				m.cursor = -1
				m.move(1)
			}
			return m, nil
		}
		switch key {
		case "/":
			m.searching = true
			m.setFilter("")
		case "esc", "ctrl+c":
			if m.filter != "" {
				m.setFilter("")
			} else if err := tmux.ReleaseSideFocus(m.opts.Client); err != nil {
				m.status = err.Error()
			} else {
				m.focus(m.snap.active)
			}
		case "j":
			m.move(1)
		case "k":
			m.move(-1)
		case "n":
			m.nextAttention(1)
		case "N":
			m.nextAttention(-1)
		case "g":
			m.gPend = true
		case "G", "end":
			m.cursor = len(m.rows)
			m.move(-1)
		case "home":
			m.cursor = -1
			m.move(1)
		}
	}
	return m, nil
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
	m.searching = false
	if m.filter != "" {
		m.setFilter("")
		m.focus(pane)
	}
}

func (m *model) setFilter(f string) {
	m.filter = f
	m.rebuild()
}

// track updates the done bookkeeping from the latest snapshot.
func (m *model) track() {
	for pane, s := range m.snap.states {
		switch s.Status {
		case state.Running, state.Waiting, state.Compacting:
			m.busy[pane] = true
			m.done[pane] = false
		case state.Idle:
			if m.busy[pane] && pane != m.snap.active {
				m.done[pane] = true
			}
			m.busy[pane] = false
		}
	}
	// Visiting the pane is what marks it seen.
	if m.snap.active != "" {
		m.done[m.snap.active] = false
	}
}

// nextAttention moves the cursor to the next row needing attention, in
// the given direction, wrapping around.
func (m *model) nextAttention(delta int) {
	n := len(m.rows)
	for step := 1; step <= n; step++ {
		i := ((m.cursor+delta*step)%n + n) % n
		if m.rows[i].attention {
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

// indicator marks a Claude Code pane by its status; the glyph alone says
// it is an agent session. done is an idle session that finished while
// its pane was not being looked at.
func indicator(s state.Status, done bool) string {
	if done {
		return stDone.Render("✓")
	}
	switch s {
	case state.Running:
		return stRunning.Render("●")
	case state.Waiting:
		return stWaiting.Render("◆")
	case state.Compacting:
		return stCompact.Render("◌")
	case state.Idle:
		return stIdle.Render("○")
	default:
		return stUnknown.Render("?")
	}
}

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

// paneLabel is the row text for a pane: its foreground command, or for a
// Claude Code pane (one a hook reported, or one running claude without
// hook data), a status indicator and the session title. attention is
// whether the pane wants the user.
func (m *model) paneLabel(p tmux.Pane) (text string, attention bool) {
	s, hooked := m.snap.states[p.PaneID]
	if !hooked && p.CurrentCommand != "claude" {
		if host, ok := m.snap.ssh[p.PanePID]; ok {
			return stProc.Render("ssh ") + host, false
		}
		return stProc.Render(p.CurrentCommand), false
	}
	st := state.Unknown
	if hooked {
		st = s.Status
	}
	done := m.done[p.PaneID]
	return indicator(st, done) + " " + claudeTitle(p.Title), done || st == state.Waiting
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
		// Best matches first; non-matching sessions drop out.
		names := make([]string, len(order))
		for i, s := range order {
			names[i] = s.name
		}
		var ranked []*sess
		for _, match := range fuzzy.Find(m.filter, names) {
			ranked = append(ranked, order[match.Index])
		}
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
				text, attention := m.paneLabel(p)
				m.rows = append(m.rows, row{
					text:      glyph(i, len(panes)) + " " + text,
					paneID:    p.PaneID,
					attention: attention,
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
	case m.searching || m.filter != "":
		b.WriteString(stDim.Render("/") + m.filter)
	}
	return b.String()
}
