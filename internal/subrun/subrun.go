// Package subrun is the durable record of one `kido spawn_subagent`: a
// directory under <state>/runs/<run-id> holding the task text, a meta
// file describing the spawn, and - once the run ends - an outcome. It is
// never pruned.
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

// ID is a run id: the name of its directory directly under Dir, and also
// the child's own pi session id. The only way to get one is ParseID or
// NewID, so every function below can trust it names nothing outside Dir.
type ID string

// ParseID refuses a run id that would name something other than one
// directory directly under Dir, since `kido run-outcome <id>` takes the
// id from a model-authored child.
func ParseID(s string) (ID, error) {
	if s == "" || strings.ContainsAny(s, `/\`) || strings.HasPrefix(s, ".") {
		return "", fmt.Errorf("invalid run id %q", s)
	}
	return ID(s), nil
}

func Dir() string { return filepath.Join(state.Dir(), "runs") }

func dirFor(id ID) string { return filepath.Join(Dir(), string(id)) }

// TaskPath is the file a spawned child reads its task from, and the one
// kido spawn_subagent sets as KIDO_AGENT_TASK_FILE. The child writes a
// sibling "delivered" marker beside it once it has handed the text to
// the model (pi/kido-agents.ts owns both halves; no Go code reads it).
func TaskPath(id ID) string { return filepath.Join(dirFor(id), "task") }

// CommandPath is the argv `kido async-run` execs, written before the
// window exists: the wrapper may already be running before the meta
// file lands, and model-authored text must reach it as a file rather
// than a command line.
func CommandPath(id ID) string { return filepath.Join(dirFor(id), "command") }

// OutputPath is where a bash run's stdout and stderr are teed in full;
// the completion notice carries only its tail.
func OutputPath(id ID) string { return filepath.Join(dirFor(id), "output") }

// ReportPath keeps a run's own notify_parent report in full; the parent
// is sent at most a notice's worth of it.
func ReportPath(id ID) string { return filepath.Join(dirFor(id), "report") }

func metaPath(id ID) string    { return filepath.Join(dirFor(id), "meta.json") }
func outcomePath(id ID) string { return filepath.Join(dirFor(id), "outcome") }
func screenPath(id ID) string  { return filepath.Join(dirFor(id), "screen") }

// DeliveredPath is the sibling marker pi/kido-agents.ts's deliverTask
// writes once it has handed id's task to the model, so a /reload does not
// deliver it twice.
func DeliveredPath(id ID) string { return filepath.Join(dirFor(id), "delivered") }

// NewID generates a run id, also used as the child's own pi session id,
// so it must be safe both as a directory name and on pi's command line.
func NewID() ID { return ID(msg.NewID()) }

// Meta is a run's own facts, written once by a fresh spawn. A resume
// rewrites the ones that have actually changed - the window, pane and
// pid it now lives in, the parent edge whoever resumed it claims, and
// the keepAlive that attempt is running under - and leaves the rest,
// which is what makes it one run rather than two.
type Meta struct {
	ID            ID       `json:"id"`
	Name          string   `json:"name"`
	Kind          Kind     `json:"kind,omitempty"`
	ParentSession string   `json:"parentSession,omitempty"`
	Depth         int      `json:"depth"`
	Pane          string   `json:"pane"`
	PID           int      `json:"pid"`
	Cwd           string   `json:"cwd"`
	Model         string   `json:"model,omitempty"`
	Tools         []string `json:"tools,omitempty"`
	// KeepAlive is recorded, like Model and Tools, because a resume has to
	// start the run it was rather than a default one.
	KeepAlive bool      `json:"keepAlive,omitempty"`
	StartedAt time.Time `json:"startedAt"`
}

// Kind is what a run's window holds.
type Kind string

const (
	KindAgent Kind = "agent" // a `kido spawn_subagent` run: a pi session with a task
	KindBash  Kind = "bash"  // a `kido async_bash` run under `kido async-run`
)

// Result is how a run ended.
type Result string

const (
	// Completed and Failed are the child's own verdict, reported through
	// `kido run-outcome` on its shutdown.
	Completed Result = "completed"
	Failed    Result = "failed"
	Died      Result = "died"    // written by a sweep closing a marked window with no outcome
	Stopped   Result = "stopped" // written by `kido stop_subagent`
)

// Outcome is a run's end state, written exactly once (see RecordOutcome).
type Outcome struct {
	Result Result    `json:"result"`
	Text   string    `json:"text,omitempty"`
	At     time.Time `json:"at,omitzero"`
}

// Create writes a new run's directory and its task text, before the
// tmux window exists: the child may read its task the instant tmux
// starts it.
func Create(id ID, task string) error {
	if err := os.MkdirAll(dirFor(id), 0o755); err != nil {
		return err
	}
	return os.WriteFile(TaskPath(id), []byte(task), 0o600)
}

func WriteCommand(id ID, argv []string) error {
	b, err := json.Marshal(argv)
	if err != nil {
		return err
	}
	return os.WriteFile(CommandPath(id), b, 0o600)
}

// ReadCommand reads back what WriteCommand wrote. An empty argv is an
// error rather than an empty exec.
func ReadCommand(id ID) ([]string, error) {
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

// WriteMeta writes m's run's meta file: a new run's before its window
// exists, and again once tmux.NewWindow has returned the pane and pid
// that complete it, while the run's own wrapper may be reading it -
// hence writeAtomic.
func WriteMeta(m Meta) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	return writeAtomic(metaPath(m.ID), b, 0o644)
}

func ReadMeta(id ID) (Meta, error) {
	b, err := os.ReadFile(metaPath(id))
	if err != nil {
		return Meta{}, err
	}
	var m Meta
	err = json.Unmarshal(b, &m)
	return m, err
}

// writeAtomic writes data to path via a same-directory temp file plus
// os.Rename, so a reader never sees a partial write and racing writers
// never share (and truncate one another's) temp file.
func writeAtomic(path string, data []byte, perm os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, werr := f.Write(data)
	cerr := f.Close()
	if werr != nil {
		os.Remove(tmp)
		return werr
	}
	if cerr != nil {
		os.Remove(tmp)
		return cerr
	}
	if err := os.Chmod(tmp, perm); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// WriteReport saves id's notify_parent report in full, last writer wins.
// The run's directory is not created here: a sender kido never spawned
// has none, and the error tells notifyParentCmd to fall back to a plain
// truncation.
func WriteReport(id ID, text string) error {
	return writeAtomic(ReportPath(id), []byte(text), 0o600)
}

func HasReport(id ID) bool {
	_, err := os.Stat(ReportPath(id))
	return err == nil
}

func ReadTask(id ID) (string, error) {
	b, err := os.ReadFile(TaskPath(id))
	return string(b), err
}

// RecordOutcome writes id's outcome, once: O_EXCL refuses to overwrite
// one that already exists, so the first writer to observe how a run
// ended wins and a later, cruder guess never clobbers it. An existing
// outcome is a plain error; os.IsExist(err) tells it apart.
func RecordOutcome(id ID, o Outcome) error {
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

// WriteScreen saves id's captured final screen, last writer wins: unlike
// RecordOutcome's outcomes, two captures of one run carry no precedence
// to defend, and refusing a second write would let a losing-race capture
// pin a run to a worse screen forever and permanently strand `kido
// spawn_subagent --resume` after its first attempt.
func WriteScreen(id ID, data []byte) error {
	return writeAtomic(screenPath(id), data, 0o644)
}

// ResetForResume clears the state a fresh attempt at id must not inherit
// from a previous one: its recorded outcome and captured screen, always,
// and its delivered marker when delivered is true - false when the
// resume mints a fresh session under the run's id, whose own
// deliverTask would otherwise find the old marker and skip redelivering
// the task.
func ResetForResume(id ID, delivered bool) error {
	paths := []string{outcomePath(id), screenPath(id)}
	if delivered {
		paths = append(paths, DeliveredPath(id))
	}
	for _, p := range paths {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func ReadScreen(id ID) (string, bool, error) {
	b, err := os.ReadFile(screenPath(id))
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, err
	}
	return string(b), true, nil
}

func ReadOutcome(id ID) (Outcome, bool, error) {
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
// there is one, or, when there is none and pid is no longer alive, a
// Died guess that is never persisted. ok is false only when the run is
// still alive.
func EffectiveOutcome(id ID, pid int) (Outcome, bool, error) {
	o, ok, err := ReadOutcome(id)
	if err != nil || ok {
		return o, ok, err
	}
	if !state.Alive(pid) {
		return Outcome{Result: Died}, true, nil
	}
	return Outcome{}, false, nil
}

func List() ([]ID, error) {
	entries, err := os.ReadDir(Dir())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var ids []ID
	for _, e := range entries {
		if e.IsDir() {
			ids = append(ids, ID(e.Name()))
		}
	}
	return ids, nil
}
