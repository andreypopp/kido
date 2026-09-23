package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"kido/internal/subrun"
)

// asyncSignalGrace is how long the wrapper waits for the command to die
// after passing on a signal, before reporting the ending itself. The
// report is the point - being killed is exactly the case where nobody
// else will speak - so the wait is short and never conditional.
const asyncSignalGrace = 2 * time.Second

func asyncRunUsage() string {
	return "usage: kido async-run [--run-id ID] [--name NAME]"
}

// asyncRunCmd implements `kido async-run`, the command a `kido
// async_bash` window actually runs. It execs the run's recorded argv with
// stdout and stderr teed to the run's output file, waits, records the
// outcome, and - if it was the one that recorded it - sends the
// completion notice to the parent. It returns the process exit code,
// which is the command's own, so the dead pane's #{pane_dead_status}
// says what happened too.
//
// Everything is reported before this process exits, which is what makes
// the feature independent of the window surviving: see
// docs/design-subagents.md, "An async bash run".
func asyncRunCmd(args []string) int {
	const cmd = "async-run"
	fail := func(what any) int {
		fmt.Fprintf(os.Stderr, "kido %s: %v\n", cmd, what)
		return 1
	}

	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	runID := fs.String("run-id", os.Getenv("KIDO_AGENT_RUN_ID"), "the run this window is running")
	name := fs.String("name", "", "the run's name, carried in the completion notice")
	if err := fs.Parse(args); err != nil {
		return fail(fmt.Sprintf("%v\n%s", err, asyncRunUsage()))
	}
	if fs.NArg() > 0 {
		return fail(fmt.Sprintf("unknown argument %q; the command comes from the run's own record, not the command line\n%s", fs.Arg(0), asyncRunUsage()))
	}
	if *runID == "" {
		return fail("--run-id is required (or $KIDO_AGENT_RUN_ID)\n" + asyncRunUsage())
	}

	argv, err := subrun.ReadCommand(*runID)
	if err != nil {
		return fail(err)
	}
	out, err := os.Create(subrun.OutputPath(*runID))
	if err != nil {
		return fail(err)
	}
	defer out.Close()

	// One writer for both streams, and the same interface value for each:
	// os/exec gives the child a single descriptor when Stdout and Stderr
	// are equal, so the two arrive interleaved in the order the command
	// wrote them rather than through two racing copies of the file.
	w := io.MultiWriter(os.Stdout, out)
	command := exec.Command(argv[0], argv[1:]...)
	command.Stdin = os.Stdin
	command.Stdout, command.Stderr = w, w

	// Armed before Start, so a signal arriving between the two is still
	// ours to report rather than the default kill.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT)
	defer signal.Stop(sig)

	if err := command.Start(); err != nil {
		reportAsyncRun(*runID, *name, subrun.Failed, err.Error())
		return fail(err)
	}

	done := make(chan error, 1)
	go func() { done <- command.Wait() }()

	select {
	case err := <-done:
		result := subrun.Completed
		status := "exit status 0"
		code := 0
		if err != nil {
			result = subrun.Failed
			status = err.Error() // "exit status 3", or "signal: killed"
			code = 1
			if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() > 0 {
				code = ee.ExitCode()
			}
		}
		reportAsyncRun(*runID, *name, result, status)
		return code
	case s := <-sig:
		command.Process.Signal(s) //nolint:errcheck // best effort; the report below is the point
		select {
		case <-done:
		case <-time.After(asyncSignalGrace):
		}
		reportAsyncRun(*runID, *name, subrun.Failed, "killed by "+s.String())
		return 1
	}
}

// reportAsyncRun is the wrapper's whole ending, in the order it must
// happen in: record the outcome, then notify. The outcome write is the
// arbiter of who observed the ending first (subrun.RecordOutcome's
// O_EXCL), so a wrapper that loses it - to a sweep, or to `kido
// stop_subagent` - stays quiet and leaves the notice to whoever won.
func reportAsyncRun(runID, name string, result subrun.Result, status string) {
	err := subrun.RecordOutcome(runID, subrun.Outcome{Result: result, Text: status, At: time.Now()})
	if err != nil {
		if !os.IsExist(err) {
			fmt.Fprintln(os.Stderr, "kido async-run:", err)
		}
		return
	}
	asyncNotice{
		runID: runID, name: name,
		parentInstance: os.Getenv("KIDO_AGENT_PARENT_INSTANCE"),
		result:         result, text: status,
	}.send("async-run")
}
