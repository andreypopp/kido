// Package ui is the Bubble Tea sidebar: sessions → panes → processes, with
// Claude Code panes badged by their hook-reported status.
package ui

import (
	"fmt"
	"os"
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
	Popup    bool   // quit after jumping (popup closes when the command exits)
	Client   string // tmux client to switch on jump; resolved via tmux when empty
	Focus    string // pane to put the cursor on at startup; client's active pane when empty
	Width    int    // pinned sidebar width, used to keep the pane in place
	Side     bool   // running inside a tmux side status column (no pane of our own)
	ShowSelf bool   // list the pane kido itself runs in
}

type tickMsg time.Time

type snapshot struct {
	current string // session the client is attached to
	active  string // the client's active pane
	panes   []tmux.Pane
	procs   *procs.Table
	states  map[string]state.Session
	err     error
	at      time.Time
}

type row struct {
	text   string
	paneID string // non-empty for selectable rows
}

type model struct {
	opts   Options
	self   string
	snap   snapshot
	rows   []row
	cursor int // index into rows; always on a selectable row when any exist
	top    int // first row shown; moves only when the cursor leaves the view
	width  int
	height int
	status string
	filter string // fuzzy filter on session names; empty shows all
}

// Run starts the sidebar and blocks until it exits.
func Run(opts Options) error {
	m := model{opts: opts}
	if !opts.Popup && !opts.Side {
		// Hide the pane the sidebar itself occupies. In a popup or a side
		// column there is no such pane; TMUX_PANE, if set, is inherited.
		m.self = os.Getenv("TMUX_PANE")
	}
	if m.opts.Focus == "" {
		m.opts.Focus = tmux.ActivePane(m.client())
	}
	m.snap = take(m.client())
	m.rebuild()
	m.focus(m.opts.Focus)
	_, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	return err
}

// keepInPlace moves a pinned sidebar back to the left edge when a layout
// command (rotate-window, swap-pane, select-layout...) displaced it. Hooks
// cover most cases, but rotate and swap fire none.
func (m *model) keepInPlace() {
	if m.self == "" || m.opts.Width <= 0 || tmux.InPlace(m.self, m.opts.Width) {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		exe = "kido"
	}
	_ = tmux.EnsureSidebar(m.self, m.opts.Width, exe)
}

// client resolves which tmux client to act on. An explicit -client wins;
// a pinned sidebar uses the client attached to its own session, which can
// change over time, so this is re-resolved on every use rather than cached.
func (m *model) client() string {
	if m.opts.Client != "" {
		return m.opts.Client
	}
	if m.self != "" {
		if c := tmux.ClientFor(m.self); c != "" {
			return c
		}
	}
	return tmux.CurrentClient()
}

func take(client string) snapshot {
	s := snapshot{at: time.Now()}
	s.current, s.active = tmux.ClientState(client)
	if s.panes, s.err = tmux.ListPanes(); s.err != nil {
		return s
	}
	if s.procs, s.err = procs.Snapshot(); s.err != nil {
		return s
	}
	s.states, s.err = state.Load()
	return s
}

func (m model) Init() tea.Cmd { return tick(m.opts.Interval) }

func tick(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ensureVisible()
	case tickMsg:
		m.keepInPlace()
		was := m.snap.active
		m.snap = take(m.client())
		m.rebuild()
		if m.snap.active != was && m.snap.active != "" {
			// The user switched panes in tmux: follow them.
			m.focus(m.snap.active)
		}
		return m, tick(m.opts.Interval)
	case tea.MouseMsg:
		// Click selects the row under the pointer and jumps; wheel moves.
		switch {
		case msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft:
			if i := m.rowAt(msg.Y); i >= 0 {
				m.cursor = i
				return m.jump()
			}
		case msg.Button == tea.MouseButtonWheelUp:
			m.scroll(-3)
		case msg.Button == tea.MouseButtonWheelDown:
			m.scroll(3)
		}
		return m, nil
	case tea.KeyMsg:
		// Runes that arrive in one read (pasted or sent with send-keys) come as
		// a single KeyMsg; handle them one at a time.
		if msg.Type == tea.KeyRunes && len(msg.Runes) > 1 {
			var cmd tea.Cmd
			var mm tea.Model = m
			for _, r := range msg.Runes {
				mm, cmd = mm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
				if cmd != nil {
					return mm, cmd
				}
			}
			return mm, nil
		}
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "esc":
			if m.filter != "" {
				m.setFilter("")
				break
			}
			if m.opts.Popup {
				return m, tea.Quit
			}
			if m.opts.Side {
				// Hand the keyboard back to the active pane.
				if err := tmux.ReleaseSideFocus(m.client()); err != nil {
					m.status = err.Error()
				}
			}
		case "ctrl+j", "ctrl+n", "down":
			m.move(1)
		case "ctrl+k", "ctrl+p", "up":
			m.move(-1)
		case "home":
			m.cursor = -1
			m.move(1)
		case "end":
			m.cursor = len(m.rows)
			m.move(-1)
		case "backspace":
			if m.filter != "" {
				r := []rune(m.filter)
				m.setFilter(string(r[:len(r)-1]))
			}
		case "enter":
			return m.jump()
		default:
			// Any other printable key narrows the session filter.
			if msg.Type == tea.KeyRunes && !msg.Alt {
				m.setFilter(m.filter + string(msg.Runes))
			}
		}
	}
	return m, nil
}

// setFilter changes the session filter and rebuilds the rows.
func (m *model) setFilter(f string) {
	m.filter = f
	m.rebuild()
	if m.cursor < 0 || m.cursor >= len(m.rows) || m.rows[m.cursor].paneID == "" {
		m.cursor = -1
		m.move(1)
	}
}

// jump switches the client to the pane under the cursor.
func (m model) jump() (tea.Model, tea.Cmd) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return m, nil
	}
	if err := tmux.Jump(m.client(), m.rows[m.cursor].paneID); err != nil {
		m.status = err.Error()
		return m, nil
	}
	if m.filter != "" {
		// Keep the chosen pane selected while the full list comes back.
		pane := m.rows[m.cursor].paneID
		m.setFilter("")
		m.focus(pane)
	}
	if m.opts.Popup {
		return m, tea.Quit
	}
	if m.opts.Side {
		// The pane is selected; give it the keyboard too.
		if err := tmux.ReleaseSideFocus(m.client()); err != nil {
			m.status = err.Error()
		}
	}
	return m, nil
}

// rowAt maps a screen line to a selectable row index, or -1.
func (m *model) rowAt(y int) int {
	i := m.top + y
	if i < 0 || i >= len(m.rows) || m.rows[i].paneID == "" {
		return -1
	}
	return i
}

// viewRows is how many rows fit; an error or the filter takes the last line.
func (m *model) viewRows() int {
	h := m.height
	if m.status != "" || m.filter != "" {
		h--
	}
	if h > 0 {
		return h
	}
	return len(m.rows)
}

// scroll moves the view by delta rows, keeping the cursor where it is.
func (m *model) scroll(delta int) {
	m.top += delta
	m.clampTop()
}

func (m *model) clampTop() {
	if max := len(m.rows) - m.viewRows(); m.top > max {
		m.top = max
	}
	if m.top < 0 {
		m.top = 0
	}
}

// scrollMargin is how many rows to keep visible beyond the cursor: the
// view starts moving when the cursor gets this close to an edge.
const scrollMargin = 3

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

// focus puts the cursor on paneID if it is listed.
func (m *model) focus(paneID string) {
	for i, r := range m.rows {
		if r.paneID != "" && r.paneID == paneID {
			m.cursor = i
			m.ensureVisible()
			return
		}
	}
}

func (m *model) move(delta int) {
	for i := m.cursor + delta; i >= 0 && i < len(m.rows); i += delta {
		if m.rows[i].paneID != "" {
			m.cursor = i
			m.ensureVisible()
			return
		}
	}
}

// ---- rendering -----------------------------------------------------------

var (
	stSession = lipgloss.NewStyle()
	stCurrent = lipgloss.NewStyle().Bold(true)
	stProc    = lipgloss.NewStyle().Foreground(lipgloss.Color("7"))
	stDim     = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	stClaude  = lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Bold(true)
	stCursor  = lipgloss.NewStyle().Reverse(true)
	stErr     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))

	stRunning = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	stWaiting = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Bold(true)
	stIdle    = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	stUnknown = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

func badge(s state.Status, age time.Duration) string {
	a := ""
	if age > 0 {
		a = " " + short(age)
	}
	switch s {
	case state.Running:
		return stRunning.Render("● running" + a)
	case state.Waiting:
		return stWaiting.Render("◆ waiting" + a)
	case state.Idle:
		return stIdle.Render("○ idle" + a)
	default:
		return stUnknown.Render("? no hook data")
	}
}

func short(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	}
}

// claudeStatus resolves the badge for a pane that hosts a claude process.
func (m *model) claudeStatus(paneID string) (state.Status, time.Duration) {
	s, ok := m.snap.states[paneID]
	if !ok {
		return state.Unknown, 0
	}
	// The hook records the claude pid; if it is gone the file is left over
	// from a session that died without firing SessionEnd.
	if s.PID != 0 && !m.snap.procs.Alive(s.PID) {
		return state.Unknown, 0
	}
	return s.Status, time.Since(s.TS).Truncate(time.Second)
}

func (m *model) rebuild() {
	prevPane := ""
	if m.cursor >= 0 && m.cursor < len(m.rows) {
		prevPane = m.rows[m.cursor].paneID
	}
	m.rows = m.rows[:0]

	if m.snap.err != nil {
		m.rows = append(m.rows, row{text: stErr.Render(m.snap.err.Error())})
		return
	}

	// Group by session, preserving tmux order.
	type sess struct {
		name     string
		attached bool
		created  int64
		panes    []tmux.Pane
	}
	var order []string
	bySess := map[string]*sess{}
	for _, p := range m.snap.panes {
		if !m.opts.ShowSelf && (p.PaneID == m.self || p.Sidebar || p.CurrentCommand == "kido") {
			continue
		}
		s, ok := bySess[p.SessionName]
		if !ok {
			s = &sess{name: p.SessionName, attached: p.SessionAttached, created: p.SessionCreated}
			bySess[p.SessionName] = s
			order = append(order, p.SessionName)
		}
		s.panes = append(s.panes, p)
	}
	// Oldest session first; names break ties.
	sort.SliceStable(order, func(i, j int) bool {
		a, b := bySess[order[i]], bySess[order[j]]
		if a.created != b.created {
			return a.created < b.created
		}
		return a.name < b.name
	})
	if m.filter != "" {
		// Best matches first; non-matching sessions drop out.
		var ranked []string
		for _, match := range fuzzy.Find(m.filter, order) {
			ranked = append(ranked, match.Str)
		}
		order = ranked
	}

	for _, name := range order {
		s := bySess[name]
		name := stSession.Render(s.name)
		if s.name == m.snap.current {
			name = stCurrent.Render(s.name)
		}
		m.rows = append(m.rows, row{text: name})

		// Group panes by window, keeping tmux's order.
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
					text:   stDim.Render(bracket(i, len(panes))) + " " + m.paneLabel(p),
					paneID: p.PaneID,
				})
			}
		}
	}

	// Restore cursor to the same pane, else first selectable row.
	m.cursor = -1
	for i, r := range m.rows {
		if r.paneID != "" && (m.cursor == -1 || r.paneID == prevPane) {
			m.cursor = i
			if r.paneID == prevPane {
				break
			}
		}
	}
}

// bracket is the glyph that groups a window's panes: a dot for a lone pane,
// else a bracket spanning the window's rows.
func bracket(i, n int) string {
	switch {
	case n == 1:
		return "·"
	case i == 0:
		return "┌"
	case i == n-1:
		return "└"
	default:
		return "├"
	}
}

// paneLabel is the row text for a pane: its foreground command, or for a
// pane running Claude Code, the session name and status badge.
func (m *model) paneLabel(p tmux.Pane) string {
	_, isClaude := m.snap.procs.FindDescendant(p.PanePID, "claude")
	if !isClaude {
		if t := m.snap.procs.Tree(p.PanePID); t != nil && t.Comm == "claude" {
			isClaude = true
		}
	}
	if !isClaude {
		return stProc.Render(p.CurrentCommand)
	}
	st, age := m.claudeStatus(p.PaneID)
	return stClaude.Render("claude") + " " + claudeTitle(p.Title) + " " + badge(st, age)
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

func (m model) View() string {
	var b strings.Builder
	h := m.viewRows()
	m.clampTop()
	start := m.top
	for i := start; i < len(m.rows) && i-start < h; i++ {
		line := m.rows[i].text
		if m.width > 0 {
			line = ansi.Truncate(line, m.width, "…")
		}
		if i == m.cursor {
			// Invert the whole row; drop inner colours so the inversion
			// is uniform across it.
			plain := ansi.Strip(line)
			if pad := m.width - lipgloss.Width(plain); pad > 0 {
				plain += strings.Repeat(" ", pad)
			}
			line = stCursor.Render(plain)
		}
		b.WriteString(line)
		b.WriteByte('\n')
	}
	switch {
	case m.status != "":
		b.WriteString(stErr.Render(m.status))
	case m.filter != "":
		b.WriteString(stDim.Render("/") + m.filter)
	}
	return strings.TrimRight(b.String(), "\n")
}
