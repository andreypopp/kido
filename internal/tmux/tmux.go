// Package tmux reads pane/window/session topology from a running tmux server.
package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Pane is one tmux pane plus the window/session it belongs to.
type Pane struct {
	SessionName     string
	SessionID       string
	SessionAttached bool
	SessionCreated  int64 // unix time
	WindowIndex     int
	WindowName      string
	WindowActive    bool
	PaneID          string // e.g. "%18"
	PaneIndex       int
	PanePID         int
	PaneActive      bool
	CurrentCommand  string
	CurrentPath     string
	Sidebar         bool // @kido=1: a kido sidebar pane
	Title           string
}

// Socket, when set, is passed to every tmux invocation as -S. Needed when
// kido is launched from a tmux hook, whose environment does not carry the
// server's socket.
var Socket string

func command(args ...string) *exec.Cmd {
	if Socket != "" {
		args = append([]string{"-S", Socket}, args...)
	}
	return exec.Command(binary(), args...)
}

var binaryOnce sync.Once
var binaryPath = "tmux"

// binary returns the tmux executable to run: the one running the server
// named by $TMUX when it can be found (so a patched tmux talks to itself),
// else whatever "tmux" resolves to on PATH.
func binary() string {
	binaryOnce.Do(func() {
		f := strings.Split(os.Getenv("TMUX"), ",")
		if len(f) < 2 {
			return
		}
		out, err := exec.Command("ps", "-o", "comm=", "-p", f[1]).Output()
		if err != nil {
			return
		}
		p := strings.TrimSpace(string(out))
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			binaryPath = p
		}
	})
	return binaryPath
}

const sep = "\x1f"

// pane_title is last because it may contain anything.
var format = strings.Join([]string{
	"#{session_name}",
	"#{session_id}",
	"#{session_attached}",
	"#{session_created}",
	"#{window_index}",
	"#{window_name}",
	"#{window_active}",
	"#{pane_id}",
	"#{pane_index}",
	"#{pane_pid}",
	"#{pane_active}",
	"#{pane_current_command}",
	"#{pane_current_path}",
	"#{@kido}",
	"#{pane_title}",
}, sep)

// ListPanes returns every pane on the server, in tmux's own order.
func ListPanes() ([]Pane, error) {
	out, err := command("list-panes", "-a", "-F", format).Output()
	if err != nil {
		return nil, fmt.Errorf("tmux list-panes: %w", err)
	}
	var panes []Pane
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		f := strings.SplitN(line, sep, 15)
		if len(f) < 15 {
			continue
		}
		p := Pane{
			SessionName:     f[0],
			SessionID:       f[1],
			SessionAttached: f[2] != "0",
			WindowName:      f[5],
			WindowActive:    f[6] == "1",
			PaneID:          f[7],
			PaneActive:      f[10] == "1",
			CurrentCommand:  f[11],
			CurrentPath:     f[12],
			Sidebar:         f[13] == "1",
			Title:           f[14],
		}
		p.SessionCreated, _ = strconv.ParseInt(f[3], 10, 64)
		p.WindowIndex, _ = strconv.Atoi(f[4])
		p.PaneIndex, _ = strconv.Atoi(f[8])
		p.PanePID, _ = strconv.Atoi(f[9])
		panes = append(panes, p)
	}
	return panes, nil
}

// CurrentClient asks tmux which client this process belongs to. Works from a
// pane and from inside a display-popup, where TMUX_PANE is unset.
func CurrentClient() string {
	out, err := command("display-message", "-p", "#{client_name}").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ClientFor returns the client currently attached to the session containing
// pane, preferring the most recently active one. Empty if none is attached.
func ClientFor(pane string) string {
	sess, err := tmuxOut("display-message", "-p", "-t", pane, "#{session_id}")
	if err != nil {
		return ""
	}
	out, err := tmuxOut("list-clients", "-F", "#{client_name}\t#{session_id}\t#{client_activity}")
	if err != nil {
		return ""
	}
	best, bestAct := "", int64(-1)
	for _, line := range strings.Split(out, "\n") {
		f := strings.Split(line, "\t")
		if len(f) != 3 || f[1] != sess {
			continue
		}
		act, _ := strconv.ParseInt(f[2], 10, 64)
		if act > bestAct {
			best, bestAct = f[0], act
		}
	}
	return best
}

// ClientState returns the session name and active pane id of client (or
// the current client) in one round trip.
func ClientState(client string) (session, pane string) {
	args := []string{"display-message", "-p"}
	if client != "" {
		args = append(args, "-c", client)
	}
	out, err := tmuxOut(append(args, "#{session_name}\t#{pane_id}")...)
	if err != nil {
		return "", ""
	}
	f := strings.SplitN(out, "\t", 2)
	if len(f) != 2 {
		return "", ""
	}
	return f[0], f[1]
}

// ActivePane returns the active pane of client (or of the current client).
func ActivePane(client string) string {
	_, pane := ClientState(client)
	return pane
}

// ReleaseSideFocus hands keyboard focus from a tmux side status column
// (patched tmux) back to the client's active pane.
func ReleaseSideFocus(client string) error {
	args := []string{"refresh-client", "-f", "!side-focus"}
	if client != "" {
		args = append(args, "-t", client)
	}
	return command(args...).Run()
}

// Jump makes paneID the active pane of client (or the current client when
// empty), switching session and window as needed.
func Jump(client, paneID string) error {
	sw := []string{"switch-client", "-t", paneID}
	if client != "" {
		sw = append(sw, "-c", client)
	}
	cmds := [][]string{
		sw,
		{"select-window", "-t", paneID},
		{"select-pane", "-t", paneID},
	}
	for _, c := range cmds {
		if out, err := command(c...).CombinedOutput(); err != nil {
			return fmt.Errorf("tmux %s: %s", strings.Join(c, " "), strings.TrimSpace(string(out)))
		}
	}
	return nil
}

// ---- pinned sidebar, server-wide ------------------------------------------
//
// The on/off state lives in the server option @kido_sidebar. When on, every
// window in every session gets a sidebar pane (marked @kido=1) at the left
// with the same width. EnsureSidebar is run from tmux hooks so windows
// created later get one too.

const (
	sidebarOpt = "@kido_sidebar"
	busyOpt    = "@kido_busy" // unix time while kido is rearranging panes
	busyTTL    = 5            // seconds; a crashed run must not wedge hooks
)

// lock marks the server busy so kido runs spawned by the hooks that our own
// split/join/resize commands trigger exit without acting. Returns false if
// another run holds the lock.
func lock() bool {
	v, _ := tmuxOut("show-option", "-gqv", busyOpt)
	if ts, err := strconv.ParseInt(v, 10, 64); err == nil && time.Now().Unix()-ts < busyTTL {
		return false
	}
	_ = command("set-option", "-g", busyOpt, strconv.FormatInt(time.Now().Unix(), 10)).Run()
	return true
}

func unlock() { _ = command("set-option", "-gu", busyOpt).Run() }

func tmuxOut(args ...string) (string, error) {
	out, err := command(args...).Output()
	if err != nil {
		return "", fmt.Errorf("tmux %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out)), nil
}

// SidebarEnabled reports the server-wide sidebar state.
func SidebarEnabled() bool {
	v, _ := tmuxOut("show-option", "-gqv", sidebarOpt)
	return v == "1"
}

func setSidebarEnabled(on bool) error {
	v := "0"
	if on {
		v = "1"
	}
	return command("set-option", "-g", sidebarOpt, v).Run()
}

type winPane struct {
	window, pane    string
	active, sidebar bool
	left, top       int
	width, height   int
	winHeight       int
}

// allPanes lists every pane on the server with its window and sidebar mark.
func allPanes() ([]winPane, error) {
	// @kido is empty on ordinary panes; only newlines are trimmed so an
	// empty first or last field survives.
	raw, err := command("list-panes", "-a", "-F", "#{@kido}\t#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{window_height}").Output()
	if err != nil {
		return nil, fmt.Errorf("tmux list-panes: %w", err)
	}
	var ps []winPane
	for _, line := range strings.Split(strings.Trim(string(raw), "\n"), "\n") {
		f := strings.Split(line, "\t")
		if len(f) != 9 {
			continue
		}
		p := winPane{sidebar: f[0] == "1", window: f[1], pane: f[2], active: f[3] == "1"}
		p.left, _ = strconv.Atoi(f[4])
		p.top, _ = strconv.Atoi(f[5])
		p.width, _ = strconv.Atoi(f[6])
		p.height, _ = strconv.Atoi(f[7])
		p.winHeight, _ = strconv.Atoi(f[8])
		ps = append(ps, p)
	}
	return ps, nil
}

// windowOf returns the window id containing pane.
func windowOf(pane string) (string, error) {
	return tmuxOut("display-message", "-p", "-t", pane, "#{window_id}")
}

// addSidebar splits a sidebar into window, placing the cursor on focus.
// With detached the new pane does not become the window's active pane.
func addSidebar(window, focus string, width int, cmd string, detached bool) error {
	args := []string{"split-window", "-hbf", "-l", strconv.Itoa(width), "-t", window, "-P", "-F", "#{pane_id}"}
	if detached {
		args = append(args, "-d")
	}
	if focus != "" {
		cmd += " -focus " + focus
	}
	if Socket != "" {
		cmd += " -socket " + Socket
	}
	cmd += " -width " + strconv.Itoa(width)
	id, err := tmuxOut(append(args, cmd)...)
	if err != nil {
		return err
	}
	return command("set-option", "-p", "-t", id, "@kido", "1").Run()
}

// ToggleSidebar turns the server-wide sidebar on or off. When turning on,
// the sidebar in target's window is focused; the others are added detached.
func ToggleSidebar(target string, width int, cmd string) error {
	if target == "" {
		target = os.Getenv("TMUX_PANE")
	}
	if !lock() {
		return nil
	}
	defer unlock()
	panes, err := allPanes()
	if err != nil {
		return err
	}
	if SidebarEnabled() {
		if err := setSidebarEnabled(false); err != nil {
			return err
		}
		for _, p := range panes {
			if p.sidebar {
				_ = command("kill-pane", "-t", p.pane).Run()
			}
		}
		return nil
	}
	if err := setSidebarEnabled(true); err != nil {
		return err
	}
	cur := ""
	if target != "" {
		cur, _ = windowOf(target)
	}
	return ensureAll(panes, cur, target, width, cmd)
}

// EnsureSidebar adds a sidebar to windows lacking one while the sidebar is
// on, and keeps existing ones at width. With target set, only that pane's
// window is considered (fast path for hooks); otherwise every window.
func EnsureSidebar(target string, width int, cmd string) error {
	if !SidebarEnabled() {
		return nil
	}
	if !lock() {
		return nil
	}
	defer unlock()
	panes, err := allPanes()
	if err != nil {
		return err
	}
	if target != "" {
		w, err := windowOf(target)
		if err != nil {
			return err
		}
		var only []winPane
		for _, p := range panes {
			if p.window == w {
				only = append(only, p)
			}
		}
		panes = only
	}
	return ensureAll(panes, "", "", width, cmd)
}

// InPlace reports whether pane is a full-height pane of the given width at
// the left edge of its window.
func InPlace(pane string, width int) bool {
	out, err := tmuxOut("display-message", "-p", "-t", pane, "#{pane_left} #{pane_top} #{pane_height} #{window_height} #{pane_width}")
	if err != nil {
		return true // can't tell; don't thrash
	}
	f := strings.Fields(out)
	if len(f) != 5 {
		return true
	}
	return f[0] == "0" && f[1] == "0" && f[2] == f[3] && f[4] == strconv.Itoa(width)
}

// FocusSidebar selects the pinned sidebar of target's window when the
// pinned sidebar is on (creating it if missing); otherwise it opens the
// popup sidebar on the client showing target.
func FocusSidebar(target string, width int, cmd string) error {
	if target == "" {
		target = os.Getenv("TMUX_PANE")
	}
	if !SidebarEnabled() {
		args := []string{"display-popup", "-E", "-w", strconv.Itoa(width + 4), "-h", "90%", "-T", " kido "}
		if c := ClientFor(target); c != "" {
			args = append(args, "-c", c)
		}
		popup := cmd + " -popup"
		if Socket != "" {
			popup += " -socket " + Socket
		}
		return command(append(args, popup)...).Run()
	}
	if err := EnsureSidebar(target, width, cmd); err != nil {
		return err
	}
	w, err := windowOf(target)
	if err != nil {
		return err
	}
	panes, err := allPanes()
	if err != nil {
		return err
	}
	for _, p := range panes {
		if p.window == w && p.sidebar {
			return command("select-pane", "-t", p.pane).Run()
		}
	}
	return fmt.Errorf("no sidebar pane in window %s", w)
}

// ensureAll gives every window in panes a sidebar. The window curWindow
// gets a focused sidebar with the cursor on curPane; others get detached
// sidebars with the cursor on their active pane.
func ensureAll(panes []winPane, curWindow, curPane string, width int, cmd string) error {
	type win struct {
		has    bool
		active string
		side   winPane
		other  string // some non-sidebar pane, used as join-pane target
	}
	wins := map[string]*win{}
	var order []string
	for _, p := range panes {
		w, ok := wins[p.window]
		if !ok {
			w = &win{}
			wins[p.window] = w
			order = append(order, p.window)
		}
		if p.sidebar {
			w.has = true
			w.side = p
		} else {
			w.other = p.pane
			if p.active {
				w.active = p.pane
			}
		}
	}
	var firstErr error
	for _, id := range order {
		w := wins[id]
		if w.has {
			sb := w.side
			switch {
			case sb.left == 0 && sb.top == 0 && sb.height == sb.winHeight && sb.width == width:
				// in place
			case sb.left == 0 && sb.top == 0 && sb.height == sb.winHeight:
				_ = command("resize-pane", "-t", sb.pane, "-x", strconv.Itoa(width)).Run()
			case w.other != "":
				// A layout change moved it: re-join it as a full-height pane
				// at the left edge. join-pane needs a sibling as target.
				_ = command("join-pane", "-hbf", "-l", strconv.Itoa(width), "-d", "-s", sb.pane, "-t", w.other).Run()
			}
			continue
		}
		focus, detached := w.active, true
		if id == curWindow {
			focus, detached = curPane, false
		}
		if err := addSidebar(id, focus, width, cmd, detached); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
