// Package state reads the per-session status files written by the Claude
// Code hook script (hooks/kido-hook.sh).
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Status is the coarse activity state of a Claude Code session.
type Status string

const (
	Running Status = "running" // model or a tool is executing
	Waiting Status = "waiting" // blocked on a permission prompt
	Idle    Status = "idle"    // turn finished, waiting for user input
	Unknown Status = "unknown" // claude process seen but no hook data
)

// Session is one state file.
type Session struct {
	SessionID string    `json:"session_id"`
	Pane      string    `json:"pane"` // TMUX_PANE, e.g. "%18"
	PID       int       `json:"pid"`  // claude process pid, when known
	CWD       string    `json:"cwd"`
	Status    Status    `json:"status"`
	Event     string    `json:"event"` // last hook_event_name
	Message   string    `json:"message,omitempty"`
	TS        time.Time `json:"ts"`
}

// Dir returns the directory holding state files.
func Dir() string {
	if d := os.Getenv("KIDO_STATE_DIR"); d != "" {
		return d
	}
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "kido")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "kido")
}

// Load reads every state file, keyed by pane id. When several sessions claim
// the same pane (a restarted claude whose predecessor never fired
// SessionEnd), the most recent wins.
func Load() (map[string]Session, error) {
	entries, err := os.ReadDir(Dir())
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]Session{}, nil
		}
		return nil, err
	}
	out := map[string]Session{}
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(Dir(), e.Name()))
		if err != nil {
			continue
		}
		var s Session
		if json.Unmarshal(b, &s) != nil || s.Pane == "" {
			continue
		}
		if prev, ok := out[s.Pane]; !ok || s.TS.After(prev.TS) {
			out[s.Pane] = s
		}
	}
	return out, nil
}
