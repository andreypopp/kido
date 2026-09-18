// Package state is the status Claude Code sessions report through hooks:
// one JSON file per session under the state directory, keyed by tmux pane.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Status is the coarse activity state of a Claude Code session.
type Status string

const (
	Running    Status = "running"    // model or a tool is executing
	Waiting    Status = "waiting"    // blocked on a permission prompt
	Compacting Status = "compacting" // context is being compacted
	Idle       Status = "idle"       // turn finished, waiting for user input
	Unknown    Status = "unknown"    // claude process seen but no hook data
)

// Session is one state file.
type Session struct {
	ID     string    `json:"-"`    // Claude Code session id (the file name)
	Pane   string    `json:"pane"` // TMUX_PANE, e.g. "%18"
	PID    int       `json:"pid"`  // claude process pid
	Status Status    `json:"status"`
	TS     time.Time `json:"ts"`
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

// Load reads every state file whose claude process is still alive, keyed
// by pane id. When several claim the same pane, the most recent wins.
func Load() (map[string]Session, error) {
	dir := Dir()
	entries, err := os.ReadDir(dir)
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
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var s Session
		if json.Unmarshal(b, &s) != nil || s.Pane == "" || !alive(s.PID) {
			continue
		}
		s.ID = strings.TrimSuffix(e.Name(), ".json")
		if prev, ok := out[s.Pane]; !ok || s.TS.After(prev.TS) {
			out[s.Pane] = s
		}
	}
	return out, nil
}

// alive reports whether pid exists (a file whose claude died without a
// SessionEnd hook is stale).
func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// Record writes the state file for session id atomically.
func Record(id string, s Session) error {
	dir := Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, id+".json.tmp")
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, id+".json"))
}

// Remove deletes the state file for session id.
func Remove(id string) error {
	err := os.Remove(filepath.Join(Dir(), id+".json"))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
