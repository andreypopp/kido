package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"kido/internal/subrun"
)

// maxNoticeTailBytes is how much of a run's output the completion notice
// carries. The tail, not the head: what a failure has to say, it says
// last.
const maxNoticeTailBytes = 4000

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
	// A run nobody started has nobody to tell, and notify_parent's own
	// refusal would only print to a pane that is about to close.
	if os.Getenv("KIDO_AGENT_PARENT_INSTANCE") == "" {
		return
	}
	notifyParentCmd(nil, strings.NewReader(asyncNoticeText(runID, name, result, status))) //nolint:errcheck // prints its own error; the outcome is already recorded
}

// asyncNoticeText is the completion notice: what ended, how, and the last
// of what it said.
//
// It names the run itself because nothing else will. A bash run writes no
// state record, so the receiving extension labels the sender by whatever
// it can find - falling through to the pane id, leaving a parent reading
// "notification from %47" - and the run's name is the only thing in this
// text that can carry it.
func asyncNoticeText(runID, name string, result subrun.Result, status string) string {
	if name == "" {
		name = runID
	}
	var b strings.Builder
	fmt.Fprintf(&b, "async run %q %s: %s\n", name, result, status)
	fmt.Fprintf(&b, "run: %s\n", runID)
	fmt.Fprintf(&b, "output: %s\n", subrun.OutputPath(runID))
	tail, omitted, err := tailOfFile(subrun.OutputPath(runID), maxNoticeTailBytes)
	switch {
	case err != nil:
		fmt.Fprintf(&b, "--- output unreadable: %v ---", err)
	case tail == "":
		fmt.Fprint(&b, "--- no output ---")
	case omitted > 0:
		fmt.Fprintf(&b, "--- last %d bytes of output (%d omitted) ---\n%s", len(tail), omitted, tail)
	default:
		fmt.Fprintf(&b, "--- output ---\n%s", tail)
	}
	return b.String()
}

// tailOfFile returns the last max bytes of path and how many bytes were
// dropped from the front of it. The cut is moved forward off a partial
// UTF-8 rune and anything still invalid is replaced, because a notice
// that is not valid UTF-8 is refused by the send path outright - and a
// build log ending mid-character is an ordinary way for that to happen.
func tailOfFile(path string, max int64) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	var omitted int64
	if fi.Size() > max {
		omitted = fi.Size() - max
		if _, err := f.Seek(omitted, io.SeekStart); err != nil {
			return "", 0, err
		}
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return "", 0, err
	}
	if omitted > 0 {
		for len(b) > 0 && b[0]&0xC0 == 0x80 {
			b, omitted = b[1:], omitted+1
		}
	}
	return strings.ToValidUTF8(string(b), "\uFFFD"), omitted, nil
}
