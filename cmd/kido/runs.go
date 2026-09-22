package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"kido/internal/subrun"
)

// RunInfo is one row of `kido runs`, and the shape a --json list prints.
// Outcome is "running" rather than empty when the run has not finished -
// subrun.EffectiveOutcome's ok=false case - so a reader never has to treat
// an empty string as a fourth outcome.
//
// OutcomeAt is a pointer so omitempty can actually omit it: a time.Time is
// a struct, which omitempty never elides, so as a value it printed
// "0001-01-01T00:00:00Z" for every running run and for every died a read
// merely guessed at - a timestamp a JSON reader has no way to tell from a
// real one. Absent means "no recorded end time", which is both of those
// cases.
type RunInfo struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	ParentInstance string     `json:"parentInstance,omitempty"`
	Depth          int        `json:"depth"`
	Cwd            string     `json:"cwd"`
	Model          string     `json:"model,omitempty"`
	Tools          []string   `json:"tools,omitempty"`
	StartedAt      time.Time  `json:"startedAt"`
	Outcome        string     `json:"outcome"`
	OutcomeAt      *time.Time `json:"outcomeAt,omitempty"`
	OutcomeText    string     `json:"outcomeText,omitempty"`
}

func runsUsage() string {
	return "usage: kido runs [--json] [<run-id>]"
}

// shellQuote wraps s for a POSIX shell: single-quoted, with any embedded
// single quote closed, escaped and reopened. It is only ever used to build
// the resume/fork command showRun prints, which must stay copy-pasteable
// into any shell regardless of what the run's cwd contains.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// runsCmd implements `kido runs [--json] [<run-id>]`: every run kido
// spawn has ever created, most recent first, or one shown in detail -
// with its task text and the exact `pi --session`/`pi --fork` command to
// resume or branch from it, since the run id is that child's own pi
// session id by construction (cmd/kido/spawn.go's --session-id).
//
// This is the CLI twin list_agents and the other tools already have one
// of, and for the same reason: the e2e harness cannot host a TypeScript
// extension, so anything living only in pi/kido-status.ts would be
// untestable there.
func runsCmd(args []string) error {
	fs := flag.NewFlagSet("runs", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	asJSON := fs.Bool("json", false, "print JSON instead of a table")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, runsUsage())
	}
	if fs.NArg() > 1 {
		return fmt.Errorf("unknown argument %q\n%s", fs.Arg(1), runsUsage())
	}
	if fs.NArg() == 1 {
		return showRun(os.Stdout, fs.Arg(0), *asJSON)
	}
	return listRuns(os.Stdout, *asJSON)
}

func runOutcomeUsage() string {
	return "usage: kido run-outcome --result completed|failed [--text TEXT] <run-id>"
}

// runOutcomeCmd implements `kido run-outcome`: a run's own child reports
// how it ended, at the same moment it already sends its parent a
// completion notice (pi/kido-status.ts's sendCompletionNotice). <run-id>
// is that child's own pi session id - which is the run id, by
// construction (see cmd/kido/spawn.go's --session-id) - so this needs no
// separate lookup, just what the child already knows about itself. It is
// its own verb rather than a flag on the agent-status report the child
// already makes on every status change because the two have different
// callers: any spawned command can end, including one that never reported
// an agent status in its life and has no business claiming to.
//
// --result only ever accepts completed or failed: Died and Stopped are
// kido's own verdicts about a run from the outside (internal/reap, kido
// stop), not something a model-authored process gets to claim about
// itself, the same reason `kido message --from` is not offered - a
// caller must not be able to assert something only kido itself is
// positioned to know.
func runOutcomeCmd(args []string) error {
	fs := flag.NewFlagSet("run-outcome", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	result := fs.String("result", "", "completed or failed")
	text := fs.String("text", "", "optional detail")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, runOutcomeUsage())
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("%s", runOutcomeUsage())
	}
	r := subrun.Result(*result)
	if r != subrun.Completed && r != subrun.Failed {
		return fmt.Errorf("--result must be %q or %q\n%s", subrun.Completed, subrun.Failed, runOutcomeUsage())
	}
	return subrun.RecordOutcome(fs.Arg(0), subrun.Outcome{Result: r, Text: *text, At: time.Now()})
}

func loadRunInfo(id string) (RunInfo, error) {
	meta, err := subrun.ReadMeta(id)
	if err != nil {
		return RunInfo{}, err
	}
	info := RunInfo{
		ID: id, Name: meta.Name, ParentInstance: meta.ParentInstance, Depth: meta.Depth,
		Cwd: meta.Cwd, Model: meta.Model, Tools: meta.Tools, StartedAt: meta.StartedAt,
		Outcome: "running",
	}
	if o, ok, err := subrun.EffectiveOutcome(id, meta.PID); err != nil {
		return RunInfo{}, err
	} else if ok {
		info.Outcome, info.OutcomeText = string(o.Result), o.Text
		// A guessed Died carries no At at all (subrun.EffectiveOutcome never
		// invents one), so it stays absent rather than becoming a zero time.
		if !o.At.IsZero() {
			at := o.At
			info.OutcomeAt = &at
		}
	}
	return info, nil
}

func listRuns(w io.Writer, asJSON bool) error {
	ids, err := subrun.List()
	if err != nil {
		return err
	}
	infos := make([]RunInfo, 0, len(ids))
	for _, id := range ids {
		info, err := loadRunInfo(id)
		if err != nil {
			continue // a run directory that lost its meta file has nothing to report
		}
		infos = append(infos, info)
	}
	sort.Slice(infos, func(i, j int) bool { return infos[i].StartedAt.After(infos[j].StartedAt) })

	if asJSON {
		return json.NewEncoder(w).Encode(infos)
	}
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tNAME\tPARENT\tSTARTED\tDURATION\tOUTCOME\tCWD")
	now := time.Now()
	for _, info := range infos {
		// A run still going is timed against now; one that ended at a known
		// time against that. A run that ended at an unknown one - the died
		// EffectiveOutcome guessed from a dead pid, which has no At - gets no
		// duration at all, since timing it against now would print a finished
		// run's duration still counting up on every invocation.
		duration := "-"
		switch {
		case info.OutcomeAt != nil:
			duration = info.OutcomeAt.Sub(info.StartedAt).Round(time.Second).String()
		case info.Outcome == "running":
			duration = now.Sub(info.StartedAt).Round(time.Second).String()
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			info.ID, info.Name, info.ParentInstance, info.StartedAt.Format(time.RFC3339),
			duration, info.Outcome, info.Cwd)
	}
	return tw.Flush()
}

func showRun(w io.Writer, id string, asJSON bool) error {
	info, err := loadRunInfo(id)
	if err != nil {
		return fmt.Errorf("run %q: %w", id, err)
	}
	task, err := subrun.ReadTask(id)
	if err != nil {
		task = ""
	}

	// The run id is the child's own pi session id by construction
	// (cmd/kido/spawn.go's --session-id), so resuming or forking a finished
	// run needs no lookup - which is the whole reason a run record is worth
	// keeping, and so is spelled out rather than left for the reader to
	// assemble.
	//
	// D6: pi sessions are project-scoped, and `pi --session <id>` alone only
	// resolves from the run's own cwd - run from anywhere else, pi asks
	// "Session found in different project... Fork into current directory?
	// [y/N]", which is not what a copy-pasted "resume" command should ever
	// do unattended. `cd <cwd> &&` in front of it is what actually makes it
	// work from anywhere, and is still one copy-pasteable line.
	resume := "cd " + shellQuote(info.Cwd) + " && pi --session " + id
	fork := "cd " + shellQuote(info.Cwd) + " && pi --fork " + id

	if asJSON {
		out := struct {
			RunInfo
			Task   string `json:"task"`
			Resume string `json:"resume"`
			Fork   string `json:"fork"`
		}{info, task, resume, fork}
		return json.NewEncoder(w).Encode(out)
	}

	fmt.Fprintf(w, "id:       %s\n", info.ID)
	fmt.Fprintf(w, "name:     %s\n", info.Name)
	fmt.Fprintf(w, "parent:   %s\n", info.ParentInstance)
	fmt.Fprintf(w, "depth:    %d\n", info.Depth)
	fmt.Fprintf(w, "cwd:      %s\n", info.Cwd)
	if info.Model != "" {
		fmt.Fprintf(w, "model:    %s\n", info.Model)
	}
	if len(info.Tools) > 0 {
		fmt.Fprintf(w, "tools:    %v\n", info.Tools)
	}
	fmt.Fprintf(w, "started:  %s\n", info.StartedAt.Format(time.RFC3339))
	fmt.Fprintf(w, "outcome:  %s\n", info.Outcome)
	if info.OutcomeAt != nil {
		fmt.Fprintf(w, "ended:    %s\n", info.OutcomeAt.Format(time.RFC3339))
	}
	if info.OutcomeText != "" {
		fmt.Fprintf(w, "detail:   %s\n", info.OutcomeText)
	}
	fmt.Fprintf(w, "resume:   %s\n", resume)
	fmt.Fprintf(w, "fork:     %s\n", fork)
	fmt.Fprintf(w, "task:\n%s\n", task)
	return nil
}
