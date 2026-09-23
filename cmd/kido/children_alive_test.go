package main

import (
	"os"
	"strings"
	"testing"
	"time"

	"kido/internal/subrun"
)

// childRun writes the run record a spawn leaves behind, under parent and
// with pid as the child process's. A pid of 0 is a process that is gone,
// which is what a run with no outcome and no live process looks like.
func childRun(t *testing.T, id, parent string, pid int) {
	t.Helper()
	if err := subrun.Create(id, "do a thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{ID: id, Name: id, ParentInstance: parent,
		PID: pid, StartedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
}

func childrenAlive(t *testing.T, instance string) string {
	t.Helper()
	out := captureStdout(t, func() {
		if err := childrenAliveCmd([]string{instance}); err != nil {
			t.Fatal(err)
		}
	})
	return strings.TrimSpace(out)
}

// TestChildrenAliveReadsTheRunRecords pins the four answers the idle
// self-exit clock depends on, together: only this parent's runs count,
// only ones that have not ended, and the reading comes from the durable
// record rather than from anything a session remembers.
func TestChildrenAliveReadsTheRunRecords(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())

	if got := childrenAlive(t, "parent-inst"); got != "false" {
		t.Errorf("with no runs at all: %q, want false", got)
	}

	childRun(t, "run-live", "parent-inst", os.Getpid())
	if got := childrenAlive(t, "parent-inst"); got != "true" {
		t.Errorf("with a live child: %q, want true", got)
	}
	// The negative control the whole feature rests on: a parent whose
	// children have all ended must go idle again, or idle self-exit is
	// simply switched off for anything that ever spawned.
	if err := subrun.RecordOutcome("run-live", subrun.Outcome{Result: subrun.Completed, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if got := childrenAlive(t, "parent-inst"); got != "false" {
		t.Errorf("with its only child ended: %q, want false", got)
	}

	// Somebody else's child says nothing about this parent.
	childRun(t, "run-other", "other-inst", os.Getpid())
	if got := childrenAlive(t, "parent-inst"); got != "false" {
		t.Errorf("with only another parent's child live: %q, want false", got)
	}

	// A child whose process is gone and whose outcome has not landed yet
	// is ended as far as this reading goes - the same guess `kido runs`
	// prints - because a parent held open by a corpse would never go idle
	// again.
	childRun(t, "run-gone", "parent-inst", 0)
	if got := childrenAlive(t, "parent-inst"); got != "false" {
		t.Errorf("with a child whose process is gone: %q, want false", got)
	}
}
