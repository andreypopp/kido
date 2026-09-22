// Package subrun is the durable record of one `kido spawn`: a directory
// under <state>/runs/<run-id> holding the task text, a meta file
// describing the spawn, and - once the run ends - an outcome. It is
// deliberately not a state.Session, which is deleted the moment its pid
// dies, and it is never pruned; see docs/design.md, "Run outcomes".
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
// directory directly under Dir: `kido run-outcome <id>` takes the id from
// a model-authored child, and "../<other-run>" would let one run claim an
// outcome for another.
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
// kido spawn sets as KIDO_AGENT_TASK_FILE. Nothing here ever removes it.
// The child writes a sibling "delivered" marker beside it once it has
// handed the text to the model (pi/kido-agents.ts owns both halves of
// that; no Go code reads the marker).
func TaskPath(id string) string { return filepath.Join(dirFor(id), "task") }

func metaPath(id string) string    { return filepath.Join(dirFor(id), "meta.json") }
func outcomePath(id string) string { return filepath.Join(dirFor(id), "outcome") }

// NewID generates a run id. It is also the child's own pi session id, so
// it must be safe both as a directory name and on pi's command line;
// msg.NewID's hex alphabet satisfies both.
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
	// Completed and Failed are the child's own verdict, reported through
	// `kido run-outcome` on its shutdown.
	Completed Result = "completed"
	Failed    Result = "failed"
	// Died is written by a sweep (internal/reap) closing a marked window
	// with no outcome recorded.
	Died Result = "died"
	// Stopped is written by `kido stop` (cmd/kido/control.go).
	Stopped Result = "stopped"
)

// Outcome is a run's end state, written exactly once (see RecordOutcome).
type Outcome struct {
	Result Result    `json:"result"`
	Text   string    `json:"text,omitempty"`
	At     time.Time `json:"at"`
}

// Create writes a new run's directory and its task text. Called by kido
// spawn before the tmux window exists, because the child may read its
// task the instant tmux starts it.
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
// tmux.NewWindow has returned the window, pane and pid that complete it;
// `kido runs` skips a run with no meta file.
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

// RecordOutcome writes id's outcome, once: it refuses (O_EXCL) to
// overwrite one that already exists, so the first writer to observe how
// a run ended wins and a later, cruder guess never clobbers it. An
// existing outcome is a plain error; os.IsExist(err) tells it apart.
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
// there is one, or, when there is none and pid (Meta.PID) is no longer
// alive, a Died guess that is never persisted. ok is false only when the
// run is still alive. The guess inherits state.Alive's biases (EPERM and
// a recycled pid both read as alive), which can only show a dead run as
// running, never the reverse.
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

// List returns every run id under Dir, in no particular order.
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
