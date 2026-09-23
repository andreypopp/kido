// Package subrun is the durable record of one `kido spawn_subagent`: a directory
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
// kido spawn_subagent sets as KIDO_AGENT_TASK_FILE. Nothing here ever removes it.
// The child writes a sibling "delivered" marker beside it once it has
// handed the text to the model (pi/kido-agents.ts owns both halves of
// that; no Go code reads the marker).
func TaskPath(id string) string { return filepath.Join(dirFor(id), "task") }

// CommandPath is the argv `kido async-run` execs, written by `kido
// async_bash` before the window exists for the reason the task text is:
// the wrapper may already be running before the meta file lands, and
// model-authored text must reach it as a file rather than as a command
// line.
func CommandPath(id string) string { return filepath.Join(dirFor(id), "command") }

// OutputPath is where a bash run's stdout and stderr are teed. It is the
// whole of what the run said; the completion notice carries only its
// tail.
func OutputPath(id string) string { return filepath.Join(dirFor(id), "output") }

func metaPath(id string) string    { return filepath.Join(dirFor(id), "meta.json") }
func outcomePath(id string) string { return filepath.Join(dirFor(id), "outcome") }
func screenPath(id string) string  { return filepath.Join(dirFor(id), "screen") }

// NewID generates a run id. It is also the child's own pi session id, so
// it must be safe both as a directory name and on pi's command line;
// msg.NewID's hex alphabet satisfies both.
func NewID() string { return msg.NewID() }

// Meta is a run's own facts, written once by a fresh spawn. A resume
// rewrites the ones that have actually changed - the window, pane and
// pid it now lives in, the parent edge whoever resumed it claims, and
// the keepAlive that attempt is running under - and leaves the rest,
// which is what makes it one run rather than two (docs/design.md, "Idle
// self-exit, and resuming a run").
type Meta struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Kind           Kind     `json:"kind,omitempty"`
	ParentInstance string   `json:"parentInstance,omitempty"`
	Depth          int      `json:"depth"`
	Window         string   `json:"window"`
	Pane           string   `json:"pane"`
	PID            int      `json:"pid"` // the child process's pid, for EffectiveOutcome's liveness guess
	Cwd            string   `json:"cwd"`
	Model          string   `json:"model,omitempty"`
	Tools          []string `json:"tools,omitempty"`
	// KeepAlive is the --keep-alive the run was spawned with. Recorded, like
	// Model and Tools, because a resume has to start the run it was rather
	// than a default one: a helper spawned to stay up came back arming a
	// thirty-second idle timer, and a child narrowed to a few tools came
	// back holding all of them.
	KeepAlive bool      `json:"keepAlive,omitempty"`
	StartedAt time.Time `json:"startedAt"`
}

// Kind is what a run's window holds. It is omitted from an agent run's
// meta file, so every run recorded before bash runs existed reads back
// as KindAgent (see EffectiveKind).
type Kind string

const (
	// KindAgent is a `kido spawn_subagent` run: a pi session with a task.
	KindAgent Kind = "agent"
	// KindBash is a `kido async_bash` run: a command under `kido async-run`,
	// which reports the run's ending itself.
	KindBash Kind = "bash"
)

// EffectiveKind is m's kind with the empty value read as KindAgent.
func (m Meta) EffectiveKind() Kind {
	if m.Kind == "" {
		return KindAgent
	}
	return m.Kind
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
	// Stopped is written by `kido stop_subagent` (cmd/kido/control.go).
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

// WriteCommand records the argv id's window runs, as `kido async-run`
// will exec it: the shape written is the shape run, so the file is not a
// rendering of a command line but the command line itself.
func WriteCommand(id string, argv []string) error {
	if err := checkID(id); err != nil {
		return err
	}
	b, err := json.Marshal(argv)
	if err != nil {
		return err
	}
	return os.WriteFile(CommandPath(id), b, 0o600)
}

// ReadCommand reads back what WriteCommand wrote. An empty argv is an
// error rather than an empty exec: there is nothing to run and nothing
// truthful to report about having run it.
func ReadCommand(id string) ([]string, error) {
	if err := checkID(id); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(CommandPath(id))
	if err != nil {
		return nil, err
	}
	var argv []string
	if err := json.Unmarshal(b, &argv); err != nil {
		return nil, err
	}
	if len(argv) == 0 {
		return nil, fmt.Errorf("run %q: command file names no command", id)
	}
	return argv, nil
}

// WriteMeta writes m's run's meta file. Called once, by kido spawn_subagent, after
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

// ClearOutcome removes id's recorded outcome, if any, so a later
// RecordOutcome can write a fresh one. Its only caller is `kido spawn_subagent
// --resume`: resuming a run is a deliberate act telling kido the run is
// alive again, not one more exit path racing to describe how it ended,
// so it does not compete with RecordOutcome's "first writer wins" rule -
// it runs before any of those exit paths have anything to say about the
// resumed run, not concurrently with one of them.
func ClearOutcome(id string) error {
	if err := checkID(id); err != nil {
		return err
	}
	if err := os.Remove(outcomePath(id)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// WriteScreen saves id's captured final screen, last writer wins: unlike
// RecordOutcome's outcomes, two captures of one run carry no precedence
// to defend (docs/design.md, "The screen capture") - rule 1 photographs
// the same frozen dead panes twice, and rule 2's live capture only gets
// more complete the later it runs - so refusing a second write the way
// RecordOutcome does would just let a losing-race capture pin a run to a
// worse screen forever, and would permanently strand `kido spawn_subagent --resume`
// after its first attempt, since nothing else ever removes this file.
// Written temp-then-rename, the way state.Record is, so a reader never
// sees a partial write and two racing writers never corrupt one another;
// os.Rename is the same-filesystem atomic swap that buys that.
func WriteScreen(id string, data []byte) error {
	if err := checkID(id); err != nil {
		return err
	}
	tmp := screenPath(id) + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, screenPath(id))
}

// ClearScreen removes id's captured screen, if any, the same way
// ClearOutcome clears an outcome: `kido spawn_subagent --resume`'s only caller,
// so that a screen captured for the run's first attempt is not shown
// under `kido runs <id>` as though it were the resumed attempt's own,
// for however long the resumed attempt takes to end and capture a new
// one of its own.
func ClearScreen(id string) error {
	if err := checkID(id); err != nil {
		return err
	}
	if err := os.Remove(screenPath(id)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// ReadScreen reads id's captured final screen, if a sweep ever saved one.
func ReadScreen(id string) (string, bool, error) {
	if err := checkID(id); err != nil {
		return "", false, err
	}
	b, err := os.ReadFile(screenPath(id))
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, err
	}
	return string(b), true, nil
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
