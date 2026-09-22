package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"kido/internal/subrun"
)

// deadPID starts and waits for a trivial child process, returning its
// pid: guaranteed to belong to no process by the time the caller uses it.
func deadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}

// newRun creates a run record the way kido spawn does, in two calls, and
// returns the buffer helpers below something to read back.
func newRun(t *testing.T, meta subrun.Meta, task string) {
	t.Helper()
	if err := subrun.Create(meta.ID, task); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(meta); err != nil {
		t.Fatal(err)
	}
}

func TestRunsListsAndShows(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	newRun(t, subrun.Meta{ID: "run-a", Name: "kid", ParentInstance: "root", Depth: 1,
		Cwd: "/tmp/proj", StartedAt: time.Now().Add(-time.Minute)}, "do the thing")
	if err := subrun.RecordOutcome("run-a", subrun.Outcome{Result: subrun.Completed, At: time.Now()}); err != nil {
		t.Fatal(err)
	}

	var list bytes.Buffer
	if err := listRuns(&list, true); err != nil {
		t.Fatal(err)
	}
	var infos []RunInfo
	if err := json.Unmarshal(list.Bytes(), &infos); err != nil {
		t.Fatalf("runs --json: %v (%q)", err, list.String())
	}
	if len(infos) != 1 || infos[0].ID != "run-a" || infos[0].Outcome != "completed" {
		t.Errorf("runs --json = %+v, want one completed run-a", infos)
	}

	var show bytes.Buffer
	if err := showRun(&show, "run-a", false); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"do the thing", "pi --session run-a", "pi --fork run-a", "completed"} {
		if !strings.Contains(show.String(), want) {
			t.Errorf("kido runs run-a output = %q, want it to contain %q", show.String(), want)
		}
	}
}

// TestRunsResumeCommandWorksFromAnyDirectory: pi sessions are
// project-scoped, so `pi --session <id>` alone only resolves from the
// run's own cwd; run anywhere else, pi asks to fork into the current
// directory instead. The printed command must `cd` into the run's own
// cwd first, so it works verbatim from anywhere.
func TestRunsResumeCommandWorksFromAnyDirectory(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	newRun(t, subrun.Meta{ID: "run-b", Name: "kid", ParentInstance: "root", Depth: 1,
		Cwd: "/tmp/some project", StartedAt: time.Now()}, "task")

	var show bytes.Buffer
	if err := showRun(&show, "run-b", false); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"cd '/tmp/some project' && pi --session run-b", "cd '/tmp/some project' && pi --fork run-b"} {
		if !strings.Contains(show.String(), want) {
			t.Errorf("kido runs run-b output = %q, want it to contain %q", show.String(), want)
		}
	}
}

func TestRunsShowsRunningForALiveUnrecordedRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	newRun(t, subrun.Meta{ID: "run-live", PID: os.Getpid(), StartedAt: time.Now()}, "x")

	var out bytes.Buffer
	if err := showRun(&out, "run-live", false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "outcome:  running") {
		t.Errorf("output = %q, want an unrecorded, live run to show as running", out.String())
	}
}

// TestRunsShowsDiedForADeadUnrecordedRun is the "a run whose outcome is
// never written is itself informative" case, from `kido runs` rather than
// from subrun.EffectiveOutcome directly.
func TestRunsShowsDiedForADeadUnrecordedRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	newRun(t, subrun.Meta{ID: "run-dead", PID: deadPID(t), StartedAt: time.Now()}, "x")

	var out bytes.Buffer
	if err := showRun(&out, "run-dead", false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "outcome:  died") {
		t.Errorf("output = %q, want a dead, unrecorded run to show as died", out.String())
	}
}

func TestRunOutcomeCmdRecordsCompletedOrFailed(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-x", "x"); err != nil {
		t.Fatal(err)
	}
	if err := runOutcomeCmd([]string{"--result", "completed", "run-x"}); err != nil {
		t.Fatal(err)
	}
	got, ok, err := subrun.ReadOutcome("run-x")
	if err != nil || !ok || got.Result != subrun.Completed {
		t.Fatalf("outcome = %+v, %v, %v", got, ok, err)
	}
}

// TestRunOutcomeCmdRejectsDiedAndStopped: a run's own process must not be
// able to claim an outcome only kido itself gets to assign from the
// outside (internal/reap's Died, cmd/kido/control.go's Stopped).
func TestRunOutcomeCmdRejectsDiedAndStopped(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-y", "x"); err != nil {
		t.Fatal(err)
	}
	for _, result := range []string{"died", "stopped", "bogus"} {
		if err := runOutcomeCmd([]string{"--result", result, "run-y"}); err == nil {
			t.Errorf("run-outcome --result %s = nil error, want a refusal", result)
		}
	}
	if _, ok, _ := subrun.ReadOutcome("run-y"); ok {
		t.Error("an outcome was recorded despite every attempt being refused")
	}
}
