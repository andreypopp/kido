package subrun

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// deadPID starts and waits for a trivial child process, returning its
// pid: guaranteed to belong to no process by the time the caller uses it.
// The same trick internal/reap/reap_test.go and internal/state's own
// tests use.
func deadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}

func TestCreateWritesMetaAndTask(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := "run-1"
	if err := Create(id, "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := WriteMeta(Meta{ID: id, Name: "kid", Depth: 1, Window: "@1", Pane: "%1", Cwd: "/tmp", StartedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}

	got, err := ReadMeta(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "kid" || got.Depth != 1 || got.Window != "@1" {
		t.Errorf("ReadMeta = %+v, want it to round-trip what WriteMeta wrote", got)
	}

	task, err := ReadTask(id)
	if err != nil {
		t.Fatal(err)
	}
	if task != "do the thing" {
		t.Errorf("ReadTask = %q, want %q", task, "do the thing")
	}

	if _, err := os.Stat(filepath.Join(Dir(), id)); err != nil {
		t.Errorf("run directory not found under Dir(): %v", err)
	}
}

func TestRecordOutcomeOnce(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := "run-3"
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	if err := RecordOutcome(id, Outcome{Result: Completed, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	// A later writer - a sweep concluding Died, say - must not clobber
	// the true story that was already recorded.
	if err := RecordOutcome(id, Outcome{Result: Died, At: time.Now()}); err == nil {
		t.Error("RecordOutcome over an existing outcome = nil error, want it refused")
	}
	got, ok, err := ReadOutcome(id)
	if err != nil || !ok {
		t.Fatalf("ReadOutcome = %+v, %v, %v", got, ok, err)
	}
	if got.Result != Completed {
		t.Errorf("outcome = %q, want it to stay %q despite the later write", got.Result, Completed)
	}
}

func TestEffectiveOutcomeRunningWhenAliveAndUnrecorded(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := "run-4"
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	_, ok, err := EffectiveOutcome(id, os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Error("EffectiveOutcome for a live, unrecorded run = ok true, want false (still running)")
	}
}

// TestEffectiveOutcomeDiedWhenDeadAndUnrecorded is the "a run whose
// outcome is never written is itself informative" case: no outcome file
// at all, but the recorded pid is provably gone, so a guess of Died beats
// silence - and must not be confused with Completed, which is a claim
// only the child itself gets to make.
func TestEffectiveOutcomeDiedWhenDeadAndUnrecorded(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := "run-5"
	pid := deadPID(t)
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	got, ok, err := EffectiveOutcome(id, pid)
	if err != nil || !ok {
		t.Fatalf("EffectiveOutcome = %+v, %v, %v", got, ok, err)
	}
	if got.Result != Died {
		t.Errorf("EffectiveOutcome.Result = %q, want %q", got.Result, Died)
	}
}

func TestEffectiveOutcomePrefersRecorded(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := "run-6"
	pid := deadPID(t)
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	if err := RecordOutcome(id, Outcome{Result: Stopped, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	got, ok, err := EffectiveOutcome(id, pid)
	if err != nil || !ok {
		t.Fatalf("EffectiveOutcome = %+v, %v, %v", got, ok, err)
	}
	if got.Result != Stopped {
		t.Errorf("EffectiveOutcome.Result = %q, want the recorded %q, not a guess", got.Result, Stopped)
	}
}

func TestListReturnsRunDirectories(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	for _, id := range []string{"a", "b"} {
		if err := Create(id, "x"); err != nil {
			t.Fatal(err)
		}
	}
	ids, err := List()
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 2 {
		t.Errorf("List = %v, want 2 entries", ids)
	}
}

// TestReadMetaMissingTruncatedOrMalformed pins loadRunInfo's (cmd/kido/runs.go)
// only defence against a run directory that is not what it should be: a
// run whose window was still being created when kido crashed (no
// meta.json yet), a meta.json cut off mid-write by the same crash, and
// one that is syntactically valid JSON but not a Meta at all. `kido runs`
// depends on all three returning a plain error rather than panicking,
// since one bad run directory must not take the whole listing down with
// it.
func TestReadMetaMissingTruncatedOrMalformed(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := Create("run-bad", "x"); err != nil {
		t.Fatal(err)
	}

	if _, err := ReadMeta("run-bad"); err == nil {
		t.Error("ReadMeta with no meta.json written yet = nil error, want one")
	}

	mp := filepath.Join(Dir(), "run-bad", "meta.json")
	if err := os.WriteFile(mp, []byte(`{"id":"run-bad","name":`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadMeta("run-bad"); err == nil {
		t.Error("ReadMeta on truncated JSON = nil error, want one")
	}

	if err := os.WriteFile(mp, []byte(`["not", "an", "object"]`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadMeta("run-bad"); err == nil {
		t.Error("ReadMeta on a JSON array = nil error, want one")
	}
}

// TestRefusesTraversingID pins checkID: `kido run-outcome <id>` takes its
// run id from the child, which is a model-authored process, so an id that
// escapes Dir must be refused rather than resolved. Measured before the
// check existed: `kido run-outcome --result completed ../../evil` wrote an
// outcome file two directories above the state dir and exited 0.
func TestRefusesTraversingID(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	for _, id := range []string{"", ".", "..", "../evil", "a/b", `..\evil`, ".hidden"} {
		if err := Create(id, "x"); err == nil {
			t.Errorf("Create(%q) = nil error, want it refused", id)
		}
		if err := RecordOutcome(id, Outcome{Result: Completed, At: time.Now()}); err == nil {
			t.Errorf("RecordOutcome(%q) = nil error, want it refused", id)
		}
		if _, err := ReadMeta(id); err == nil {
			t.Errorf("ReadMeta(%q) = nil error, want it refused", id)
		}
		if _, err := ReadTask(id); err == nil {
			t.Errorf("ReadTask(%q) = nil error, want it refused", id)
		}
		if _, _, err := ReadOutcome(id); err == nil {
			t.Errorf("ReadOutcome(%q) = nil error, want it refused", id)
		}
	}
}
