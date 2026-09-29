package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
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

var (
	newWindow    = tmux.NewWindow
	markRun      = tmux.MarkRun
	windowExists = tmux.WindowExists
)

const spawnUsage = "usage: kido spawn_subagent --parent-pid PID --parent-session ID --name NAME --task-file FILE|- [--fork SESSION_ID] [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n" +
	"   or: kido spawn_subagent --no-parent --name NAME --task-file FILE|- [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n" +
	"   or: kido spawn_subagent --resume RUN_ID [--parent-pid PID --parent-session ID | --no-parent] [--keep-alive] [-- COMMAND...]"

type parentEdge struct {
	pid     int
	session string
}

type spawnMode interface{ isSpawn() }

type fresh struct {
	name, task, fork, model string
	tools                   []string
}

type resume struct {
	runID subrun.ID
	adopt bool
}

func (fresh) isSpawn()  {}
func (resume) isSpawn() {}

type spawnReq struct {
	mode      spawnMode
	parent    *parentEdge
	keepAlive bool
	command   []string
}

func parseSpawn(args []string) (spawnReq, error) {
	fs := flag.NewFlagSet("spawn_subagent", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	parentPID := fs.Int("parent-pid", 0, "pid of the agent spawning this one")
	parentSession := fs.String("parent-session", "", "Session id of the agent spawning this one")
	name := fs.String("name", "", "window name, and (by convention) the child's own --name")
	taskFile := fs.String("task-file", "", `file holding the task text to deliver as the child's first message, or "-" for stdin`)
	model := fs.String("model", "", "model the child will run, recorded in the run's meta for kido runs")
	toolsFlag := fs.String("tools", "", "comma-separated tool allowlist the child will run, recorded in the run's meta for kido runs")
	resumeID := fs.String("resume", "", "resume an existing run's own session instead of starting a new one")
	forkSession := fs.String("fork", "", "seed the child's session with this pi session's transcript, so it starts holding the caller's context")
	keepAlive := fs.Bool("keep-alive", false, "the child does not self-reap after going idle (KIDO_AGENT_KEEP_ALIVE)")
	noParent := fs.Bool("no-parent", false, "spawn with no parent edge at all: the child reports to nobody, arms no idle timer, and is never reaped as an orphan")
	if err := fs.Parse(args); err != nil {
		return spawnReq{}, fmt.Errorf("%w\n%s", err, spawnUsage)
	}
	refuse := func(why string) (spawnReq, error) {
		return spawnReq{}, fmt.Errorf("%s\n%s", why, spawnUsage)
	}

	req := spawnReq{keepAlive: *keepAlive, command: fs.Args()}
	if len(req.command) == 0 {
		req.command = []string{"pi"}
	}
	switch {
	case *noParent && (*parentPID > 0 || *parentSession != ""):
		return refuse("--no-parent contradicts --parent-pid/--parent-session; pass one or the other")
	case *parentPID > 0 && *parentSession != "":
		req.parent = &parentEdge{pid: *parentPID, session: *parentSession}
	case *parentPID > 0 || *parentSession != "":
		return refuse("--parent-pid and --parent-session name one parent and are given together")
	}

	if *resumeID != "" {
		switch {
		case *taskFile != "":
			return refuse("--resume keeps the run's original task; --task-file is refused alongside it")
		case *name != "":
			return refuse("--resume keeps the run's original window name; --name is refused alongside it")
		case *forkSession != "":
			return refuse("--resume continues a run's own session; --fork starts a new one from somebody else's, and the two cannot both be asked for")
		}
		runID, err := subrun.ParseID(*resumeID)
		if err != nil {
			return refuse(err.Error())
		}
		req.mode = resume{runID: runID, adopt: req.parent == nil && !*noParent}
		return req, nil
	}

	switch {
	case req.parent == nil && !*noParent:
		return refuse("--parent-pid and --parent-session are required (or --no-parent for a child owned by nobody)")
	case *name == "":
		return refuse("--name is required")
	case *taskFile == "":
		return refuse("--task-file is required")
	}
	if err := checkWindowName(*name); err != nil {
		return spawnReq{}, err
	}
	// --fork goes on the child's command line, so it is held to what a
	// window name is held to: tmux's own parsers are what it has to survive.
	if err := tmuxSafe("--fork", *forkSession); err != nil {
		return spawnReq{}, err
	}
	task, err := readTask(*taskFile)
	if err != nil {
		return spawnReq{}, err
	}
	m := fresh{name: *name, task: task, fork: *forkSession, model: *model}
	if *toolsFlag != "" {
		m.tools = strings.Split(*toolsFlag, ",")
	}
	req.mode = m
	return req, nil
}

func checkWindowName(name string) error {
	if err := tmuxSafe("window name", name); err != nil {
		return err
	}
	if len(name) > maxWindowNameLen {
		return fmt.Errorf("refusing window name %q: %d bytes is over the %d byte limit", name, len(name), maxWindowNameLen)
	}
	return nil
}

func spawnSubagentCmd(args []string) error {
	req, err := parseSpawn(args)
	if err != nil {
		return err
	}
	pane, _, err := callerPane()
	if err != nil {
		return err
	}

	live, err := state.LoadLive()
	if err != nil {
		return err
	}
	self := state.ByPane(live)[pane.PaneID]
	parent := req.parent
	if r, ok := req.mode.(resume); ok && r.adopt && self.ID != "" {
		parent = &parentEdge{pid: self.PID, session: self.ID}
	}
	depth := self.Depth + 1
	if depth > maxDepth {
		return fmt.Errorf("refusing to spawn at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)", depth, maxDepth)
	}
	if parent != nil {
		if _, ok := state.Find(live, parent.session); !ok {
			return fmt.Errorf("--parent-session %q names no currently live agent; the child would be closed within moments as an orphan (internal/reap's rule 2) - pass --no-parent for a child owned by nobody, or name an agent that is actually running", parent.session)
		}
	}

	command := req.command
	var meta subrun.Meta
	mint := false
	switch m := req.mode.(type) {
	case fresh:
		meta = subrun.Meta{
			ID: subrun.NewID(), Name: m.name, Kind: subrun.KindAgent,
			Cwd: pane.CurrentPath, Model: m.model, Tools: m.tools, StartedAt: time.Now(),
		}
		// The run id is the child's own pi session id; any other command has
		// no session to name and is left as given. Measured against pi 0.85.1,
		// --fork and --session-id compose: createSessionManager (main.js) forks
		// the resolved source through SessionManager.forkFrom with the given id,
		// so a forked child still holds the run id its identity proof is read
		// from (docs/design-subagents.md, "Forking the caller's context").
		if command[0] == "pi" {
			var flags []string
			if m.fork != "" {
				flags = append(flags, "--fork", m.fork)
			}
			flags = append(flags, "--session-id", string(meta.ID))
			command = slices.Insert(command, 1, flags...)
		}
	case resume:
		if meta, err = subrun.ReadMeta(m.runID); err != nil {
			return fmt.Errorf("run %q: %w", m.runID, err)
		}
		if _, ok, err := subrun.EffectiveOutcome(meta.ID, meta.PID); err != nil {
			return err
		} else if !ok {
			return fmt.Errorf("run %q is still running (pid %d); resuming a live agent makes no sense", meta.ID, meta.PID)
		}
		// A run with no pi session file on disk has nothing for `pi --session`
		// to resume - the id is free, not stale, since it is also the child's
		// own session id (docs/design-subagents.md, "The run record") - so
		// --session-id mints a fresh session under that same id instead, and
		// the stored task is redelivered as if this were a fresh spawn.
		mint = !piSessionFileExists(meta.Cwd, meta.ID)
		if command[0] == "pi" {
			if mint {
				command = slices.Insert(command, 1, "--session-id", string(meta.ID))
			} else {
				command = slices.Insert(command, 1, "--session", string(meta.ID))
			}
			if meta.Model != "" && !slices.Contains(command[1:], "--model") {
				command = append(command, "--model", meta.Model)
			}
			if len(meta.Tools) > 0 && !slices.Contains(command[1:], "--tools") {
				command = append(command, "--tools", strings.Join(meta.Tools, ","))
			}
		}
	}
	if err := validateModel(command); err != nil {
		return err
	}

	// meta.Cwd is left as the run's own on a resume: pi sessions are
	// project-scoped, and `pi --session` run from any other directory asks
	// to fork into the current one instead of resuming, so the window is
	// created there rather than at the caller's.
	meta.ParentSession, meta.Depth, meta.KeepAlive = "", depth, meta.KeepAlive || req.keepAlive
	if parent != nil {
		meta.ParentSession = parent.session
	}
	switch m := req.mode.(type) {
	case fresh:
		if err := subrun.Create(meta.ID, m.task); err != nil {
			return err
		}
		if err := subrun.WriteMeta(meta); err != nil {
			return err
		}
	case resume:
		// A resumed run is running again: its old outcome and the first
		// attempt's captured screen no longer describe it, and
		// RecordOutcome's O_EXCL would otherwise refuse every exit path that
		// follows this one. A minted session starts holding the same task
		// file, and pi/kido-agents.ts's deliverTask skips it while the
		// "delivered" marker the earlier attempt left exists.
		if err := subrun.ResetForResume(meta.ID, mint); err != nil {
			return err
		}
	}
	return createRunWindow(meta, pane.SessionID, runEnv(meta.ID, parent, depth, meta.KeepAlive), command)
}

func callerPane() (tmux.Pane, []tmux.Pane, error) {
	panes, err := listPanes()
	if err != nil {
		return tmux.Pane{}, nil, err
	}
	caller := os.Getenv("TMUX_PANE")
	pane, ok := findPane(panes, caller)
	if !ok {
		return tmux.Pane{}, panes, fmt.Errorf("pane %q not found", caller)
	}
	return pane, panes, nil
}

// new-window runs its command with the tmux server's environment, not the
// caller's, so KIDO_AGENT_* is the only channel a child has. The parent
// edge is left out when there is nobody to name, rather than reported as
// zero or empty, because internal/reap would read a zero as an orphan's.
func runEnv(runID subrun.ID, parent *parentEdge, depth int, keepAlive bool) []string {
	env := []string{
		"KIDO_AGENT_TASK_FILE=" + subrun.TaskPath(runID),
		// Unconditional: a child that is not pi has no --session-id to learn
		// the run id from, and `kido run-outcome` needs it.
		"KIDO_AGENT_RUN_ID=" + string(runID),
		"KIDO_AGENT_DEPTH=" + strconv.Itoa(depth),
	}
	if parent != nil {
		env = append(env,
			"KIDO_AGENT_PARENT_PID="+strconv.Itoa(parent.pid),
			"KIDO_AGENT_PARENT_SESSION="+parent.session)
	}
	if keepAlive {
		env = append(env, "KIDO_AGENT_KEEP_ALIVE=1")
	}
	return env
}

// The mark is the only thing that makes the window reapable: the sweep,
// the sidebar's tree and the window-cycling keys all key off it, so an
// unmarked window is uncollectable forever and a failed mark kills the
// window rather than strand it.
func createRunWindow(meta subrun.Meta, sessionID string, env, command []string) error {
	windowID, paneID, panePID, err := newWindow(sessionID, meta.Name, meta.Cwd, env, command)
	if err != nil {
		subrun.RecordOutcome(meta.ID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	meta.Pane, meta.PID = paneID, panePID
	if err := subrun.WriteMeta(meta); err != nil {
		return err
	}
	if err := markRun(paneID, string(meta.ID)); err != nil {
		// A window that has already closed cannot be marked and does not need
		// to be. A bash run's own wrapper already records and reports its
		// ending from inside the window; an agent run has no such wrapper, so
		// it keeps the recorded failure below instead.
		if meta.Kind == subrun.KindBash && !windowExists(windowID) {
			printCreated(meta, windowID, paneID)
			return nil
		}
		killWindow(windowID)                                                                                    //nolint:errcheck // best effort cleanup; the mark error is what matters
		subrun.RecordOutcome(meta.ID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	printCreated(meta, windowID, paneID)
	return nil
}

// printCreated's output is contract: pi/kido-agents.ts parses the window,
// pane and run ids back out of it. A bash run carries a fourth field, the
// file its output is teed to.
func printCreated(meta subrun.Meta, windowID, paneID string) {
	if meta.Kind == subrun.KindBash {
		fmt.Printf("%s %s %s %s\n", windowID, paneID, meta.ID, subrun.OutputPath(meta.ID))
		return
	}
	fmt.Printf("%s %s %s\n", windowID, paneID, meta.ID)
}

// piSessionFileExists reports whether id has a pi session file under
// cwd's session directory: pi names one "<timestamp>_<id>.jsonl", so any
// entry ending in "_<id>.jsonl" is a match. An unresolvable directory (no
// $HOME) reads as present, so a check kido has no way to actually perform
// fails open rather than blocking every resume on a guess.
//
// The directory mirrors pi 0.85.1's own getDefaultSessionDirPath
// (session-manager.js): PI_CODING_AGENT_SESSION_DIR overrides outright;
// otherwise it is <agentDir>/sessions/--<cwd, its slashes and colons
// turned to dashes>--, with PI_CODING_AGENT_DIR overriding <agentDir> the
// same way pi itself honours it. This does not walk pi's own
// settings.json "sessionDir" override (a project- or agent-dir-level
// setting) - a real gap, noted in docs/design.md, rather than kido
// reimplementing pi's full settings resolution just to check one file's
// existence.
func piSessionFileExists(cwd string, id subrun.ID) bool {
	dir := os.Getenv("PI_CODING_AGENT_SESSION_DIR")
	if dir == "" {
		agentDir := os.Getenv("PI_CODING_AGENT_DIR")
		if agentDir == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return true
			}
			agentDir = filepath.Join(home, ".pi", "agent")
		}
		safe := "--" + strings.NewReplacer("/", "-", "\\", "-", ":", "-").Replace(strings.TrimPrefix(cwd, "/")) + "--"
		dir = filepath.Join(agentDir, "sessions", safe)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	suffix := "_" + string(id) + ".jsonl"
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), suffix) {
			return true
		}
	}
	return false
}

// Run with kido's own environment untouched, since which providers are
// configured is a per-user setting.
var listModels = func() ([]byte, error) {
	return exec.Command("pi", "--list-models").Output()
}

// A model no configured pi provider can run would otherwise let pi accept
// it, print "Use /login to log into a provider via OAuth or API key" and
// exit 0 having run no turn. This checks against `pi --list-models` by
// exact "provider/model" match, the same resolution pi's own --model flag
// gets; a bare alias like "sonnet" is never a pi model id and is refused
// the same way a misconfigured full id is.
func validateModel(command []string) error {
	model := ""
	if command[0] == "pi" {
		if i := slices.Index(command, "--model"); i >= 0 && i+1 < len(command) {
			model = command[i+1]
		}
	}
	if model == "" {
		return nil
	}
	out, err := listModels()
	if err != nil {
		return fmt.Errorf("could not validate model %q: pi --list-models: %w", model, err)
	}
	// pi --list-models's own table: a header line, skipped by position
	// rather than matched by wording, then one row per model with the
	// provider in column 1 and the model id in column 2. The refusal's list
	// is grouped by provider.
	byProvider := map[string][]string{}
	var providers []string
	for i, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		fields := strings.Fields(line)
		if i == 0 || len(fields) < 2 {
			continue
		}
		if fields[0]+"/"+fields[1] == model {
			return nil
		}
		if _, ok := byProvider[fields[0]]; !ok {
			providers = append(providers, fields[0])
		}
		byProvider[fields[0]] = append(byProvider[fields[0]], fields[1])
	}
	for i, p := range providers {
		providers[i] = p + "/{" + strings.Join(byProvider[p], ",") + "}"
	}
	return fmt.Errorf("model %q is not a model of a configured provider; configured: %s", model, strings.Join(providers, ", "))
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
