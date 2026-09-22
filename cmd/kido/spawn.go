package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

// maxDepth is the nesting ceiling: root 0 -> subagent 1 -> subagent 2.
const maxDepth = 2

// maxTaskBytes matches MAX_PROMPT_BYTES in pi/kido-status.ts: both paths
// deliver a session's first user message, and there should be one answer
// to how big a prompt can be. Restated because the literal cannot be
// shared across Go and TypeScript.
const maxTaskBytes = 1024 * 1024

// maxWindowNameLen caps the model-authored --name. Refusing keeps the
// failure visible to the model instead of quietly mangling the name.
const maxWindowNameLen = 64

// newWindow and markSubagent are tmux.NewWindow and tmux.MarkSubagent,
// indirected so tests can run spawnCmd without a tmux server.
var (
	newWindow    = tmux.NewWindow
	markSubagent = tmux.MarkSubagent
)

func spawnUsage() string {
	return "usage: kido spawn --parent-pid PID --parent-instance ID --name NAME --task-file FILE|- [--depth N] [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n" +
		"   or: kido spawn --resume RUN_ID [--parent-pid PID --parent-instance ID] [--keep-alive] [-- COMMAND...]"
}

// spawnCmd implements `kido spawn`: it creates a detached window in the
// caller's own tmux session (found from $TMUX_PANE) running COMMAND,
// defaulting to `pi`, with KIDO_AGENT_* set in its environment, and
// prints the new window id, pane id and run id, space-separated. The
// task goes in a file in the run's directory, never on the command line;
// the window name does go on the command line and is checked with
// tmuxConfUnsafe. See docs/design.md, "Spawning".
func spawnCmd(args []string) error {
	fs := flag.NewFlagSet("spawn", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	parentPID := fs.Int("parent-pid", 0, "pid of the agent spawning this one")
	parentInstance := fs.String("parent-instance", "", "Instance of the agent spawning this one")
	// --depth is accepted (pi/kido-agents.ts sends it for its own early
	// refusal) but never consulted for the child's depth: see callerDepth
	// below. It is parsed only so a negative value can be rejected.
	claimedDepth := fs.Int("depth", -1, "the caller's own claimed depth; accepted but not trusted, see callerDepth")
	name := fs.String("name", "", "window name, and (by convention) the child's own --name")
	taskFile := fs.String("task-file", "", `file holding the task text to deliver as the child's first message, or "-" for stdin`)
	model := fs.String("model", "", "model the child will run, recorded in the run's meta for kido runs")
	toolsFlag := fs.String("tools", "", "comma-separated tool allowlist the child will run, recorded in the run's meta for kido runs")
	resumeID := fs.String("resume", "", "resume an existing run's own session instead of starting a new one")
	keepAlive := fs.Bool("keep-alive", false, "the child does not self-reap after going idle (KIDO_AGENT_KEEP_ALIVE)")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, spawnUsage())
	}
	depthGiven := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "depth" {
			depthGiven = true
		}
	})
	resuming := *resumeID != ""

	switch {
	case !resuming && *parentPID <= 0:
		return fmt.Errorf("--parent-pid is required\n%s", spawnUsage())
	case !resuming && *parentInstance == "":
		return fmt.Errorf("--parent-instance is required\n%s", spawnUsage())
	case depthGiven && *claimedDepth < 0:
		return fmt.Errorf("--depth must not be negative\n%s", spawnUsage())
	case !resuming && *name == "":
		return fmt.Errorf("--name is required\n%s", spawnUsage())
	case !resuming && *taskFile == "":
		return fmt.Errorf("--task-file is required\n%s", spawnUsage())
	case resuming && *taskFile != "":
		return fmt.Errorf("--resume keeps the run's original task; --task-file is refused alongside it\n%s", spawnUsage())
	case resuming && *name != "":
		return fmt.Errorf("--resume keeps the run's original window name; --name is refused alongside it\n%s", spawnUsage())
	}

	if resuming {
		return spawnResume(*resumeID, *parentPID, *parentInstance, fs.Args(), *keepAlive)
	}

	if i := strings.IndexAny(*name, tmuxConfUnsafe); i >= 0 {
		return fmt.Errorf("refusing window name %q: it contains %q, which cannot survive tmux's own command-line parsing", *name, (*name)[i:i+1])
	}
	if len(*name) > maxWindowNameLen {
		return fmt.Errorf("refusing window name %q: %d bytes is over the %d byte limit", *name, len(*name), maxWindowNameLen)
	}

	task, err := readTask(*taskFile)
	if err != nil {
		return err
	}

	var tools []string
	if *toolsFlag != "" {
		tools = strings.Split(*toolsFlag, ",")
	}

	command := fs.Args()
	if len(command) == 0 {
		command = []string{"pi"}
	}

	caller := os.Getenv("TMUX_PANE")
	panes, err := listPanes()
	if err != nil {
		return err
	}
	pane, ok := findPane(panes, caller)
	if !ok {
		return fmt.Errorf("pane %q not found", caller)
	}

	// The child's depth is derived from the caller's own state record, not
	// from --depth, which a caller at the ceiling could understate. A
	// caller with no record is depth 0, which can only make the ceiling
	// stricter (docs/design.md, "The depth ceiling is derived").
	states, err := state.Load()
	if err != nil {
		return err
	}
	callerDepth := states[caller].Depth
	depth := callerDepth + 1
	if depth > maxDepth {
		return fmt.Errorf("refusing to spawn at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)", depth, maxDepth)
	}

	runID := subrun.NewID()
	if err := subrun.Create(runID, task); err != nil {
		return err
	}
	meta := subrun.Meta{
		ID: runID, Name: *name, ParentInstance: *parentInstance, Depth: depth,
		Cwd: pane.CurrentPath, Model: *model, Tools: tools, StartedAt: time.Now(),
	}

	// The run id is the child's own pi session id; any other command has
	// no session to name and is left as given.
	if command[0] == "pi" {
		command = append([]string{command[0], "--session-id", runID}, command[1:]...)
	}

	env := []string{
		"KIDO_AGENT_PARENT_PID=" + strconv.Itoa(*parentPID),
		"KIDO_AGENT_PARENT_INSTANCE=" + *parentInstance,
		"KIDO_AGENT_DEPTH=" + strconv.Itoa(depth),
		"KIDO_AGENT_TASK_FILE=" + subrun.TaskPath(runID),
		// Unconditional: a child that is not pi has no --session-id to learn
		// the run id from, and `kido run-outcome` needs it.
		"KIDO_AGENT_RUN_ID=" + runID,
	}
	if *keepAlive {
		env = append(env, "KIDO_AGENT_KEEP_ALIVE=1")
	}
	windowID, paneID, panePID, err := newWindow(pane.SessionID, *name, pane.CurrentPath, env, command)
	if err != nil {
		// The meta is written first: `kido runs` passes over a directory
		// with no meta file, and would pass over this outcome with it.
		subrun.WriteMeta(meta)                                                                                //nolint:errcheck // best effort
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	meta.Window, meta.Pane, meta.PID = windowID, paneID, panePID
	if err := subrun.WriteMeta(meta); err != nil {
		return err
	}
	// The mark is the only thing that makes this window reapable. An
	// unmarked window would be uncollectable forever, so a failed mark
	// kills the window rather than strand it.
	if err := markSubagent(windowID, tmux.SubagentMark(runID, *parentInstance, depth)); err != nil {
		killWindow(windowID)                                                                                  //nolint:errcheck // best effort cleanup; the mark error is what matters
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	fmt.Printf("%s %s %s\n", windowID, paneID, runID)
	return nil
}

// liveInstance reports whether some session in states reports instance as
// its own and is still alive - the same reading internal/reap's rule 2
// uses to decide a subagent's parent is gone, spelled out here so a
// resume can refuse before creating a window rule 2 would only close
// moments later.
func liveInstance(states map[string]state.Session, instance string) bool {
	for _, s := range states {
		if s.Instance == instance && state.Alive(s.PID) {
			return true
		}
	}
	return false
}

// spawnResume implements `kido spawn --resume RUN_ID`: it creates a
// detached window through the identical tmux.NewWindow / markSubagent
// path a fresh spawn uses, but launches `pi --session RUN_ID` instead of
// minting a new one, and continues run id's existing run record instead
// of creating a second one - its task, its history and its id stay
// (docs/design.md, "kido spawn --resume"). command is fs.Args(): the
// COMMAND after "--", defaulting to plain pi exactly as a fresh spawn
// does.
func spawnResume(runID string, parentPID int, parentInstance string, command []string, keepAlive bool) error {
	meta, err := subrun.ReadMeta(runID)
	if err != nil {
		return fmt.Errorf("run %q: %w", runID, err)
	}

	// EffectiveOutcome's ok is false exactly when the run is still alive
	// and has recorded nothing about itself yet - the one case resuming
	// makes no sense, since the run's own process already holds the
	// session. Any recorded outcome, whatever it says, means the pid is
	// gone (or kido stop said so), and resuming is what this command is for.
	if _, ok, err := subrun.EffectiveOutcome(runID, meta.PID); err != nil {
		return err
	} else if !ok {
		return fmt.Errorf("run %q is still running (pid %d); resuming a live agent makes no sense", runID, meta.PID)
	}

	if !piSessionFileExists(meta.Cwd, runID) {
		return fmt.Errorf("run %q: no pi session file found under %s; nothing to resume", runID, piSessionDir(meta.Cwd))
	}

	caller := os.Getenv("TMUX_PANE")
	panes, err := listPanes()
	if err != nil {
		return err
	}
	pane, ok := findPane(panes, caller)
	if !ok {
		return fmt.Errorf("pane %q not found", caller)
	}

	// A caller with no state record - a bare human shell - gets no parent
	// pid or instance defaulted for it, exactly as an unreported caller's
	// own depth defaults to 0 below: the resumed run simply has no current
	// parent, same as any other pi session kido never spawned. A caller
	// that does have a record (another agent, or `kido runs`'s printed
	// resume line run from inside a kido-tracked pane) becomes the run's
	// new parent without --parent-pid/--parent-instance having to name it.
	// Given explicitly, those flags still win, the same as a fresh spawn.
	states, err := state.Load()
	if err != nil {
		return err
	}
	self := states[caller]
	if parentPID == 0 {
		parentPID = self.PID
	}
	if parentInstance == "" {
		parentInstance = self.Instance
	}
	// internal/reap's rule 2 closes any marked window whose child reports
	// a ParentInstance that names nobody currently alive - it has no
	// memory of history, so "never heard of that instance" and "that
	// instance's process has since died" read identically to it, and
	// KIDO_AGENT_PARENT_INSTANCE below is exactly what makes the resumed
	// pi report one. A fresh spawn can never trigger this: its caller is
	// always the live process asking for itself. --resume's whole point
	// is letting a *different*, by-hand caller claim the parent edge, so
	// an unverifiable value here is not a hypothetical - refusing before
	// the window exists turns a silent close within moments (the run left
	// recording a useless "died") into an actionable error up front.
	depth := self.Depth + 1
	if depth > maxDepth {
		return fmt.Errorf("refusing to resume at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)", depth, maxDepth)
	}
	if parentInstance != "" && !liveInstance(states, parentInstance) {
		return fmt.Errorf("--parent-instance %q names no currently live agent; the resumed run would be reaped within moments as an orphan (internal/reap's rule 2) - omit --parent-pid/--parent-instance for a parentless resume, or give the instance of an agent that is actually running", parentInstance)
	}

	if len(command) == 0 {
		command = []string{"pi"}
	}
	if command[0] == "pi" {
		command = append([]string{command[0], "--session", runID}, command[1:]...)
		// A bare `--resume` with no `-- pi --model ...` used to come up on
		// pi's default provider, which may have no API key configured -
		// the run's own meta already remembers what it ran under, and a
		// caller who wants something else still wins by naming --model
		// explicitly in the command after --.
		if meta.Model != "" && !slices.Contains(command[1:], "--model") {
			command = append(command, "--model", meta.Model)
		}
	}

	env := []string{
		"KIDO_AGENT_TASK_FILE=" + subrun.TaskPath(runID),
		"KIDO_AGENT_RUN_ID=" + runID,
	}
	if parentPID > 0 {
		env = append(env, "KIDO_AGENT_PARENT_PID="+strconv.Itoa(parentPID))
	}
	if parentInstance != "" {
		env = append(env, "KIDO_AGENT_PARENT_INSTANCE="+parentInstance)
	}
	env = append(env, "KIDO_AGENT_DEPTH="+strconv.Itoa(depth))
	if keepAlive {
		env = append(env, "KIDO_AGENT_KEEP_ALIVE=1")
	}

	// A resumed run is running again: its old outcome, if any, no longer
	// describes it, and RecordOutcome's O_EXCL would otherwise refuse every
	// exit path that follows this one. Cleared before any of those paths
	// runs again, not racing one of them - see ClearOutcome's own doc.
	if err := subrun.ClearOutcome(runID); err != nil {
		return err
	}
	// The first attempt's captured screen, if a sweep saved one, describes
	// that attempt and not this one; clearing it here keeps `kido runs
	// <id>` from showing it as this attempt's own until a sweep captures a
	// fresh one - see ClearScreen's own doc.
	if err := subrun.ClearScreen(runID); err != nil {
		return err
	}

	// The window is created at the run's own cwd, not the caller's: pi
	// sessions are project-scoped, and `pi --session` run from any other
	// directory asks to fork into the current one instead of resuming.
	windowID, paneID, panePID, err := newWindow(pane.SessionID, meta.Name, meta.Cwd, env, command)
	if err != nil {
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	meta.Window, meta.Pane, meta.PID = windowID, paneID, panePID
	meta.ParentInstance, meta.Depth = parentInstance, depth
	if err := subrun.WriteMeta(meta); err != nil {
		return err
	}
	// The mark is the only thing that makes this window reapable, exactly
	// as for a fresh spawn.
	if err := markSubagent(windowID, tmux.SubagentMark(runID, parentInstance, depth)); err != nil {
		killWindow(windowID)                                                                                  //nolint:errcheck // best effort cleanup; the mark error is what matters
		subrun.RecordOutcome(runID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	fmt.Printf("%s %s %s\n", windowID, paneID, runID)
	return nil
}

// piSessionDir mirrors pi 0.85.1's own getDefaultSessionDirPath
// (session-manager.js): PI_CODING_AGENT_SESSION_DIR overrides outright;
// otherwise it is <agentDir>/sessions/--<cwd, its slashes and colons
// turned to dashes>--, with PI_CODING_AGENT_DIR overriding <agentDir> the
// same way pi itself honours it. This does not walk pi's own
// settings.json "sessionDir" override (a project- or agent-dir-level
// setting) - a real gap, noted in docs/design.md, rather than kido
// reimplementing pi's full settings resolution just to check one file's
// existence.
func piSessionDir(cwd string) string {
	if d := os.Getenv("PI_CODING_AGENT_SESSION_DIR"); d != "" {
		return d
	}
	agentDir := os.Getenv("PI_CODING_AGENT_DIR")
	if agentDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		agentDir = filepath.Join(home, ".pi", "agent")
	}
	trimmed := strings.TrimPrefix(cwd, "/")
	safe := "--" + strings.NewReplacer("/", "-", "\\", "-", ":", "-").Replace(trimmed) + "--"
	return filepath.Join(agentDir, "sessions", safe)
}

// piSessionFileExists reports whether id has a pi session file under
// cwd's session directory: pi names one "<timestamp>_<id>.jsonl", so any
// entry ending in "_<id>.jsonl" is a match. An unresolvable directory (no
// $HOME) reads as present, so a check kido has no way to actually perform
// fails open rather than blocking every resume on a guess.
func piSessionFileExists(cwd, id string) bool {
	dir := piSessionDir(cwd)
	if dir == "" {
		return true
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	suffix := "_" + id + ".jsonl"
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), suffix) {
			return true
		}
	}
	return false
}

// readTask reads the task text from path, or from stdin when path is "-".
// A missing or oversized task is refused before any window is created;
// the alternative is a child that starts with no task and no sign
// anything was lost.
func readTask(path string) (string, error) {
	if path == "-" {
		b, err := io.ReadAll(io.LimitReader(os.Stdin, maxTaskBytes+1))
		if err != nil {
			return "", fmt.Errorf("reading task from stdin: %w", err)
		}
		if len(b) > maxTaskBytes {
			return "", fmt.Errorf("task on stdin is over the %d byte task limit", maxTaskBytes)
		}
		return string(b), nil
	}
	fi, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("--task-file %q: %w", path, err)
	}
	if fi.IsDir() {
		return "", fmt.Errorf("--task-file %q is a directory, not a task file", path)
	}
	if fi.Size() > maxTaskBytes {
		return "", fmt.Errorf("--task-file %q is %d bytes, over the %d byte task limit", path, fi.Size(), maxTaskBytes)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("--task-file %q: %w", path, err)
	}
	return string(b), nil
}
