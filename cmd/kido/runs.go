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
	"kido/internal/tmux"
)

// RunInfo is one row of `kido runs`, and the shape a --json list prints.
type RunInfo struct {
	subrun.Meta
	Outcome *subrun.Outcome `json:"outcome,omitempty"`
}

const runsUsage = "usage: kido runs [--json] [<run-id>]"

// runsCmd implements `kido runs [--json] [<run-id>]`: every run kido
// spawn has ever created, most recent first, or one shown in detail with
// its task text and the command to resume or fork it.
func runsCmd(args []string) error {
	fs := flag.NewFlagSet("runs", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	asJSON := fs.Bool("json", false, "print JSON instead of a table")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, runsUsage)
	}
	if fs.NArg() > 1 {
		return fmt.Errorf("unknown argument %q\n%s", fs.Arg(1), runsUsage)
	}
	if fs.NArg() == 1 {
		return showRun(os.Stdout, fs.Arg(0), *asJSON)
	}
	return listRuns(os.Stdout, *asJSON)
}

const runOutcomeUsage = "usage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>"

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
//
// Before any of that, a failing run captures its own pane into the run
// directory (subrun.CaptureOwnScreen): this call runs from inside the
// child, whose pane is still alive at this instant, which is the one
// chance to save what it actually showed before the process that reports
// this exits and takes it with it - a sweep's own capture (internal/reap)
// only ever sees a window already being closed, and `kido close-run`
// captures nothing at all. A failure is the only ending whose screen
// anyone reads, so a completion is not worth the capture-pane and the
// file; the sweep, which keeps every screen it collects, cannot tell the
// two apart beforehand and this can.
func runOutcomeCmd(args []string) error {
	fs := flag.NewFlagSet("run-outcome", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	result := fs.String("result", "", "completed or failed")
	text := fs.String("text", "", "optional detail")
	unreported := fs.Bool("unreported", false, "the child never called notify_parent: tell its parent so")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, runOutcomeUsage)
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("%s", runOutcomeUsage)
	}
	r := subrun.Result(*result)
	if r != subrun.Completed && r != subrun.Failed {
		return fmt.Errorf("--result must be %q or %q\n%s", subrun.Completed, subrun.Failed, runOutcomeUsage)
	}
	id, err := subrun.ParseID(fs.Arg(0))
	if err != nil {
		return err
	}
	o := subrun.Outcome{Result: r, Text: *text, At: time.Now()}

	meta, metaErr := subrun.ReadMeta(id)
	if metaErr == nil && r == subrun.Failed {
		if screen, ok := subrun.CaptureOwnScreen(id, meta.Pane); ok {
			o.Text = refineNoTurnDetail(o.Text, screen)
		}
	}

	if !*unreported || metaErr != nil {
		return subrun.RecordOutcome(id, o)
	}
	if e, won := reap.RecordEnding(meta, o); won {
		e.Detail = reap.AgentEnding{Unreported: true}
		if err := e.Send(); err != nil {
			fmt.Fprintln(os.Stderr, "kido run-outcome:", err)
		}
	}
	return nil
}

// loginLine is what pi prints and exits 0 on when it cannot resolve a
// provider for the model it was given - the one line that makes "no turn
// ever ran" precise, since it names its own cause. Matched by substring
// rather than parsed, since it is pi's own wording to change.
const loginLine = "Use /login to log into a provider via OAuth or API key"

// refineNoTurnDetail sharpens the idle-exit detail (pi/kido-agents.ts's
// NO_FIRST_TURN_TEXT) when the screen just captured for it holds pi's own
// explanation: a provider it could not authenticate for the requested
// model. Any other text, or a screen without that line, is returned
// unchanged - this is the one ending whose cause is knowable from the
// screen, not a general rewrite of every detail string.
//
// What is left for it to catch is narrower than it was: validateModel
// (spawn_subagent.go) refuses a model no configured provider can run
// before any window is created, so the bare alias that used to end this
// way never gets this far. A model of a configured provider whose auth
// fails at run time - an expired key, a revoked token - still does.
func refineNoTurnDetail(text, screen string) string {
	if !strings.Contains(text, "no turn ever ran") || !strings.Contains(screen, loginLine) {
		return text
	}
	return text + ` (the pane showed: "` + loginLine + `")`
}

func loadRunInfo(id subrun.ID) (RunInfo, error) {
	meta, err := subrun.ReadMeta(id)
	if err != nil {
		return RunInfo{}, err
	}
	o, ok, err := subrun.EffectiveOutcome(id, meta.PID)
	if err != nil {
		return RunInfo{}, err
	}
	info := RunInfo{Meta: meta}
	if ok {
		info.Outcome = &o
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
		outcome, duration := "running", now.Sub(info.StartedAt).Round(time.Second).String()
		if o := info.Outcome; o != nil {
			outcome, duration = string(o.Result), "-"
			if !o.At.IsZero() {
				duration = o.At.Sub(info.StartedAt).Round(time.Second).String()
			}
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			string(info.ID), info.Name, info.ParentSession, info.StartedAt.Format(time.RFC3339),
			duration, outcome, info.Cwd)
	}
	return tw.Flush()
}

func showRun(w io.Writer, idStr string, asJSON bool) error {
	id, err := subrun.ParseID(idStr)
	if err != nil {
		return err
	}
	info, err := loadRunInfo(id)
	if err != nil {
		return fmt.Errorf("run %q: %w", id, err)
	}
	task, _ := subrun.ReadTask(id)
	// A screen exists only when a sweep captured one before closing the
	// run's window (internal/reap); a run still alive, or one whose
	// window a human closed by hand, has none.
	screen, hasScreen, _ := subrun.ReadScreen(id)

	// A bare `pi --session <id>` comes back an orphan: no parent edge, no
	// @kido_run mark, not a descendant for stop/ask scoping, and a
	// fresh run record that abandons this one's history. `kido spawn_subagent
	// --resume` goes through the same window-creation path a fresh spawn
	// uses instead, and continues this run rather than starting another
	// (spawnSubagentCmd). pi sessions are project-scoped, so the `cd`
	// prefix stays even though a resume itself reads the run's own cwd from
	// its meta rather than trusting the invoking shell's.
	resume := "cd " + tmux.Quote(info.Cwd) + " && kido spawn_subagent --resume " + idStr
	// `pi --fork` stays bare: forking into a standalone session, with no
	// parent edge or run record of its own, is a different, legitimate
	// thing from resuming this run.
	fork := "cd " + tmux.Quote(info.Cwd) + " && pi --fork " + idStr

	if asJSON {
		out := struct {
			RunInfo
			Task   string `json:"task"`
			Resume string `json:"resume"`
			Fork   string `json:"fork"`
			Screen string `json:"screen,omitempty"`
		}{info, task, resume, fork, screen}
		return json.NewEncoder(w).Encode(out)
	}

	fmt.Fprintf(w, "id:       %s\n", info.ID)
	fmt.Fprintf(w, "name:     %s\n", info.Name)
	fmt.Fprintf(w, "kind:     %s\n", info.Kind)
	fmt.Fprintf(w, "parent:   %s\n", info.ParentSession)
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
	if o := info.Outcome; o == nil {
		fmt.Fprintln(w, "outcome:  running")
	} else {
		fmt.Fprintf(w, "outcome:  %s\n", o.Result)
		// A guessed died carries no end time.
		if !o.At.IsZero() {
			fmt.Fprintf(w, "ended:    %s\n", o.At.Format(time.RFC3339))
		}
		if o.Text != "" {
			fmt.Fprintf(w, "detail:   %s\n", o.Text)
		}
	}
	// Only a report too long for one notice leaves a file behind, and then
	// the notice its parent got names this path too: one line, for the run
	// whose whole report is the thing worth having.
	if subrun.HasReport(id) {
		fmt.Fprintf(w, "report:   %s\n", subrun.ReportPath(id))
	}
	fmt.Fprintf(w, "resume:   %s\n", resume)
	fmt.Fprintf(w, "fork:     %s\n", fork)
	fmt.Fprintf(w, "task:\n%s\n", task)
	if hasScreen {
		fmt.Fprintf(w, "screen:\n%s\n", screen)
	}
	return nil
}
