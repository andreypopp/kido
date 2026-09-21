// Package tmux talks to the tmux server that owns this process.
package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	binaryOnce sync.Once
	binaryPath = "tmux"
)

// binary returns the tmux executable to run: the one running the server
// named by $TMUX when it can be found (so a patched tmux talks to itself),
// else whatever "tmux" resolves to on PATH.
func binary() string {
	binaryOnce.Do(func() {
		f := strings.Split(os.Getenv("TMUX"), ",")
		if len(f) < 2 {
			return
		}
		pid := f[1]

		// Linux: /proc/<pid>/exe is a symlink to the absolute binary path,
		// unlike "ps -o comm=" which only reports the basename.
		if p, err := os.Readlink("/proc/" + pid + "/exe"); err == nil {
			if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
				binaryPath = p
				return
			}
		}

		out, err := exec.Command("ps", "-o", "comm=", "-p", pid).Output()
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

func run(args ...string) (string, error) {
	out, err := exec.Command(binary(), args...).Output()
	if err != nil {
		return "", fmt.Errorf("tmux %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out)), nil
}

// Pane is one tmux pane plus the window and session it belongs to.
type Pane struct {
	SessionName    string
	SessionCreated int64 // unix time
	WindowIndex    int
	WindowID       string // e.g. "@7"; unique server-wide, unlike WindowIndex
	WindowName     string
	WindowLayout   string
	PaneID         string // e.g. "%18"
	Active         bool   // the session's current pane
	PanePID        int
	CurrentCommand string
	CurrentPath    string
	Title          string
}

const sep = "\x1f"

// pane_title is last because it may contain anything.
var paneFormat = strings.Join([]string{
	"#{session_name}",
	"#{session_created}",
	"#{window_index}",
	"#{window_id}",
	"#{window_name}",
	"#{window_layout}",
	"#{pane_id}",
	"#{&&:#{window_active},#{pane_active}}",
	"#{pane_pid}",
	"#{pane_current_command}",
	"#{pane_current_path}",
	"#{pane_title}",
}, sep)

// parsePanes turns list-panes output lines into panes. Shared by the exec
// and control-mode paths, which ask for the same format.
func parsePanes(lines []string) []Pane {
	var panes []Pane
	for _, line := range lines {
		f := strings.SplitN(line, sep, 12)
		if len(f) < 12 {
			continue
		}
		p := Pane{SessionName: f[0], WindowID: f[3], WindowName: f[4], WindowLayout: f[5],
			PaneID: f[6], Active: f[7] == "1", CurrentCommand: f[9],
			CurrentPath: f[10], Title: f[11]}
		p.SessionCreated, _ = strconv.ParseInt(f[1], 10, 64)
		p.WindowIndex, _ = strconv.Atoi(f[2])
		p.PanePID, _ = strconv.Atoi(f[8])
		panes = append(panes, p)
	}
	return panes
}

// OrderWindows groups panes into windows in kido's order: sessions oldest
// first, ties broken by name (SessionLess), and within a session each
// window's panes kept in ListPanes' own order (tmux's natural window
// order). This is kido's one true window order: the sidebar's grouping and
// `kido switch-window` both walk it, so they cannot drift apart. Each
// returned slice is one window's panes, in pane order, so windows[i][0]
// identifies the window (SessionName, WindowID).
func OrderWindows(panes []Pane) [][]Pane {
	type sess struct {
		name    string
		created int64
		panes   []Pane
	}
	var order []*sess
	bySess := map[string]*sess{}
	for _, p := range panes {
		s, ok := bySess[p.SessionName]
		if !ok {
			s = &sess{name: p.SessionName, created: p.SessionCreated}
			bySess[p.SessionName] = s
			order = append(order, s)
		}
		s.panes = append(s.panes, p)
	}
	sort.SliceStable(order, func(i, j int) bool {
		return SessionLess(
			Session{Name: order[i].name, Created: order[i].created},
			Session{Name: order[j].name, Created: order[j].created})
	})

	var windows [][]Pane
	for _, s := range order {
		var cur []Pane
		for _, p := range s.panes {
			if len(cur) > 0 && cur[0].WindowID != p.WindowID {
				windows = append(windows, cur)
				cur = nil
			}
			cur = append(cur, p)
		}
		if len(cur) > 0 {
			windows = append(windows, cur)
		}
	}
	return windows
}

// ListPanes returns every pane on the server, in tmux's own order.
func ListPanes() ([]Pane, error) {
	out, err := run("list-panes", "-a", "-F", paneFormat)
	if err != nil {
		return nil, err
	}
	return parsePanes(strings.Split(out, "\n")), nil
}

// CapturePane returns the visible contents of a pane as plain text, one
// line per screen row. Wrapped lines are deliberately not joined (-J):
// what the caller reads is the shape of the last few rows.
func CapturePane(pane string) ([]string, error) {
	out, err := run("capture-pane", "-p", "-t", pane)
	if err != nil {
		return nil, err
	}
	return strings.Split(out, "\n"), nil
}

// CurrentClient asks tmux which client this process belongs to. Used when
// kido is started by hand in a pane rather than by the side status line.
func CurrentClient() string {
	out, _ := run("display-message", "-p", "#{client_name}")
	return out
}

// Session is one tmux session, enough to order it the way the sidebar does.
type Session struct {
	Name    string
	Created int64 // unix time, #{session_created}
}

// SessionLess orders sessions oldest first (session_created), ties broken by
// name. This is kido's one true session order: the sidebar's grouping and
// `kido switch-session` both sort with it, so they cannot drift apart.
func SessionLess(a, b Session) bool {
	if a.Created != b.Created {
		return a.Created < b.Created
	}
	return a.Name < b.Name
}

// SortSessions orders sessions in place, oldest first, ties broken by name.
func SortSessions(sessions []Session) {
	sort.SliceStable(sessions, func(i, j int) bool { return SessionLess(sessions[i], sessions[j]) })
}

// sessionFormat is what ListSessions asks for, one line per session.
var sessionFormat = strings.Join([]string{
	"#{session_created}",
	"#{session_name}",
}, sep)

// parseSessions turns list-sessions output lines into sessions.
func parseSessions(lines []string) []Session {
	var sessions []Session
	for _, line := range lines {
		f := strings.SplitN(line, sep, 2)
		if len(f) < 2 {
			continue
		}
		s := Session{Name: f[1]}
		s.Created, _ = strconv.ParseInt(f[0], 10, 64)
		sessions = append(sessions, s)
	}
	return sessions
}

// ListSessions returns every session on the server, in tmux's own order (by
// name); pass the result to SortSessions for kido's order.
func ListSessions() ([]Session, error) {
	out, err := run("list-sessions", "-F", sessionFormat)
	if err != nil {
		return nil, err
	}
	return parseSessions(strings.Split(out, "\n")), nil
}

// SwitchSession switches client to the session adjacent to its current one
// in kido's order (oldest first, ties by name), wrapping around. next
// selects the following session, otherwise the preceding one. A server with
// one session, or a client not attached to any session kido can find, is a
// no-op.
func SwitchSession(client string, next bool) error {
	sessions, err := ListSessions()
	if err != nil {
		return err
	}
	if len(sessions) < 2 {
		return nil
	}
	SortSessions(sessions)

	current, _ := ClientState(client)
	i := -1
	for j, s := range sessions {
		if s.Name == current {
			i = j
			break
		}
	}
	if i < 0 {
		return nil
	}
	delta := -1
	if next {
		delta = 1
	}
	target := sessions[(i+delta+len(sessions))%len(sessions)]

	_, err = run("switch-client", "-c", client, "-t", target.Name)
	return err
}

// SwitchWindow switches client to the window adjacent to its current one in
// kido's order (OrderWindows: sessions oldest first, windows in tmux's own
// order within a session), wrapping around the whole server. This crosses
// session boundaries: advancing past a session's last window moves to the
// next session's first window, unlike tmux's own next-window/previous-window
// which wrap inside one session. A server with one window, or a client whose
// current window kido cannot find, is a no-op. Targeting a window in another
// session takes one tmux invocation: switch-client to the target's session,
// then select-window by window id (unique server-wide, unlike
// session:index), the way Jump does it.
func SwitchWindow(client string, next bool) error {
	panes, err := ListPanes()
	if err != nil {
		return err
	}
	windows := OrderWindows(panes)
	if len(windows) < 2 {
		return nil
	}

	session, _ := ClientState(client)
	activeWindowID := ""
	for _, p := range panes {
		if p.SessionName == session && p.Active {
			activeWindowID = p.WindowID
			break
		}
	}
	if activeWindowID == "" {
		return nil
	}
	i := -1
	for j, w := range windows {
		if w[0].WindowID == activeWindowID {
			i = j
			break
		}
	}
	if i < 0 {
		return nil
	}
	delta := -1
	if next {
		delta = 1
	}
	target := windows[(i+delta+len(windows))%len(windows)][0]

	_, err = run("switch-client", "-c", client, "-t", target.SessionName, ";",
		"select-window", "-t", target.WindowID)
	return err
}

// sideFocusFlag is the patched tmux's client flag that routes keys to the
// side status line's job.
const sideFocusFlag = "side-status-focus"

// clientFormat is what ClientState asks for, one line per client.
// display-message -c would be shorter, but it only honours -c for the
// formats when the target client happens to be on the command's own target
// session (cmd-display-message.c), which is not so over the control
// connection: that client has a session of its own.
var clientFormat = strings.Join([]string{
	"#{client_name}",
	"#{client_session}",
	"#{client_flags}",
}, sep)

// parseClientState picks client's line out of list-clients output.
func parseClientState(lines []string, client string) (session string, focused bool) {
	for _, line := range lines {
		f := strings.SplitN(line, sep, 3)
		if len(f) < 3 || f[0] != client {
			continue
		}
		return f[1], strings.Contains(f[2], sideFocusFlag)
	}
	return "", false
}

// ClientState returns the client's session and whether the side status
// line has its keyboard focus.
func ClientState(client string) (session string, focused bool) {
	out, err := run("list-clients", "-F", clientFormat)
	if err != nil {
		return "", false
	}
	return parseClientState(strings.Split(out, "\n"), client)
}

// ActivePane returns the pane ID of the active pane of session within
// panes, or "" if none is found.
func ActivePane(panes []Pane, session string) string {
	for _, p := range panes {
		if p.SessionName == session && p.Active {
			return p.PaneID
		}
	}
	return ""
}

// Jump makes paneID the active pane of client, switching session and
// window as needed, and hands it the keyboard.
//
// The side-focus flag is cleared here in every mode, standalone included.
// Clearing a flag a client does not have is a no-op, checked by hand on a
// server with side-status off, where the jump goes through unharmed; and
// when the client does happen to be showing a focused sidebar, a jump made
// from a popup should hand it the keyboard just as one made from the
// sidebar does. So there is nothing for a standalone kido to skip.
func Jump(client, paneID string) error {
	_, err := run("switch-client", "-c", client, "-t", paneID, ";",
		"select-window", "-t", paneID, ";",
		"select-pane", "-t", paneID, ";",
		"refresh-client", "-t", client, "-f", "!"+sideFocusFlag)
	return err
}

// ReleaseSideFocus hands keyboard focus from the side status line back to
// the client's active pane.
func ReleaseSideFocus(client string) error {
	_, err := run("refresh-client", "-t", client, "-f", "!"+sideFocusFlag)
	return err
}

// promptKeyDelay is the pause between typing a prompt's text and pressing
// Enter, mirroring ~/.config/ink/plugged/cctools/bin/ccsend: without it, a
// paste-sensitive reader (Claude Code included) can see the Enter as part
// of the pasted text rather than a submission.
const promptKeyDelay = 100 * time.Millisecond

// SendPrompt types text into pane as literal keys, then presses Enter
// after promptKeyDelay so it submits as a paste rather than being cut
// mid-line.
func SendPrompt(pane, text string) error {
	if _, err := run("send-keys", "-t", pane, "-l", text); err != nil {
		return err
	}
	time.Sleep(promptKeyDelay)
	_, err := run("send-keys", "-t", pane, "Enter")
	return err
}
