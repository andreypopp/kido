package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runInfo is lib/run_history.ml's info as JSON, just the fields these tests
// read, with the outcome flattened: "running" when there is none.
type runInfo struct {
	ID          string
	Kind        string
	Outcome     string
	OutcomeText string
}

func (r *runInfo) UnmarshalJSON(b []byte) error {
	var raw struct {
		ID      string `json:"id"`
		Kind    string `json:"kind"`
		Outcome *struct {
			Result string `json:"result"`
			Text   string `json:"text"`
		} `json:"outcome"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	*r = runInfo{ID: raw.ID, Kind: raw.Kind, Outcome: "running"}
	if raw.Outcome != nil {
		r.Outcome, r.OutcomeText = raw.Outcome.Result, raw.Outcome.Text
	}
	return nil
}

// spawnRun is runSpawn but lets the caller supply the command's script
// directly: runSpawn's own fixed "env; pwd; sleep" script never exits on
// its own, which every test here needs control over.
func (h *harness) spawnRun(name, script string, parentExtra ...string) (runID, windowID string) {
	h.t.Helper()
	h.liveParent("alpha", "root-e2e", parentExtra...)
	outFile := filepath.Join(h.dir, name+".out")
	cmd := fmt.Sprintf("PI_SESSION_ID=root-e2e %s tool spawn_subagent --name %s --task-file %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, name, h.writeTaskFile(name), shellQuote(script), outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		h.t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	return fields[2], fields[0]
}

// runMeta is `kido runs --json <run>` whole, for the fields runInfo
// leaves out.
func (h *harness) runMeta(tag, runID string) map[string]any {
	h.t.Helper()
	out := h.runKido("alpha", runID+"-"+tag+"-meta.out", "runs", "--json", runID)
	var meta map[string]any
	if err := json.Unmarshal([]byte(strings.SplitN(out, "\n", 2)[0]), &meta); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return meta
}

func (h *harness) writeTaskFile(name string) string {
	h.t.Helper()
	path := filepath.Join(h.dir, name+"-task.txt")
	if err := os.WriteFile(path, []byte("do the thing"), 0o644); err != nil {
		h.t.Fatal(err)
	}
	return path
}

// runOutcome reads one run's outcome; a tag keeps two reads of one run
// from reusing the first read's output file.
func (h *harness) runOutcome(runID string, tag ...string) string {
	h.t.Helper()
	name := runID + "-show.out"
	if len(tag) > 0 {
		name = runID + "-" + tag[0] + "-show.out"
	}
	out := h.runKido("alpha", name, "runs", "--json", runID)
	var info runInfo
	line := strings.SplitN(out, "\n", 2)[0] // drop runKido's own trailing "rc=0" line
	if err := json.Unmarshal([]byte(line), &info); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return info.Outcome
}

// A child killed outright must leave a readable run record once the
// sidebar's sweep has collected its window: the outcome must survive the
// window closing, not just the pane dying. The sweep takes the signal from
// tmux's pane_dead_signal.
func TestRunRecordSurvivesReapAsSignal(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("died-e2e", "exec sleep 300")
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	h.killPane(paneID)

	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's sweep to close window %s", windowID))

	if got := h.runOutcome(runID); got != "failed" {
		t.Errorf("run %s outcome = %q, want %q", runID, got, "failed")
	}
}

// Same shape, but the child records its own ending before exiting,
// standing in for pi's session end (the e2e suite cannot host the
// extension). The recorded outcome must win over the sweep's own Died
// guess for the same dead, marked window. The child never reported, so
// kido adds the one unreported ending notice.
func TestRunRecordSurvivesReapAsCompleted(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const marker = "KIDO-E2E-SCREEN-MARKER-4f2a"
	script := fmt.Sprintf(`echo %s; sleep 0.3; %s run-outcome --result completed -- "$KIDO_AGENT_RUN_ID"`, marker, kidoBin)
	// The parent has its inbox before the child starts: the child's ending
	// notice is sent once, 0.3s in, and a parent without an inbox loses it.
	in := startInbox(h.t, "ok\n")
	runID, windowID := h.spawnRun("done-e2e", script, "--inbox", in.Path)

	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's sweep to close window %s once the child has exited", windowID))

	if got := h.runOutcome(runID); got != "completed" {
		t.Errorf("run %s outcome = %q, want %q (the sweep's own Died guess must not win the race)", runID, got, "completed")
	}
	h.stableCount(in, 1, "a child that ended without reporting is spoken for once, and the sweep adds nothing")
	if got := in.Received()[0]; !strings.Contains(got, "completed without reporting") {
		t.Errorf("parent inbox received %q, want the one unreported ending notice", got)
	}
	// The screen output must survive the sweep collecting its window, through
	// `kido runs <id>`, the only way a human would actually see it.
	if out := h.runKido("alpha", "screen-show.out", "runs", runID); !strings.Contains(out, marker) {
		t.Errorf("kido runs %s = %q, want it to contain the captured marker %q", runID, out, marker)
	}
}

// `kido runs` and `kido runs <id>` render lib's run records for a human
// in bin/main.ml: the table newest first, local times, a "-" for a run
// with no ending, Go durations, the detail's aligned keys, and --json's
// key order. TZ is a POSIX zone, not a zoneinfo name, so a host without
// tzdata still pins the local time and its half-hour offset.
func TestRunsTableShowAndJSON(t *testing.T) {
	t.Parallel()
	state := serverDir(t)
	write := func(id string, meta map[string]any, outcome string) {
		dir := filepath.Join(state, "runs", id)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		b, err := json.Marshal(meta)
		if err != nil {
			t.Fatal(err)
		}
		files := map[string]string{"meta.json": string(b), "task": "do the thing"}
		if outcome != "" {
			files["outcome"] = outcome
		}
		for name, body := range files {
			if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	write("run-a", map[string]any{
		"id": "run-a", "name": "kid", "kind": "agent", "parent": "root",
		"pane": "", "pid": 0, "cwd": "/tmp/some project", "startedAt": "2023-11-14T22:13:20Z",
	}, `{"result":"completed","at":"2023-11-14T22:14:50Z"}`)
	write("run-b", map[string]any{
		"id": "run-b", "name": "later", "kind": "bash",
		"pane": "", "pid": 0, "cwd": "", "startedAt": "2023-11-14T23:13:20Z",
	}, "")
	kidoIn := func(tz string, args ...string) string {
		t.Helper()
		cmd := exec.Command(kidoBin, args...)
		cmd.Env = cleanEnv("KIDO_STATE_DIR="+state, "TZ="+tz)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("kido %v: %v %q", args, err, out)
		}
		return string(out)
	}
	kido := func(args ...string) string { t.Helper(); return kidoIn("IST-5:30", args...) }

	row := func(cells ...string) string {
		return fmt.Sprintf("%-7s%-7s%-9s%-8s%-27s%-10s%-11s%s\n", cells[0], cells[1], cells[2], cells[3], cells[4], cells[5], cells[6], cells[7])
	}
	if got, want := kido("runs"),
		row("ID", "NAME", "SESSION", "PARENT", "STARTED", "DURATION", "OUTCOME", "CWD")+
			row("run-b", "later", "", "", "2023-11-15T04:43:20+05:30", "-", "died", "")+
			row("run-a", "kid", "", "root", "2023-11-15T03:43:20+05:30", "1m30s", "completed", "/tmp/some project"); got != want {
		t.Errorf("kido runs:\n%s\nwant:\n%s", got, want)
	}

	if got, want := kido("runs", "run-a"), `id:       run-a
name:     kid
kind:     agent
session:  
parent:   root
cwd:      /tmp/some project
started:  2023-11-15T03:43:20+05:30
outcome:  completed
ended:    2023-11-15T03:44:50+05:30
output:   `+state+`/runs/run-a/output
resume:   cd '/tmp/some project' && kido tool spawn_subagent --resume run-a
fork:     cd '/tmp/some project' && pi --fork run-a
task:
do the thing
`; got != want {
		t.Errorf("kido runs run-a:\n%s\nwant:\n%s", got, want)
	}

	dec := json.NewDecoder(strings.NewReader(kido("runs", "--json", "run-a")))
	var keys []string
	if _, err := dec.Token(); err != nil {
		t.Fatal(err)
	}
	for dec.More() {
		key, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, key.(string))
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			t.Fatal(err)
		}
	}
	if got, want := strings.Join(keys, " "), "id name kind parent pane pid cwd startedAt session outcome task resume fork output"; got != want {
		t.Errorf("kido runs --json run-a keys = %q, want %q", got, want)
	}

	var listed []runInfo
	if err := json.Unmarshal([]byte(kido("runs", "--json")), &listed); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range listed {
		got = append(got, r.ID+" "+r.Outcome)
	}
	if want := "run-b died, run-a completed"; strings.Join(got, ", ") != want {
		t.Errorf("kido runs --json = %q, want %q", strings.Join(got, ", "), want)
	}

	// A negative half-hour zone, an instant whose local date is in another
	// year, and both sides of each DST transition: in 2024 NDT starts at
	// 02:00 local on 10 March and ends at 02:00 local on 3 November.
	const nst = "NST3:30NDT,M3.2.0,M11.1.0"
	for i, c := range []struct{ tz, at, want string }{
		{"NST3:30", "2023-11-14T22:13:20Z", "2023-11-14T18:43:20-03:30"},
		{"NST3:30", "2024-01-01T01:00:00Z", "2023-12-31T21:30:00-03:30"},
		{"IST-5:30", "2023-12-31T20:00:00Z", "2024-01-01T01:30:00+05:30"},
		{nst, "2024-03-10T05:00:00Z", "2024-03-10T01:30:00-03:30"},
		{nst, "2024-03-10T06:00:00Z", "2024-03-10T03:30:00-02:30"},
		{nst, "2024-11-03T04:00:00Z", "2024-11-03T01:30:00-02:30"},
		{nst, "2024-11-03T05:00:00Z", "2024-11-03T01:30:00-03:30"},
	} {
		id := fmt.Sprintf("run-tz%d", i)
		write(id, map[string]any{
			"id": id, "name": "tz", "kind": "bash",
			"pane": "", "pid": 0, "cwd": "", "startedAt": c.at,
		}, "")
		var started string
		for _, line := range strings.Split(kidoIn(c.tz, "runs", id), "\n") {
			if v, ok := strings.CutPrefix(line, "started:  "); ok {
				started = v
			}
		}
		if started != c.want {
			t.Errorf("TZ=%s started %s = %q, want %q", c.tz, c.at, started, c.want)
		}
	}
}

// A pi kido did not start is a run too: its holder makes it running, a
// release completes it with its name kept, and it resumes as a plain pi.
func TestRunsListsAPiRun(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.firstPane("alpha")
	h.programStatus(pane, "state=idle:app=pi", "top")
	h.agentStatus("top-pi", pane, "--name", "Top")
	if info := h.runInfo("top-pi"); info.Kind != "pi" || info.Outcome != "running" {
		t.Fatalf("held pi run = %+v, want a running pi", info)
	}
	h.agentStatus("top-pi", pane, "--remove")
	meta := h.runMeta("released", "top-pi")
	// Releasing the record only frees its holder: the pane still marks the
	// run and shows a pi root, so the run is running until that pane dies.
	if info := h.runInfo("top-pi"); info.Outcome != "running" || meta["name"] != "Top" {
		t.Fatalf("released pi run = %+v, %v, want running and named Top", info, meta)
	}
	if !strings.HasSuffix(meta["resume"].(string), "&& pi --session '"+h.sessionFile("top-pi")+"'") {
		t.Errorf("resume = %q, want a plain pi --session of its recorded file", meta["resume"])
	}
}
