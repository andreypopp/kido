package subrun

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"kido/internal/testutil"
)

func TestCreateWritesMetaAndTask(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-1")
	if err := Create(id, "do the thing"); err != nil {
		t.Fatal(err)
	}
	if err := WriteMeta(Meta{ID: id, Name: "kid", Depth: 1, Pane: "%1", Cwd: "/tmp", StartedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}

	got, err := ReadMeta(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "kid" || got.Depth != 1 || got.Pane != "%1" {
		t.Errorf("ReadMeta = %+v, want it to round-trip what WriteMeta wrote", got)
	}

	task, err := ReadTask(id)
	if err != nil {
		t.Fatal(err)
	}
	if task != "do the thing" {
		t.Errorf("ReadTask = %q, want %q", task, "do the thing")
	}

	if _, err := os.Stat(filepath.Join(Dir(), string(id))); err != nil {
		t.Errorf("run directory not found under Dir(): %v", err)
	}
}

func TestKindRoundTrips(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	for _, c := range []struct {
		id      ID
		written Kind
	}{
		{"run-bash", KindBash},
		{"run-agent", KindAgent},
	} {
		if err := Create(c.id, "x"); err != nil {
			t.Fatal(err)
		}
		if err := WriteMeta(Meta{ID: c.id, Name: string(c.id), Kind: c.written}); err != nil {
			t.Fatal(err)
		}
		got, err := ReadMeta(c.id)
		if err != nil {
			t.Fatal(err)
		}
		if got.Kind != c.written {
			t.Errorf("ReadMeta(%q).Kind = %q, want the written %q", c.id, got.Kind, c.written)
		}
	}
}

// TestCommandRoundTrips pins that the argv comes back exactly as given -
// quotes, newlines and all - and that an empty one is an error instead
// of an empty exec.
func TestCommandRoundTrips(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-cmd")
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadCommand(id); err == nil {
		t.Error("ReadCommand with no command written = nil error, want one")
	}
	argv := []string{"bash", "-c", "echo 'it\"s' $HOME `date`\nexit 3"}
	if err := WriteCommand(id, argv); err != nil {
		t.Fatal(err)
	}
	got, err := ReadCommand(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(argv) {
		t.Fatalf("ReadCommand = %q, want %q", got, argv)
	}
	for i := range argv {
		if got[i] != argv[i] {
			t.Errorf("ReadCommand()[%d] = %q, want %q", i, got[i], argv[i])
		}
	}

	if err := WriteCommand(id, nil); err != nil {
		t.Fatal(err)
	}
	if got, err := ReadCommand(id); err == nil {
		t.Errorf("ReadCommand of an empty command = %q, nil, want an error", got)
	}
}

func TestRecordOutcomeOnce(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-3")
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	if err := RecordOutcome(id, Outcome{Result: Completed, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
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

// TestWriteScreenLastWriterWins pins that, unlike RecordOutcome's
// O_EXCL, a second WriteScreen wins: refusing it would have permanently
// stranded `kido spawn_subagent --resume`.
func TestWriteScreenLastWriterWins(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-screen")
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := ReadScreen(id); err != nil || ok {
		t.Fatalf("ReadScreen before any write = %v, %v, want no screen yet", ok, err)
	}
	if err := WriteScreen(id, []byte("first capture")); err != nil {
		t.Fatal(err)
	}
	if err := WriteScreen(id, []byte("second capture")); err != nil {
		t.Fatal(err)
	}
	got, ok, err := ReadScreen(id)
	if err != nil || !ok {
		t.Fatalf("ReadScreen = %q, %v, %v", got, ok, err)
	}
	if got != "second capture" {
		t.Errorf("screen = %q, want the later write to win", got)
	}
}

// TestWriteScreenConcurrentWritersLeaveOneWholePayload pins that racing
// writers never share a temp file: the result is always one whole
// payload, never a mix.
func TestWriteScreenConcurrentWritersLeaveOneWholePayload(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-screen-race")
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	const writers = 8
	payloads := make([][]byte, writers)
	for i := range payloads {
		payloads[i] = bytes.Repeat([]byte(fmt.Sprintf("%d", i)), 4096)
	}
	var wg sync.WaitGroup
	for _, p := range payloads {
		wg.Add(1)
		go func(p []byte) {
			defer wg.Done()
			if err := WriteScreen(id, p); err != nil {
				t.Error(err)
			}
		}(p)
	}
	wg.Wait()

	got, ok, err := ReadScreen(id)
	if err != nil || !ok {
		t.Fatalf("ReadScreen = %v, %v, %v", got, ok, err)
	}
	for _, p := range payloads {
		if got == string(p) {
			return
		}
	}
	t.Errorf("screen on disk matches none of the %d whole payloads: %q", writers, got)
}

func TestResetForResume(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-screen-clear")
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	if err := ResetForResume(id, true); err != nil {
		t.Fatalf("ResetForResume with nothing to clear = %v", err)
	}
	if err := WriteScreen(id, []byte("captured")); err != nil {
		t.Fatal(err)
	}
	if err := RecordOutcome(id, Outcome{Result: Died}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(DeliveredPath(id), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ResetForResume(id, true); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := ReadScreen(id); err != nil || ok {
		t.Fatalf("ReadScreen after ResetForResume = %v, %v, want it gone", ok, err)
	}
	if _, ok, err := ReadOutcome(id); err != nil || ok {
		t.Fatalf("ReadOutcome after ResetForResume = %v, %v, want it gone", ok, err)
	}
	if _, err := os.Stat(DeliveredPath(id)); !os.IsNotExist(err) {
		t.Fatalf("delivered marker after ResetForResume(delivered=true) = %v, want removed", err)
	}
}

// TestResetForResumeKeepsDeliveredUnlessAsked pins that ResetForResume
// leaves the delivered marker alone when delivered is false.
func TestResetForResumeKeepsDeliveredUnlessAsked(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-screen-clear-2")
	if err := Create(id, "x"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(DeliveredPath(id), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ResetForResume(id, false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(DeliveredPath(id)); err != nil {
		t.Fatalf("delivered marker after ResetForResume(delivered=false) = %v, want kept", err)
	}
}

func TestEffectiveOutcomeRunningWhenAliveAndUnrecorded(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-4")
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

// TestEffectiveOutcomeDiedWhenDeadAndUnrecorded pins that a dead pid
// with no outcome file guesses Died, never Completed.
func TestEffectiveOutcomeDiedWhenDeadAndUnrecorded(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	id := ID("run-5")
	pid := testutil.DeadPID(t)
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
	id := ID("run-6")
	pid := testutil.DeadPID(t)
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
	for _, id := range []ID{"a", "b"} {
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

// TestReadMetaMissingTruncatedOrMalformed pins that a missing, truncated
// or malformed meta.json each return a plain error rather than panic.
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

// TestParseIDRefusesTraversal pins ParseID against path traversal: `kido
// run-outcome <id>` takes its run id from a model-authored child, and an
// id that escapes Dir must be refused rather than resolved. Measured
// before the check existed: `kido run-outcome --result completed
// ../../evil` wrote an outcome file two directories above the state dir
// and exited 0.
func TestParseIDRefusesTraversal(t *testing.T) {
	for _, id := range []string{"", ".", "..", "../evil", "a/b", `..\evil`, ".hidden"} {
		if _, err := ParseID(id); err == nil {
			t.Errorf("ParseID(%q) = nil error, want it refused", id)
		}
	}
}
