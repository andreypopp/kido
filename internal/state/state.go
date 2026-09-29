// Package state is the status agent sessions report: Claude Code through
// its hooks (kido hook), other agents through kido agent-status. One JSON
// file per session under the state directory, keyed by tmux pane.
package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"

	"kido/internal/tmux"
)

// Status is the coarse activity state of an agent session.
type Status string

const (
	Running    Status = "running"
	Waiting    Status = "waiting"
	Compacting Status = "compacting"
	Idle       Status = "idle"
)

// Statuses lists the statuses an agent may report, in the order a usage
// message lists them.
func Statuses() []Status { return []Status{Running, Waiting, Compacting, Idle} }

func Valid(s Status) bool { return slices.Contains(Statuses(), s) }

// Agent names the program a session belongs to.
type Agent string

const (
	AgentClaude Agent = "claude"
	AgentPi     Agent = "pi"
)

// Parent is one edge to the agent that spawned a session; nil for a
// root agent. PID is a cheap first liveness check, not the identity:
// that is matched on Session.
type Parent struct {
	Session string `json:"session"`
	PID     int    `json:"pid,omitempty"`
}

// NewParent returns nil when session is empty: a pid with no session
// names nothing.
func NewParent(session string, pid int) *Parent {
	if session == "" {
		return nil
	}
	return &Parent{Session: session, PID: pid}
}

// Session is one state file.
type Session struct {
	ID string `json:"-"`
	// Agent unset reads as AgentClaude: files written before kido knew
	// about other agents have no agent key.
	Agent  Agent     `json:"agent,omitempty"`
	Pane   string    `json:"pane"`
	PID    int       `json:"pid"`
	Status Status    `json:"status"`
	TS     time.Time `json:"ts"`
	// Title is set with --title (kido agent-status); empty for Claude
	// Code, which the UI falls back to the pane title for.
	Title string `json:"title,omitempty"`
	// Inbox is a unix socket speaking kido's own inbox protocol, not a
	// general address: an agent framing messages differently (Claude
	// Code's own per-session socket) cannot be named here.
	Inbox string    `json:"inbox,omitempty"`
	Ended time.Time `json:"ended,omitempty"`
	// Background says the main loop has already stopped and the session
	// is running only because a subagent or background shell is still in
	// flight; the next hook event ending that work ends the turn.
	Background bool `json:"background,omitempty"`
	// ToolPending says PreToolUse fired without a matching PostToolUse
	// yet. Claude Code emits nothing in between and a tool call has no
	// upper bound, so the record would otherwise read as stale (StalledSince).
	ToolPending bool    `json:"toolPending,omitempty"`
	Activity    string  `json:"activity,omitempty"`
	Parent      *Parent `json:"parent,omitempty"`
	Depth       int     `json:"depth,omitempty"`
	Model       string  `json:"model,omitempty"`
}

// StallThreshold is how long a session may claim Running without a fresh
// report before Stalled treats it as wedged: six of the ~30s heartbeats
// pi/kido-status.ts sends while running. Overridable via
// KIDO_STALL_THRESHOLD_MS for the e2e suite, which drives a separately
// built binary.
var StallThreshold = func() time.Duration {
	if n, err := strconv.Atoi(os.Getenv("KIDO_STALL_THRESHOLD_MS")); err == nil && n > 0 {
		return time.Duration(n) * time.Millisecond
	}
	return 3 * time.Minute
}()

// StalledSince reports whether s claims Running but has gone quiet past
// StallThreshold, measured from s.TS or wake (the last recorded wake),
// whichever is later. Never true while a tool call is in flight or the
// session is parked on background work: neither has a heartbeat to go
// stale, so the verdict would be wrong every time rather than uncertain.
//
// wake is a parameter rather than read here because a caller comparing
// this verdict at two instants (internal/ui, stallPending) needs one
// reading for both, and reading it per call would put a file open on the
// sidebar's 100ms path.
func StalledSince(s Session, wake, now time.Time) bool {
	if s.Status != Running || s.Background || s.ToolPending {
		return false
	}
	baseline := s.TS
	if wake.After(baseline) {
		baseline = wake
	}
	return now.Sub(baseline) >= StallThreshold
}

// Stalled is StalledSince for a one-shot caller that reads Wake once
// and exits; a caller polling reads Wake itself and uses StalledSince.
func Stalled(s Session, now time.Time) bool {
	return StalledSince(s, Wake(), now)
}

// Wake is the last recorded wake (RecordPause), or the zero time if the
// machine has never been seen to sleep or the marker cannot be read.
func Wake() time.Time {
	b, err := os.ReadFile(filepath.Join(Dir(), pauseFile))
	if err != nil {
		return time.Time{}
	}
	var m pauseMarker
	if json.Unmarshal(b, &m) != nil {
		return time.Time{}
	}
	return m.At
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
// by pane id: of two live agents sharing a pane only one survives the
// map (see beats), which is right for the sidebar's one row per pane and
// wrong for a caller asking whether some agent is running at all, who
// wants LoadLive instead.
func Load() (map[string]Session, error) {
	live, err := LoadLive()
	if err != nil {
		return nil, err
	}
	return ByPane(live), nil
}

// LoadLive reads every state file whose agent process is still alive,
// one entry per session, dropping nothing. It removes a file whose pid
// is dead as it reads it, same as Load, but skips Load's per-pane
// collapse: a caller needing both views calls this once and passes the
// result to ByPane rather than reading the directory twice.
func LoadLive() ([]Session, error) {
	files, err := readFiles()
	if err != nil {
		return nil, err
	}
	out := files[:0]
	for _, s := range files {
		if !Alive(s.PID) {
			os.Remove(filepath.Join(Dir(), s.ID+".json")) //nolint:errcheck // best effort; a concurrent writer may recreate it
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

func Find(live []Session, id string) (Session, bool) {
	for _, s := range live {
		if s.ID == id {
			return s, true
		}
	}
	return Session{}, false
}

// ByPane collapses sessions to one per pane, the outer agent winning a
// shared pane regardless of timestamp (see beats). It is Load's last
// step, exported for a caller already holding a LoadLive slice.
func ByPane(sessions []Session) map[string]Session {
	out := make(map[string]Session, len(sessions))
	for _, s := range sessions {
		if prev, ok := out[s.Pane]; !ok || beats(s, prev) {
			out[s.Pane] = s
		}
	}
	return out
}

// ReadAll reads every state file exactly as recorded, without either of
// Load's side effects. `kido reap` is its one caller: a command
// reasoning about dead agents should not be what deletes the evidence.
func ReadAll() ([]Session, error) {
	return readFiles()
}

func parse(id string, b []byte) (Session, bool) {
	var s Session
	if json.Unmarshal(b, &s) != nil {
		return Session{}, false
	}
	s.ID = id
	return s, true
}

// readFiles reads every well-formed state file in Dir, applying none of
// Load's filtering.
func readFiles() ([]Session, error) {
	dir := Dir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []Session
	for _, e := range entries {
		// Skipping directories keeps runs/ and inbox/ invisible to Load.
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		s, ok := parse(strings.TrimSuffix(e.Name(), ".json"), b)
		if !ok || s.Pane == "" {
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

// outer reports whether agent is the outer agent of a pane it may share
// with Claude Code: pi runs Claude Code inside itself, so a pi record
// always wins over a claude one there. Two non-Claude agents nested in
// one pane both report outer and fall through to beats' timestamp
// comparison.
func outer(agent Agent) bool {
	return agent != AgentClaude
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

// Get reads the state file for session id, if one exists, without
// Load's pane or liveness filtering.
func Get(id string) (Session, bool, error) {
	b, err := os.ReadFile(filepath.Join(Dir(), id+".json"))
	if err != nil {
		if os.IsNotExist(err) {
			return Session{}, false, nil
		}
		return Session{}, false, err
	}
	s, ok := parse(id, b)
	return s, ok, nil
}

func Alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// HeldError is what Record and Remove answer a process that is not the
// live holder of the session id it named. PID and Pane are the holder's.
type HeldError struct {
	ID   string
	PID  int
	Pane string
}

func (e *HeldError) Error() string {
	return fmt.Sprintf("session %s is already open in pane %s (pid %d); this process is not tracked", e.ID, e.Pane, e.PID)
}

func held(id string, pid int) *HeldError {
	prev, ok, err := Get(id)
	if err != nil || !ok || prev.PID == pid || !Alive(prev.PID) {
		return nil
	}
	return &HeldError{ID: id, PID: prev.PID, Pane: prev.Pane}
}

// Record writes the state file for session id, and only for the process
// that holds that session: one live holder per session id, enforced
// lock-free. A first writer creates the record with os.Link from its
// own temp file, atomic and failing if the name is taken, so of two
// processes starting at once exactly one wins and the other stands down
// with a *HeldError. A later write is allowed over the caller's own
// record or a dead holder's, refused otherwise; two processes taking
// over one dead holder both write, then re-read to tell the loser.
func Record(id string, s Session) error {
	dir := Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, id+".json")
	// Named after the writing process: two `kido hook` invocations for one
	// Claude Code session share a pid, and a shared temp name would let one
	// read the other's half-written bytes. Not .json, to stay out of readFiles.
	tmp := filepath.Join(dir, fmt.Sprintf("%s.json.tmp.%d", id, os.Getpid()))
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	defer os.Remove(tmp) //nolint:errcheck // best effort; a leftover temp file is skipped by every reader
	if err := os.Link(tmp, path); err == nil {
		return nil
	} else if !os.IsExist(err) {
		return err
	}
	prev, ok, _ := Get(id)
	takeover := ok && prev.PID != s.PID
	if takeover && Alive(prev.PID) {
		return &HeldError{ID: id, PID: prev.PID, Pane: prev.Pane}
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	if takeover {
		if e := held(id, s.PID); e != nil {
			return e
		}
	}
	return nil
}

// piPrefix is what pi puts before the title it sets: "π - <session> -
// <cwd>", or "π - <cwd>" when the session is unnamed.
const piPrefix = "π - "

// AgentTitle extracts the session name from the pane title an agent sets,
// e.g. "✳ Tmux config" → "Tmux config" for Claude Code and "π - kido -
// internal" → "kido - internal" for pi. Empty in, empty out.
//
// pi's marker is a letter as far as unicode is concerned, so it needs its
// own prefix test; Claude Code's title is trimmed of leading punctuation
// and symbols instead.
func AgentTitle(title string) string {
	t, ok := strings.CutPrefix(title, piPrefix)
	if !ok {
		t = strings.TrimLeftFunc(title, func(r rune) bool {
			return !unicode.IsLetter(r) && !unicode.IsDigit(r)
		})
	}
	return t
}

// IsAgentPane reports whether p runs an agent: one that has reported, one
// running the claude command with no reported data yet, or one whose
// process tree holds a pi that has not reported either. piPanes is
// procs.Scan().Pi, keyed by pane pid; nil means no process sweep was made.
func IsAgentPane(states map[string]Session, piPanes map[int]bool, p tmux.Pane) bool {
	_, reported := states[p.PaneID]
	return reported || p.CurrentCommand == "claude" || piPanes[p.PanePID]
}

// Remove deletes the state file for session id on behalf of pid, which
// must be its live holder.
func Remove(id string, pid int) error {
	if e := held(id, pid); e != nil {
		return e
	}
	err := os.Remove(filepath.Join(Dir(), id+".json"))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
