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

	"kido/internal/reap"
	"kido/internal/subrun"
)

// RunInfo is one row of `kido runs`, and the shape a --json list prints.
// Outcome is "running" rather than empty when the run has not finished.
//
// OutcomeAt is a pointer so omitempty can actually omit it: encoding/json
// never elides a struct, so a time.Time value printed "0001-01-01" for
// every running run and every guessed died. Absent means "no recorded
// end time".
type RunInfo struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	Kind           string     `json:"kind"`
	ParentInstance string     `json:"parentInstance,omitempty"`
	Depth          int        `json:"depth"`
	Cwd            string     `json:"cwd"`
	Model          string     `json:"model,omitempty"`
	Tools          []string   `json:"tools,omitempty"`
	KeepAlive      bool       `json:"keepAlive,omitempty"`
	StartedAt      time.Time  `json:"startedAt"`
	Outcome        string     `json:"outcome"`
	OutcomeAt      *time.Time `json:"outcomeAt,omitempty"`
	OutcomeText    string     `json:"outcomeText,omitempty"`
}

func runsUsage() string {
	return "usage: kido runs [--json] [<run-id>]"
}

// shellQuote wraps s for a POSIX shell: single-quoted, with any embedded
// single quote closed, escaped and reopened.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// runsCmd implements `kido runs [--json] [<run-id>]`: every run kido
// spawn has ever created, most recent first, or one shown in detail with
// its task text and the command to resume or fork it.
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
	return "usage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>"
}

// runOutcomeCmd implements `kido run-outcome`: a run's own child reports
// how it ended. --result accepts only completed or failed; died and
// stopped are kido's verdicts from the outside (docs/design.md, "Run
// outcomes").
//
// --unreported says the child is ending without ever having called
// notify_parent, and asks for the one notice that fact is owed. It goes
// through reap.RecordEnding rather than writing the outcome directly,
// because the outcome write is what decides who speaks: a run already
// spoken for from outside - stopped, or swept - has had its parent told
// once already, and this call then records nothing and says nothing.
func runOutcomeCmd(args []string) error {
	fs := flag.NewFlagSet("run-outcome", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	result := fs.String("result", "", "completed or failed")
	text := fs.String("text", "", "optional detail")
	unreported := fs.Bool("unreported", false, "the child never called notify_parent: tell its parent so")
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
	o := subrun.Outcome{Result: r, Text: *text, At: time.Now()}
	if !*unreported {
		return subrun.RecordOutcome(fs.Arg(0), o)
	}
	meta, err := subrun.ReadMeta(fs.Arg(0))
	if err != nil {
		// No meta file is a run nothing knows the parent of, so there is
		// nobody to tell; the outcome is still this child's to record.
		return subrun.RecordOutcome(fs.Arg(0), o)
	}
	if n, won := reap.RecordEnding(meta, o); won {
		noticeFor(n).send("run-outcome")
	}
	return nil
}

func loadRunInfo(id string) (RunInfo, error) {
	meta, err := subrun.ReadMeta(id)
	if err != nil {
		return RunInfo{}, err
	}
	info := RunInfo{
		ID: id, Name: meta.Name, Kind: string(meta.EffectiveKind()),
		ParentInstance: meta.ParentInstance, Depth: meta.Depth,
		Cwd: meta.Cwd, Model: meta.Model, Tools: meta.Tools, KeepAlive: meta.KeepAlive,
		StartedAt: meta.StartedAt, Outcome: "running",
	}
	if o, ok, err := subrun.EffectiveOutcome(id, meta.PID); err != nil {
		return RunInfo{}, err
	} else if ok {
		info.Outcome, info.OutcomeText = string(o.Result), o.Text
		// A guessed Died carries no At.
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
			continue // no meta file: nothing to report
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
		// A guessed died has no end time, and timing it against now would
		// print a finished run's duration still counting up.
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
	// A screen exists only when a sweep captured one before closing the
	// run's window (internal/reap); a run still alive, or one whose
	// window a human closed by hand, has none.
	screen, hasScreen, err := subrun.ReadScreen(id)
	if err != nil {
		hasScreen = false
	}

	// A bare `pi --session <id>` comes back an orphan: no parent edge, no
	// @kido_subagent mark, not a descendant for stop/ask scoping, and a
	// fresh run record that abandons this one's history. `kido spawn_subagent
	// --resume` goes through the same window-creation path a fresh spawn
	// uses instead, and continues this run rather than starting another
	// (cmd/kido/spawn.go's spawnResume). pi sessions are project-scoped, so
	// the `cd` prefix stays even though spawnResume itself reads the run's
	// own cwd from its meta rather than trusting the invoking shell's.
	resume := "cd " + shellQuote(info.Cwd) + " && kido spawn_subagent --resume " + id
	// `pi --fork` stays bare: forking into a standalone session, with no
	// parent edge or run record of its own, is a different, legitimate
	// thing from resuming this run.
	fork := "cd " + shellQuote(info.Cwd) + " && pi --fork " + id

	if asJSON {
		out := struct {
			RunInfo
			Task   string `json:"task"`
			Resume string `json:"resume"`
			Fork   string `json:"fork"`
			Screen string `json:"screen,omitempty"`
		}{info, task, resume, fork, ""}
		if hasScreen {
			out.Screen = screen
		}
		return json.NewEncoder(w).Encode(out)
	}

	fmt.Fprintf(w, "id:       %s\n", info.ID)
	fmt.Fprintf(w, "name:     %s\n", info.Name)
	fmt.Fprintf(w, "kind:     %s\n", info.Kind)
	fmt.Fprintf(w, "parent:   %s\n", info.ParentInstance)
	fmt.Fprintf(w, "depth:    %d\n", info.Depth)
	fmt.Fprintf(w, "cwd:      %s\n", info.Cwd)
	if info.Model != "" {
		fmt.Fprintf(w, "model:    %s\n", info.Model)
	}
	if len(info.Tools) > 0 {
		fmt.Fprintf(w, "tools:    %v\n", info.Tools)
	}
	// Shown only when set, like the model and the tools above: all three are
	// what a resume will start the run with again, and "keepAlive: false" is
	// the absence of a fact rather than one worth a line.
	if info.KeepAlive {
		fmt.Fprintln(w, "keepAlive: true")
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
	if hasScreen {
		fmt.Fprintf(w, "screen:\n%s\n", screen)
	}
	return nil
}
