// Package subrun is the durable record of one `kido spawn`: a directory
// under <state>/runs/<run-id> holding the task text, a meta file
// describing the spawn, and - once the run ends - an outcome. See
// docs/subagents-plan.md's Phase 8 section for why this exists.
//
// A run record is deliberately not a state.Session: state.Load deletes a
// session record the moment its pid dies, which is exactly the cleanup
// pi's per-turn Claude Code bridge needs and exactly what a durable run
// record must survive instead. state.Load's own file scan already skips
// directory entries (it only reads *.json files), so runs/ - a directory,
// sitting right next to those files in the same state dir - is invisible
// to it for free. Nothing here may ever depend on that changing: the day
// Load learns to look inside runs/ is the day a live run's own directory
// gets read as a session file and mishandled.
//
// Retention is deliberately absent. kido never prunes an old run
// directory, the same way pi never prunes its own session files - a run
// record is a pointer to that session (see RunID and Meta.Window), not a
// copy of anything, so deleting it would not free the space a cleanup
// would be chasing anyway. If that is ever wanted, it belongs in a
// separate tool that a user runs on purpose, not in any path here.
package subrun

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
)

// checkID refuses a run id that would name something other than one
// directory directly under Dir. Every id kido itself mints is NewID's hex
// (see NewID), but `kido run-outcome <id>` takes one from the child - and
// a child is a model-authored process, so "../../somewhere" would
// otherwise write an outcome file anywhere its uid can reach, and
// "../<other-run>" would let one run claim an outcome for another. The
// trust model here is uid-scoped and advisory (AGENTS.md), so this is not
// a security boundary; it is the same refusal-over-quoting stance
// tmuxConfUnsafe takes in cmd/kido/setup.go, for a path kido builds from
// text it did not choose.
func checkID(id string) error {
	if id == "" || strings.ContainsAny(id, `/\`) || strings.HasPrefix(id, ".") {
		return fmt.Errorf("invalid run id %q", id)
	}
	return nil
}

// Dir is the directory holding one subdirectory per run.
func Dir() string { return filepath.Join(state.Dir(), "runs") }

func dirFor(id string) string { return filepath.Join(Dir(), id) }

// TaskPath is the file a spawned child reads its task from, and the one
// kido spawn sets as KIDO_AGENT_TASK_FILE. Exported so cmd/kido/spawn.go
// and a test can both name it without either hand-building the path.
//
// Nothing here ever removes it: it is the record of what this run was
// asked to do, read back later by `kido runs <id>`. The child writes a
// sibling "delivered" marker beside it once it has actually handed the
// text to the model, which is how a pi /reload - which re-runs
// session_start - knows not to deliver it twice (pi/kido-status.ts owns
// both halves of that; no Go code reads the marker).
func TaskPath(id string) string { return filepath.Join(dirFor(id), "task") }

func metaPath(id string) string    { return filepath.Join(dirFor(id), "meta.json") }
func outcomePath(id string) string { return filepath.Join(dirFor(id), "outcome") }

// NewID generates a run id. It is also the child's own pi session id
// (kido spawn passes it as --session-id), so it must be safe both as a
// directory name and on pi's command line - msg.NewID's hex alphabet
// already satisfies both, which is reason enough to reuse it rather than
// mint a second id format.
func NewID() string { return msg.NewID() }

// Meta is a run's own facts, fixed at spawn time and never rewritten
// (WriteMeta is called exactly once).
type Meta struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	ParentInstance string    `json:"parentInstance,omitempty"`
	Depth          int       `json:"depth"`
	Window         string    `json:"window"`
	Pane           string    `json:"pane"`
	PID            int       `json:"pid"` // the child process's pid, for EffectiveOutcome's liveness guess
	Cwd            string    `json:"cwd"`
	Model          string    `json:"model,omitempty"`
	Tools          []string  `json:"tools,omitempty"`
	StartedAt      time.Time `json:"startedAt"`
}

// Result is how a run ended.
type Result string

const (
	// Completed and Failed are reported by the child itself, through
	// `kido run-outcome`, on its own ordinary shutdown - the same moment
	// it already sends its parent a completion notice.
	Completed Result = "completed"
	Failed    Result = "failed"
	// Died is written by a sweep (internal/reap) that finds a marked
	// window's process gone with no outcome recorded: the child never
	// got to report anything, by SIGKILL, an OOM kill, or a crash.
	Died Result = "died"
	// Stopped is written by cmd/kido/control.go's stopCmd, whether the
	// target went quietly or had to be escalated to a window kill: either
	// way, `kido stop` is what ended it, not the child's own choice.
	Stopped Result = "stopped"
)

// Outcome is a run's end state, written exactly once (see RecordOutcome).
type Outcome struct {
	Result Result    `json:"result"`
	Text   string    `json:"text,omitempty"`
	At     time.Time `json:"at"`
}

// Create writes a new run's directory and its task text. Called by kido
// spawn before the tmux window exists, because the child must be able to
// read its task the instant tmux starts it - and because a run directory
// already there is what lets a spawn that then fails record that as an
// outcome, rather than leaving no trace at all.
func Create(id, task string) error {
	if err := checkID(id); err != nil {
		return err
	}
	if err := os.MkdirAll(dirFor(id), 0o755); err != nil {
		return err
	}
	return os.WriteFile(TaskPath(id), []byte(task), 0o600)
}

// WriteMeta writes m's run's meta file. Called once, by kido spawn, after
// tmux.NewWindow has returned the window, pane and pid that complete it:
// a run with no meta file yet is one whose window is still being created,
// and `kido runs` simply has nothing to say about it (loadRunInfo skips
// it).
func WriteMeta(m Meta) error {
	if err := checkID(m.ID); err != nil {
		return err
	}
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	return os.WriteFile(metaPath(m.ID), b, 0o644)
}

// ReadMeta reads id's meta file.
func ReadMeta(id string) (Meta, error) {
	if err := checkID(id); err != nil {
		return Meta{}, err
	}
	b, err := os.ReadFile(metaPath(id))
	if err != nil {
		return Meta{}, err
	}
	var m Meta
	err = json.Unmarshal(b, &m)
	return m, err
}

// ReadTask reads id's task text.
func ReadTask(id string) (string, error) {
	if err := checkID(id); err != nil {
		return "", err
	}
	b, err := os.ReadFile(TaskPath(id))
	return string(b), err
}

// RecordOutcome writes id's outcome, once. It refuses to overwrite one
// that already exists (O_EXCL): several exit paths can race to describe
// the same run - a child's own clean shutdown and a sweep that, a moment
// later, finds the same now-dead window and calls it Died - and the
// first to observe the run ending is definitionally the true story. A
// later, cruder guess must never clobber it. A failure (no such run
// directory, or one already recorded) is best-effort as far as the three
// callers inside kido are concerned - a sweep, a stop and a failed spawn
// all ignore it - while `kido run-outcome` reports it, since a child
// asking twice is worth telling. Hence a plain error rather than a "did
// it write" bool: os.IsExist(err) is that check for a caller that wants
// it.
func RecordOutcome(id string, o Outcome) error {
	if err := checkID(id); err != nil {
		return err
	}
	b, err := json.Marshal(o)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(outcomePath(id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(b)
	return err
}

// ReadOutcome reads id's outcome, if one has been recorded.
func ReadOutcome(id string) (Outcome, bool, error) {
	if err := checkID(id); err != nil {
		return Outcome{}, false, err
	}
	b, err := os.ReadFile(outcomePath(id))
	if err != nil {
		if os.IsNotExist(err) {
			return Outcome{}, false, nil
		}
		return Outcome{}, false, err
	}
	var o Outcome
	if err := json.Unmarshal(b, &o); err != nil {
		return Outcome{}, false, err
	}
	return o, true, nil
}

// EffectiveOutcome is what `kido runs` shows: the recorded outcome if
// there is one, or - when there is not, and pid (Meta.PID) is no longer
// alive - a Died guess, per docs/subagents-plan.md's "a run whose outcome
// is never written is itself informative" instruction. It never persists
// that guess; only a sweep does, when it is the one actually closing the
// run's window (internal/reap). Persisting it here too would mean `kido
// runs` - a read-only report - writes to disk on every invocation, and
// buys nothing: the guess is recomputed identically next time regardless.
// The ok result is false only when the run is still alive and has not
// finished.
//
// It is the same conclusion a sweep persists, reached by a different
// means (a dead pid here, a window of remain-on-exit corpses there), and
// both inherit state.Alive's biases: EPERM reads as alive, and a pid
// recycled by an unrelated process reads as alive too - likely enough for
// a run record that outlives a reboot. Both push the same way, toward
// reporting a long-dead run as still running; neither can invent a Died
// for a run that is in fact alive, since the pid is the pane's own. A
// stale "running" row is the wrong answer kido can afford here, which is
// why this stays a guess on read rather than growing a start-time
// fingerprint to settle it.
func EffectiveOutcome(id string, pid int) (Outcome, bool, error) {
	o, ok, err := ReadOutcome(id)
	if err != nil || ok {
		return o, ok, err
	}
	if !state.Alive(pid) {
		return Outcome{Result: Died}, true, nil
	}
	return Outcome{}, false, nil
}

// List returns every run id under Dir, in no particular order - sorting
// is a display concern for `kido runs`, not a storage one.
func List() ([]string, error) {
	entries, err := os.ReadDir(Dir())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var ids []string
	for _, e := range entries {
		if e.IsDir() {
			ids = append(ids, e.Name())
		}
	}
	return ids, nil
}
