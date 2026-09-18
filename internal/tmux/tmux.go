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
	PaneID         string // e.g. "%18"
	PanePID        int
	CurrentCommand string
	Title          string
}

const sep = "\x1f"

// pane_title is last because it may contain anything.
var format = strings.Join([]string{
	"#{session_name}",
	"#{session_created}",
	"#{window_index}",
	"#{pane_id}",
	"#{pane_pid}",
	"#{pane_current_command}",
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
		f := strings.SplitN(line, sep, 7)
		if len(f) < 7 {
			continue
		}
		p := Pane{SessionName: f[0], PaneID: f[3], CurrentCommand: f[5], Title: f[6]}
		p.SessionCreated, _ = strconv.ParseInt(f[1], 10, 64)
		p.WindowIndex, _ = strconv.Atoi(f[2])
		p.PanePID, _ = strconv.Atoi(f[4])
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

// ClientState returns the client's session name, active pane id, and
// whether the side status line has its keyboard focus.
func ClientState(client string) (session, pane string, focused bool) {
	out, err := run("display-message", "-p", "-c", client,
		"#{session_name}\t#{pane_id}\t#{client_flags}")
	if err != nil {
		return "", "", false
	}
	f := strings.SplitN(out, "\t", 3)
	if len(f) != 3 {
		return "", "", false
	}
	return f[0], f[1], strings.Contains(f[2], "side-status-focus")
}

// Jump makes paneID the active pane of client, switching session and
// window as needed, and hands it the keyboard.
func Jump(client, paneID string) error {
	_, err := run("switch-client", "-c", client, "-t", paneID, ";",
		"select-window", "-t", paneID, ";",
		"select-pane", "-t", paneID, ";",
		"refresh-client", "-t", client, "-f", "!side-status-focus")
	return err
}

// ReleaseSideFocus hands keyboard focus from the side status line back to
// the client's active pane.
func ReleaseSideFocus(client string) error {
	_, err := run("refresh-client", "-t", client, "-f", "!side-status-focus")
	return err
}
