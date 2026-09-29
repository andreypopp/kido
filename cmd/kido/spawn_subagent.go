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

// newWindow and markRun are tmux.NewWindow and tmux.MarkRun, indirected
// so tests can run spawnCmd without a tmux server.
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
	runID string
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
	// --no-parent is the whole surface for a child owned by nobody, and it
	// is a flag rather than an empty --parent-session because the two
	// failures are not alike: a script whose parent session came out empty means
	// to name a parent and has lost it, and silently spawning an
	// uncollectable window for it would be the wrong reading. A flag cannot
	// be arrived at by accident. spawn_subagent the tool never passes it -
	// a pi session spawning always names itself - so this is a human's
	// entrance only.
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
		req.mode = resume{runID: *resumeID, adopt: req.parent == nil && !*noParent}
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

// spawnSubagentCmd implements `kido spawn_subagent`: it creates a detached window in the
// caller's own tmux session (found from $TMUX_PANE) running COMMAND,
// defaulting to `pi`, with KIDO_AGENT_* set in its environment, and
// prints the new window id, pane id and run id, space-separated. The
// task goes in a file in the run's directory, never on the command line;
// the window name does go on the command line and is checked with
// tmuxConfUnsafe. See docs/design.md, "Spawning".
func spawnSubagentCmd(args []string) error {
	req, err := parseSpawn(args)
	if err != nil {
		return err
	}
	pane, _, err := callerPane()
	if err != nil {
		return err
	}

	// The child's depth is derived from the caller's own state record. A
	// caller with no record is depth 0, which can only make the ceiling
	// stricter (docs/design.md, "The depth ceiling is derived").
	//
	// One read, two views of it: the pane-keyed one settles who owns the
	// caller's pane, and the whole live slice answers "is this session
	// running anywhere" for state.Find below - a parent's own record is
	// exactly the one a pane collision drops from the per-pane view
	// (AGENTS.md, "Agent state").
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
			flags = append(flags, "--session-id", meta.ID)
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
				command = slices.Insert(command, 1, "--session-id", meta.ID)
			} else {
				command = slices.Insert(command, 1, "--session", meta.ID)
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
		// follows this one.
		if err := subrun.ClearOutcome(meta.ID); err != nil {
			return err
		}
		if err := subrun.ClearScreen(meta.ID); err != nil {
			return err
		}
		// A minted session starts holding the same task file, and
		// pi/kido-agents.ts's deliverTask skips it while the "delivered"
		// marker the earlier attempt left exists.
		if mint {
			if err := subrun.ClearDelivered(meta.ID); err != nil {
				return err
			}
		}
	}
	return createRunWindow(meta, pane.SessionID, runEnv(meta.ID, parent, depth, meta.KeepAlive), command)
}

// callerPane resolves the pane kido was run from - $TMUX_PANE, which tmux
// sets in every process it starts - against tmux's own pane list, which
// it returns alongside. A command that acts "here" rather than on a named
// target needs both: the pane says which session and which directory, the
// list is what everything else is looked up in.
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

// runEnv is the KIDO_AGENT_* environment a run's window is created with,
// the only channel a child has: new-window runs its command with the tmux
// server's environment, not the caller's. The parent edge is left out
// when there is nobody to name - a --no-parent spawn, or a run resumed
// from a bare human shell - rather than reported as zero or empty: the
// child's own subagent test reads whether the variable is there at all,
// and internal/reap would read a zero as an orphan's.
func runEnv(runID string, parent *parentEdge, depth int, keepAlive bool) []string {
	env := []string{
		"KIDO_AGENT_TASK_FILE=" + subrun.TaskPath(runID),
		// Unconditional: a child that is not pi has no --session-id to learn
		// the run id from, and `kido run-outcome` needs it.
		"KIDO_AGENT_RUN_ID=" + runID,
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

// createRunWindow is the tail both a spawn and an async run end in:
// create the detached window in sessionID, stamp what tmux answered into
// meta, mark the run's own pane and print what was created. meta arrives
// fully assembled - its Name and Cwd are what the window is made with -
// and a new run's is already on disk, so a wrapper started in the window
// can read it; a resume's is rewritten only once its window exists.
//
// The mark is the only thing that makes the window reapable: the sweep,
// the sidebar's tree and the window-cycling keys all key off it, so an
// unmarked window is uncollectable forever and a failed mark kills the
// window rather than strand it. Both failures record the run failed,
// since an error returned here is all the caller ever sees of it.
//
// What it prints is contract; printCreated owns that line.
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
	if err := markRun(paneID, meta.ID); err != nil {
		// A window that has already closed cannot be marked and does not
		// need to be: the mark is what makes a window reapable, and there
		// is nothing left to reap. For a bash run that is an ordinary
		// ending - the command in it ran, and `kido async-run` records and
		// reports how it went from inside the window - which is why no
		// outcome is recorded over its own here. Otherwise a creation error
		// is the standing answer for every command fast enough to beat
		// remain-on-exit, which is every typo.
		//
		// An agent run has no such wrapper, and nothing else ever reaches
		// it: a window tmux has lost carries no marked pane, so neither
		// sweep rule can find it, and a pi that vanished this fast never
		// reached its task. It keeps the recorded failure it always got.
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

// printCreated prints what a spawn made, the line pi/kido-agents.ts
// parses the window, pane and run ids back out of. A bash run carries a
// fourth field, the file its output is teed to: where kido keeps a run's
// output is kido's own to say, and a tool deriving it would be a second
// copy of state.Dir's KIDO_STATE_DIR/XDG precedence.
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
func piSessionFileExists(cwd, id string) bool {
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
	suffix := "_" + id + ".jsonl"
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), suffix) {
			return true
		}
	}
	return false
}

// listModels runs `pi --list-models`, indirected so a test never shells
// out to a real pi. It is run with kido's own environment untouched -
// the caller's PATH and HOME, exactly what the spawn itself would use to
// resolve a bare "pi" - since which providers are configured is a
// per-user setting, not kido's to guess at.
var listModels = func() ([]byte, error) {
	return exec.Command("pi", "--list-models").Output()
}

// validateModel refuses a model no configured pi provider can actually
// run, rather than letting pi accept it, print "Use /login to log into a
// provider via OAuth or API key" and exit 0 having run no turn thirty
// seconds later (the failure mode a bare alias like "sonnet" - never a
// pi model id - used to produce). It checks against `pi --list-models`,
// the same resolution pi's own --model flag is handed to, and by exact
// "provider/model" match: a full id whose provider is not configured is
// refused exactly as a bare alias is. A pi that cannot even list its
// models cannot start one either, so a failure running the command
// refuses the spawn rather than letting it through unchecked.
//
// The model checked is the --model argument on a `pi` command line; any
// other command's is not pi's to resolve.
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
