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
	// OSC 133 shell integration, reported by tmux only for shells that
	// emit the markers (kido ships a zsh shim in shell/zsh). A shell that
	// never emits them leaves LastPromptTime zero; see ShellStatus.
	CommandRunning   bool
	CommandStartTime int64 // unix time of the last 133;C
	LastPromptTime   int64 // unix time of the last 133;A
	// The last finished command's exit status, from the last 133;D.
	// tmux prints pane_command_status empty when it has none (it keeps
	// -1 internally), so the flag is what tells "no status yet" from a
	// clean exit; CommandEndTime is the unix time of that 133;D.
	CommandStatus   int
	CommandStatusOK bool
	CommandEndTime  int64
	Title           string
}

// ShellStatus reports whether pane p is running a command right now, and
// whether its shell reports that at all.
//
// ok is false when the shell has no OSC 133 integration - no prompt has
// ever been marked - and then running means nothing: the caller must draw
// the pane exactly as it did before. Every pane started before the user
// loaded the shim is in that state.
//
// The running rule is deliberately not just CommandRunning. A program that
// emits 133;C and exits without the matching 133;D (pi does this, as does
// anything else with partial integration) would leave tmux believing a
// command is still running forever. The shell's own precmd emits 133;A at
// the next prompt, which puts LastPromptTime after CommandStartTime, and
// that is what heals such a pane back to idle.
func (p Pane) ShellStatus() (running, ok bool) {
	if p.LastPromptTime == 0 {
		return false, false
	}
	return p.CommandRunning && !(p.LastPromptTime > p.CommandStartTime), true
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
	// OSC 133. pane_command_duration is deliberately left out: it ticks
	// every second, which would defeat the snapshot change-detection.
	"#{pane_command_running}",
	"#{pane_command_start_time}",
	"#{pane_last_prompt_time}",
	"#{pane_command_status}",
	"#{pane_command_end_time}",
	"#{pane_title}",
}, sep)

// parsePanes turns list-panes output lines into panes. Shared by the exec
// and control-mode paths, which ask for the same format.
func parsePanes(lines []string) []Pane {
	var panes []Pane
	for _, line := range lines {
		f := strings.SplitN(line, sep, 17)
		if len(f) < 17 {
			continue
		}
		p := Pane{SessionName: f[0], WindowID: f[3], WindowName: f[4], WindowLayout: f[5],
			PaneID: f[6], Active: f[7] == "1", CurrentCommand: f[9],
			CurrentPath: f[10], CommandRunning: f[11] == "1", Title: f[16]}
		p.SessionCreated, _ = strconv.ParseInt(f[1], 10, 64)
		p.WindowIndex, _ = strconv.Atoi(f[2])
		p.PanePID, _ = strconv.Atoi(f[8])
		p.CommandStartTime, _ = strconv.ParseInt(f[12], 10, 64)
		p.LastPromptTime, _ = strconv.ParseInt(f[13], 10, 64)
		// An empty status field means tmux has no exit status for this
		// pane, which is not the same as a status of 0.
		if n, err := strconv.Atoi(f[14]); err == nil {
			p.CommandStatus, p.CommandStatusOK = n, true
		}
		p.CommandEndTime, _ = strconv.ParseInt(f[15], 10, 64)
		panes = append(panes, p)
	}
	return panes
}

// Session is one session's windows, grouped the way kido shows and walks
// them: Windows[i] is one window's panes in pane order, so Windows[i][0]
// identifies the window (SessionName, WindowID).
type Session struct {
	Name    string
	Windows [][]Pane
}

// OrderSessions groups panes into sessions and windows in kido's order:
// sessions oldest first (session_created), ties broken by name, and within
// a session each window's panes kept in ListPanes' own order (tmux's
// natural window order). This is kido's one true order, derived from one
// list-panes: the sidebar's grouping, `kido switch-session` and `kido
// switch-window` all walk it, so they cannot drift apart.
func OrderSessions(panes []Pane) []Session {
	type group struct {
		created int64
		sess    Session
	}
	var order []*group
	bySess := map[string]*group{}
	for _, p := range panes {
		g, ok := bySess[p.SessionName]
		if !ok {
			g = &group{created: p.SessionCreated, sess: Session{Name: p.SessionName}}
			bySess[p.SessionName] = g
			order = append(order, g)
		}
		n := len(g.sess.Windows)
		if n == 0 || g.sess.Windows[n-1][0].WindowID != p.WindowID {
			g.sess.Windows = append(g.sess.Windows, nil)
			n++
		}
		g.sess.Windows[n-1] = append(g.sess.Windows[n-1], p)
	}
	sort.SliceStable(order, func(i, j int) bool {
		if order[i].created != order[j].created {
			return order[i].created < order[j].created
		}
		return order[i].sess.Name < order[j].sess.Name
	})

	sessions := make([]Session, 0, len(order))
	for _, g := range order {
		sessions = append(sessions, g.sess)
	}
	return sessions
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

// SwitchSession switches client to the session adjacent to its current one
// in kido's order (OrderSessions: oldest first, ties by name), wrapping
// around. next selects the following session, otherwise the preceding one.
// A server with one session, or a client not attached to any session kido
// can find, is a no-op.
func SwitchSession(client string, next bool) error {
	panes, err := ListPanes()
	if err != nil {
		return err
	}
	sessions := OrderSessions(panes)
	if len(sessions) < 2 {
		return nil
	}

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
// kido's order (OrderSessions: sessions oldest first, windows in tmux's own
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
	var windows [][]Pane
	for _, s := range OrderSessions(panes) {
		windows = append(windows, s.Windows...)
	}
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
