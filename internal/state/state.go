// Package state is the status agent sessions report: Claude Code through
// its hooks (kido hook), other agents through kido agent-status. One JSON
// file per session under the state directory, keyed by tmux pane.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
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
	// protocol (see cmd/kido/inbox.go). It is not a general "send a
	// message here" address: an agent with a socket of its own that frames
	// messages differently (Claude Code's per-session socket, for one)
	// cannot be named here. Empty for any agent without a kido inbox.
	Inbox string `json:"inbox,omitempty"`
	// Protocol is the highest inbox envelope version (see internal/msg) the
	// agent's inbox understands. Zero means either no inbox or one that has
	// not advertised a version; a sender treats both as v0.
	Protocol int `json:"protocol,omitempty"`
	// When the last turn ended (Stop or equivalent); zero if the session
	// is idle for another reason, such as having just started.
	Ended time.Time `json:"ended,omitempty"`
	// Background says the session's main loop has already stopped and it
	// is running only because background work (a subagent, a background
	// shell) is still in flight. It is how the next hook event knows that
	// the end of that work ends the turn. Files written by a kido that
	// predates it have no such key and read as false, which is the state
	// of every session that is not waiting on background work.
	//
	// Nothing clears it explicitly: every report writes a whole fresh
	// Session, so it survives only as long as events keep setting it.
	Background bool `json:"background,omitempty"`
	// ToolPending says a tool call is in flight: PreToolUse has fired and
	// the matching PostToolUse has not. Claude Code emits nothing in
	// between, and a tool call has no upper bound - a build, a test run,
	// an ssh to a slow host - so the record cannot be refreshed while one
	// runs and would otherwise read as stale (see StalledSince).
	//
	// Like Background, nothing clears it explicitly: every report writes a
	// whole fresh Session, so PostToolUse, a Stop, or an interrupted turn's
	// idle all leave it false simply by not setting it.
	ToolPending bool `json:"toolPending,omitempty"`
	// Activity is free text the agent sets ("refactoring internal/ui").
	// Unlike Status it is not a closed vocabulary and does not drive
	// colour.
	Activity string `json:"activity,omitempty"`
	// Instance is an opaque id an agent generates once per process and
	// reports on every status call. It, not the pid, is what a child names
	// as its ParentInstance (docs/design.md, Identity).
	Instance string `json:"instance,omitempty"`
	// ParentPID is the pid of the agent that spawned this one, used only
	// as a first liveness check; a parent edge is matched on
	// ParentInstance, that parent's own Instance.
	ParentPID      int    `json:"parentPid,omitempty"`
	ParentInstance string `json:"parentInstance,omitempty"`
	// Depth is 0 for a root agent, 1 for its subagent, 2 for that
	// subagent's.
	Depth int `json:"depth,omitempty"`
	// Model is the name of the model the agent is currently running,
	// e.g. "claude-sonnet-5".
	Model string `json:"model,omitempty"`
}

// StallThreshold is how long a session may claim Running without a fresh
// report before Stalled treats it as wedged rather than busy: six of the
// ~30s heartbeats pi/kido-status.ts sends while running (docs/design.md,
// Heartbeat and staleness). Overridable via KIDO_STALL_THRESHOLD_MS for
// the e2e suite, which drives a separately built binary.
var StallThreshold = stallThresholdFromEnv(3 * time.Minute)

func stallThresholdFromEnv(def time.Duration) time.Duration {
	if n, err := strconv.Atoi(os.Getenv("KIDO_STALL_THRESHOLD_MS")); err == nil && n > 0 {
		return time.Duration(n) * time.Millisecond
	}
	return def
}

// StalledSince reports whether s claims to be running but has gone quiet
// for longer than StallThreshold, measured from s.TS or from wake - the
// last recorded wake (RecordPause), zero if none - whichever is later.
// Never true for anything but Running.
//
// Never true either while a tool call is in flight, for the same reason
// in a different shape: Claude Code says nothing between PreToolUse and
// PostToolUse, and a tool call is unbounded, so a session seven minutes
// into one is working exactly as intended.
//
// Never true either for a session parked on background work. Staleness
// asks whether an agent that should be reporting has stopped, and the
// threshold is six of the thirty-second heartbeats pi sends while it
// runs. A session Stop parked with work outstanding has no such clock:
// its main loop has ended, Claude Code emits nothing while a background
// shell runs, and the next event may be the user's own next prompt. The
// verdict there is not uncertain but wrong every time, three minutes
// after every backgrounded turn. Detecting background work that has
// genuinely wedged needs evidence of the work itself, which is a
// different signal from the one this function reads.
//
// The baseline is a parameter because a caller that asks about many
// sessions, or about one session at two instants, must use one reading
// of it for all of them: the sidebar compares this verdict at two times
// to decide whether to redraw (internal/ui, stallPending), and two
// separately read baselines could differ across that comparison and make
// it meaningless. Reading the marker per call also put a file open in
// the sidebar's 100ms path for a value that changes once per suspend.
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

// Stalled is StalledSince with the wake marker read for this one call:
// the one-shot form, for a CLI command that asks once and exits. A
// caller on a poll reads Wake itself and uses StalledSince.
func Stalled(s Session, now time.Time) bool {
	return StalledSince(s, Wake(), now)
}

// Wake is the last recorded wake (RecordPause), or the zero time if the
// machine has never been seen to sleep or the marker cannot be read - in
// which case the baseline is the session's own TS, which is what it was
// before pause detection existed.
func Wake() time.Time {
	if at, ok, err := readPause(); err == nil && ok {
		return at
	}
	return time.Time{}
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
// by pane id. A file belonging to a dead process is removed rather than
// skipped, and when several files claim one pane the outer agent wins
// regardless of timestamp (see beats). Both policies are explained in
// docs/design.md, "Who is authoritative for what".
//
// Keying by pane drops records: of two live agents sharing a pane only
// one survives the map. That is right for the sidebar's rows, where a
// pane has one label, and wrong for any caller asking whether some agent
// is running at all. Such a caller wants LoadLive, which is the same
// read without the last step.
func Load() (map[string]Session, error) {
	live, err := LoadLive()
	if err != nil {
		return nil, err
	}
	return ByPane(live), nil
}

// LoadLive reads every state file whose agent process is still alive and
// returns all of them, one entry per session, dropping nothing. It has
// Load's deletion side effect - a file whose pid is dead is removed as it
// is read - and not Load's per-pane collapse.
//
// A caller that needs both views (internal/ui takes a snapshot per 100ms
// tick and both draws rows and sweeps from it) calls this once and passes
// the result to ByPane, rather than reading the directory twice.
func LoadLive() ([]Session, error) {
	files, err := readFiles()
	if err != nil {
		return nil, err
	}
	out := files[:0]
	for _, s := range files {
		if !alive(s.PID) {
			os.Remove(filepath.Join(Dir(), s.ID+".json")) //nolint:errcheck // best effort; a concurrent writer may recreate it
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

// ByPane collapses sessions to one per pane, the outer agent winning a
// shared pane regardless of timestamp (see beats). It is Load's last
// step, exported so a caller holding a LoadLive slice can take the same
// view of it without a second read.
func ByPane(sessions []Session) map[string]Session {
	out := make(map[string]Session, len(sessions))
	for _, s := range sessions {
		if prev, ok := out[s.Pane]; !ok || beats(s, prev) {
			out[s.Pane] = s
		}
	}
	return out
}

// ReadAll reads every state file exactly as recorded, keyed by session id
// rather than pane, without either of Load's side effects: it neither
// deletes a dead-pid file nor keeps only one record per pane. `kido reap`
// is its one caller; a command that reasons about dead agents should not
// be what deletes the evidence.
func ReadAll() (map[string]Session, error) {
	files, err := readFiles()
	if err != nil {
		return nil, err
	}
	out := make(map[string]Session, len(files))
	for _, s := range files {
		out[s.ID] = s
	}
	return out, nil
}

// readFiles reads every well-formed state file in Dir, normalising Agent
// but applying none of Load's filtering.
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
		// Skipping directories is what keeps runs/ and inbox/ invisible to
		// Load; nothing may come to depend on that changing (docs/design.md).
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var s Session
		if json.Unmarshal(b, &s) != nil || s.Pane == "" {
			continue
		}
		s.ID = strings.TrimSuffix(e.Name(), ".json")
		s.Agent = agentOf(s.Agent)
		out = append(out, s)
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
// Claude Code: pi runs Claude Code inside itself, so a pi record always
// wins a pane over a claude one. An unknown agent is treated as outer too,
// since a bare claude record is the one kido knows can come from inside.
//
// This is a two-agent test, not a general ranking: two non-Claude agents
// nested in one pane would both report "outer" and fall through to beats'
// timestamp comparison, flip-flopping the pane between them.
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

// Alive is alive, exported so callers outside the package apply the same
// liveness test Load does rather than a second opinion.
func Alive(pid int) bool { return alive(pid) }

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
