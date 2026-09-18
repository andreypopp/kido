// Package tmux talks to the tmux server that owns this process.
package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
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
var format = strings.Join([]string{
	"#{session_name}",
	"#{session_created}",
	"#{window_index}",
	"#{window_name}",
	"#{window_layout}",
	"#{pane_id}",
	"#{&&:#{window_active},#{pane_active}}",
	"#{pane_pid}",
	"#{pane_current_command}",
	"#{pane_current_path}",
	"#{pane_title}",
}, sep)

// ListPanes returns every pane on the server, in tmux's own order.
func ListPanes() ([]Pane, error) {
	out, err := run("list-panes", "-a", "-F", format)
	if err != nil {
		return nil, err
	}
	var panes []Pane
	for _, line := range strings.Split(out, "\n") {
		f := strings.SplitN(line, sep, 11)
		if len(f) < 11 {
			continue
		}
		p := Pane{SessionName: f[0], WindowName: f[3], WindowLayout: f[4],
			PaneID: f[5], Active: f[6] == "1", CurrentCommand: f[8],
			CurrentPath: f[9], Title: f[10]}
		p.SessionCreated, _ = strconv.ParseInt(f[1], 10, 64)
		p.WindowIndex, _ = strconv.Atoi(f[2])
		p.PanePID, _ = strconv.Atoi(f[7])
		panes = append(panes, p)
	}
	return panes, nil
}

// CurrentClient asks tmux which client this process belongs to. Used when
// kido is started by hand in a pane rather than by the side status line.
func CurrentClient() string {
	out, _ := run("display-message", "-p", "#{client_name}")
	return out
}

// sideFocusFlag is the patched tmux's client flag that routes keys to the
// side status line's job.
const sideFocusFlag = "side-status-focus"

// ClientState returns the client's session and whether the side status
// line has its keyboard focus. (display-message's #{session_name} would
// report the command's target session, not the client's.)
func ClientState(client string) (session string, focused bool) {
	out, err := run("display-message", "-p", "-c", client,
		"#{client_session}\t#{client_flags}")
	if err != nil {
		return "", false
	}
	sess, flags, _ := strings.Cut(out, "\t")
	return sess, strings.Contains(flags, sideFocusFlag)
}

// ActivePane returns the active pane of session within panes.
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
