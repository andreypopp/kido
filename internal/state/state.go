// Package state is the status agent sessions report: Claude Code through
// its hooks (kido hook), other agents through kido agent-status. One JSON
// file per session under the state directory, keyed by tmux pane.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"kido/internal/tmux"
)

// Status is the coarse activity state of an agent session.
type Status string

const (
	Running    Status = "running"    // model or a tool is executing
	Waiting    Status = "waiting"    // blocked on a permission prompt
	Compacting Status = "compacting" // context is being compacted
	Idle       Status = "idle"       // turn finished, waiting for user input
	Unknown    Status = "unknown"    // agent process seen but no reported data
)

// Statuses lists the statuses an agent may report, in the order a usage
// message lists them. Unknown is kido's own and not reportable.
func Statuses() []Status { return []Status{Running, Waiting, Compacting, Idle} }

// Valid reports whether s is a status an agent may report.
func Valid(s Status) bool {
	for _, v := range Statuses() {
		if s == v {
			return true
		}
	}
	return false
}

// Agent names the program a session belongs to. The sidebar renders every
// agent the same way; the name only decides which record wins for a pane
// (see Load) and which agent-specific guesswork applies (internal/ui).
const (
	AgentClaude = "claude" // Claude Code, reporting through kido hook
	AgentPi     = "pi"     // pi, reporting through kido agent-status
)

// Session is one state file.
type Session struct {
	ID string `json:"-"` // agent session id (the file name)
	// Agent is the program that reported this session, AgentClaude or
	// AgentPi. Files written before kido knew about other agents have no
	// agent, and are read as AgentClaude.
	Agent  string    `json:"agent,omitempty"`
	Pane   string    `json:"pane"` // TMUX_PANE, e.g. "%18"
	PID    int       `json:"pid"`  // agent process pid
	Status Status    `json:"status"`
	TS     time.Time `json:"ts"`
	// Title is the session name an agent reported with --title (kido
	// agent-status). Empty for Claude Code, and for an agent that has not
	// reported one; the UI falls back to the pane title in that case.
	Title string `json:"title,omitempty"`
	// Inbox is the path of a unix socket that speaks kido's own inbox
	// protocol (see cmd/kido/inbox.go), reported with --inbox (kido
	// agent-status). It is not a general "send a message here" address:
	// an agent with a socket of its own that frames messages differently
	// (Claude Code's per-session socket, for one) cannot be named here.
	// Empty for Claude Code and for any agent that has no kido inbox;
	// `kido prompt` then types the prompt into the pane with send-keys
	// instead.
	Inbox string `json:"inbox,omitempty"`
	// When the last turn ended (Stop or equivalent); zero if the session
	// is idle for another reason, such as having just started.
	Ended time.Time `json:"ended,omitempty"`
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

// Load reads every state file whose agent process is still alive, keyed
// by pane id. A file found to belong to a dead process is removed rather
// than merely skipped: pi's headless Claude Code bridge (pi-claude-bridge)
// writes one such file per turn, and without this they never go away.
// Deletion only ever targets a file whose recorded pid is not alive, so a
// hook or agent-status call concurrently writing a fresh file for a live
// session is never touched; a removal error (the file is already gone, or
// a race with another sweep) is not fatal.
//
// Several files can claim the same pane, and the winner must not depend on
// which one was written last: pi runs Claude Code inside its own pane
// (pi-claude-bridge, headless, inheriting TMUX_PANE), so that inner Claude
// Code's hooks write a claude record for a pane that is really a pi pane,
// and the two keep overwriting each other as both agents work. The outer
// agent is what the pane is, so the outer agent wins the pane (pi beats
// claude; see beats) and only records of the same standing are compared by
// time.
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
		path := filepath.Join(dir, e.Name())
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var s Session
		if json.Unmarshal(b, &s) != nil || s.Pane == "" {
			continue
		}
		if !alive(s.PID) {
			os.Remove(path) //nolint:errcheck // best effort; a concurrent writer may recreate it
			continue
		}
		s.ID = strings.TrimSuffix(e.Name(), ".json")
		s.Agent = agentOf(s.Agent)
		if prev, ok := out[s.Pane]; !ok || beats(s, prev) {
			out[s.Pane] = s
		}
	}
	return out, nil
}

// agentOf normalises a record's agent: an empty one (a file written before
// kido knew about other agents) is Claude Code.
func agentOf(agent string) string {
	if agent == "" {
		return AgentClaude
	}
	return agent
}

// outer reports whether agent is the outer agent of a pane it shares with
// Claude Code: pi runs Claude Code inside itself (pi-claude-bridge), so a pi
// record always wins a pane over a claude one, whatever the other wrote
// last. An unknown agent is treated as outer too, since a bare claude
// record is the one kido knows can come from the inside.
//
// This is a two-agent test, not a general ranking: it is correct only
// because the nested agent is always Claude Code. Two non-Claude agents
// nested in one pane would both report "outer" and fall through to beats'
// timestamp comparison, reintroducing the flip-flop Load's doc warns about.
func outer(agent string) bool {
	return agentOf(agent) != AgentClaude
}

// beats reports whether s should replace prev as the record for their
// shared pane: the outer agent always wins, and between two records from
// the same standing (both outer, or both Claude Code) the more recent one
// wins.
func beats(s, prev Session) bool {
	if so, po := outer(s.Agent), outer(prev.Agent); so != po {
		return so
	}
	return s.TS.After(prev.TS)
}

// Get reads the state file for session id, if one exists. It does not
// filter by pane or process liveness the way Load does: callers that want
// the raw last-recorded record for a specific session (e.g. to compare
// against a new observation) use this instead.
func Get(id string) (Session, bool, error) {
	b, err := os.ReadFile(filepath.Join(Dir(), id+".json"))
	if err != nil {
		if os.IsNotExist(err) {
			return Session{}, false, nil
		}
		return Session{}, false, err
	}
	var s Session
	if err := json.Unmarshal(b, &s); err != nil {
		return Session{}, false, err
	}
	s.ID = id
	s.Agent = agentOf(s.Agent)
	return s, true, nil
}

// alive reports whether pid exists (a file whose agent died without
// reporting the end of its session is stale).
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

// IsAgentPane reports whether p runs an agent: one that has reported (its
// state file still names this pane, by key in states, which Load keys by
// pane id), one currently running the claude command with no reported data
// yet, or one whose process tree holds a pi that has not reported either.
// piPanes is procs.Scan().Pi, keyed by pane pid; a nil map just means no
// process sweep was made.
func IsAgentPane(states map[string]Session, piPanes map[int]bool, p tmux.Pane) bool {
	_, reported := states[p.PaneID]
	return reported || p.CurrentCommand == "claude" || piPanes[p.PanePID]
}

// Remove deletes the state file for session id.
func Remove(id string) error {
	err := os.Remove(filepath.Join(Dir(), id+".json"))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
