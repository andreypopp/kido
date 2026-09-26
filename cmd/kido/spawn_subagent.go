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

// newWindow and markSubagent are tmux.NewWindow and tmux.MarkSubagent,
// indirected so tests can run spawnCmd without a tmux server.
var (
	newWindow        = tmux.NewWindow
	markSubagent     = tmux.MarkSubagent
	markSubagentPane = tmux.MarkSubagentPane
	windowExists     = tmux.WindowExists
)

func spawnUsage() string {
	return "usage: kido spawn_subagent --parent-pid PID --parent-session ID --name NAME --task-file FILE|- [--depth N] [--fork SESSION_ID] [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n" +
		"   or: kido spawn_subagent --no-parent --name NAME --task-file FILE|- [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n" +
		"   or: kido spawn_subagent --resume RUN_ID [--parent-pid PID --parent-session ID | --no-parent] [--keep-alive] [-- COMMAND...]"
}

// spawnSubagentCmd implements `kido spawn_subagent`: it creates a detached window in the
// caller's own tmux session (found from $TMUX_PANE) running COMMAND,
// defaulting to `pi`, with KIDO_AGENT_* set in its environment, and
// prints the new window id, pane id and run id, space-separated. The
// task goes in a file in the run's directory, never on the command line;
// the window name does go on the command line and is checked with
// tmuxConfUnsafe. See docs/design.md, "Spawning".
func spawnSubagentCmd(args []string) error {
	fs := flag.NewFlagSet("spawn_subagent", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	parentPID := fs.Int("parent-pid", 0, "pid of the agent spawning this one")
	parentSession := fs.String("parent-session", "", "Session id of the agent spawning this one")
	// --depth is accepted (pi/kido-agents.ts sends it for its own early
	// refusal) but never consulted for the child's depth: see callerDepth
	// below. It is parsed only so a negative value can be rejected.
	claimedDepth := fs.Int("depth", -1, "the caller's own claimed depth; accepted but not trusted, see callerDepth")
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
		return fmt.Errorf("%w\n%s", err, spawnUsage())
	}
	depthGiven := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "depth" {
			depthGiven = true
		}
	})
	resuming := *resumeID != ""
	parentGiven := *parentPID > 0 || *parentSession != ""

	switch {
	case *noParent && parentGiven:
		return fmt.Errorf("--no-parent contradicts --parent-pid/--parent-session; pass one or the other\n%s", spawnUsage())
	case !resuming && !*noParent && *parentPID <= 0:
		return fmt.Errorf("--parent-pid is required (or --no-parent for a child owned by nobody)\n%s", spawnUsage())
	case !resuming && !*noParent && *parentSession == "":
		return fmt.Errorf("--parent-session is required (or --no-parent for a child owned by nobody)\n%s", spawnUsage())
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
	case resuming && *forkSession != "":
		return fmt.Errorf("--resume continues a run's own session; --fork starts a new one from somebody else's, and the two cannot both be asked for\n%s", spawnUsage())
	}

	if resuming {
		return spawnResume(*resumeID, *parentPID, *parentSession, fs.Args(), *keepAlive, *noParent)
	}

	if i := strings.IndexAny(*name, tmuxConfUnsafe); i >= 0 {
		return fmt.Errorf("refusing window name %q: it contains %q, which cannot survive tmux's own command-line parsing", *name, (*name)[i:i+1])
	}
	if len(*name) > maxWindowNameLen {
		return fmt.Errorf("refusing window name %q: %d bytes is over the %d byte limit", *name, len(*name), maxWindowNameLen)
	}
	// --fork goes on the child's command line, so it is held to what a
	// window name is held to: tmux's own parsers are what it has to survive.
	if i := strings.IndexAny(*forkSession, tmuxConfUnsafe); i >= 0 {
		return fmt.Errorf("refusing --fork %q: it contains %q, which cannot survive tmux's own command-line parsing", *forkSession, (*forkSession)[i:i+1])
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
	if err := validateModel(extractModel(command)); err != nil {
		return err
	}

	pane, _, err := callerPane()
	if err != nil {
		return err
	}

	// The child's depth is derived from the caller's own state record, not
	// from --depth, which a caller at the ceiling could understate. A
	// caller with no record is depth 0, which can only make the ceiling
	// stricter (docs/design.md, "The depth ceiling is derived").
	//
	// One read, two views of it: the pane-keyed one settles who owns the
	// caller's pane, and the whole live slice answers "is this session
	// running anywhere" for liveSession below - a parent's own record is
	// exactly the one a pane collision drops from the per-pane view
	// (AGENTS.md, "Agent state").
	live, err := state.LoadLive()
	if err != nil {
		return err
	}
	states := state.ByPane(live)
	depth := states[pane.PaneID].Depth + 1
	if depth > maxDepth {
		return fmt.Errorf("refusing to spawn at depth %d: maximum nesting is %d (root 0, subagent 1, subagent 2)", depth, maxDepth)
	}
	// A made-up parent edge used to be accepted here and cost the child its
	// window moments later: internal/reap's rule 2 closes any marked window
	// whose child names a ParentSession no live record claims, and it keeps
	// no history, so an invented session and one whose process has died
	// read identically to it - there was never going to be an error message
	// for the human to see. The tool cannot trip this, since a pi session
	// spawning names itself; a human at a shell could, and --no-parent is
	// now the honest spelling of what they were reaching for.
	if *parentSession != "" && !liveSession(live, *parentSession) {
		return fmt.Errorf("--parent-session %q names no currently live agent; the child would be closed within moments as an orphan (internal/reap's rule 2) - pass --no-parent for a child owned by nobody, or name an agent that is actually running", *parentSession)
	}

	runID := subrun.NewID()
	if err := subrun.Create(runID, task); err != nil {
		return err
	}
	meta := subrun.Meta{
		ID: runID, Name: *name, Kind: subrun.KindAgent, ParentSession: *parentSession, Depth: depth,
		Cwd: pane.CurrentPath, Model: *model, Tools: tools, KeepAlive: *keepAlive,
		StartedAt: time.Now(),
	}

	// The run id is the child's own pi session id; any other command has
	// no session to name and is left as given. Measured against pi 0.85.1,
	// --fork and --session-id compose: createSessionManager (main.js) forks
	// the resolved source through SessionManager.forkFrom with the given id,
	// so a forked child still holds the run id its identity proof is read
	// from (docs/design-subagents.md, "Forking the caller's context").
	if command[0] == "pi" {
		var flags []string
		if *forkSession != "" {
			flags = append(flags, "--fork", *forkSession)
		}
		flags = append(flags, "--session-id", runID)
		command = slices.Insert(command, 1, flags...)
	}

	return createRunWindow(meta, pane.SessionID, runEnv(runID, *parentPID, *parentSession, depth, *keepAlive), command)
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
// from a bare human shell - so an empty pid or session is omitted rather
// than reported as zero or empty: the child's own subagent test reads
// whether the variable is there at all, and internal/reap would read a
// zero as an orphan's.
func runEnv(runID string, parentPID int, parentSession string, depth int, keepAlive bool) []string {
	env := []string{
		"KIDO_AGENT_TASK_FILE=" + subrun.TaskPath(runID),
		// Unconditional: a child that is not pi has no --session-id to learn
		// the run id from, and `kido run-outcome` needs it.
		"KIDO_AGENT_RUN_ID=" + runID,
		"KIDO_AGENT_DEPTH=" + strconv.Itoa(depth),
	}
	if parentPID > 0 {
		env = append(env, "KIDO_AGENT_PARENT_PID="+strconv.Itoa(parentPID))
	}
	if parentSession != "" {
		env = append(env, "KIDO_AGENT_PARENT_SESSION="+parentSession)
	}
	if keepAlive {
		env = append(env, "KIDO_AGENT_KEEP_ALIVE=1")
	}
	return env
}

// createRunWindow is the tail both a fresh spawn and a resume end in:
// create the detached window in sessionID, stamp what tmux answered into
// meta, mark the window as a subagent's and print what was created. meta
// arrives fully assembled - its Name and Cwd are what the window is made
// with - and the caller is finished once this returns.
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
		// A meta has to exist before the outcome, or the outcome is
		// invisible: `kido runs` passes over a run directory that has no
		// meta file. A fresh spawn has none yet, so this is where it gets
		// one; a resume's is already on disk and is left exactly as it was,
		// since this attempt never got as far as a window and has nothing
		// truer to say about the run than the last attempt already recorded.
		if _, err := subrun.ReadMeta(meta.ID); err != nil {
			subrun.WriteMeta(meta) //nolint:errcheck // best effort
		}
		subrun.RecordOutcome(meta.ID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	meta.Window, meta.Pane, meta.PID = windowID, paneID, panePID
	if err := subrun.WriteMeta(meta); err != nil {
		return err
	}
	if err := markSubagent(windowID, tmux.SubagentMark(meta.ID, meta.ParentSession, meta.Depth)); err != nil {
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
		if meta.EffectiveKind() == subrun.KindBash && !windowExists(windowID) {
			printCreated(meta, windowID, paneID)
			return nil
		}
		killWindow(windowID)                                                                                    //nolint:errcheck // best effort cleanup; the mark error is what matters
		subrun.RecordOutcome(meta.ID, subrun.Outcome{Result: subrun.Failed, Text: err.Error(), At: time.Now()}) //nolint:errcheck // best effort
		return err
	}
	// Best effort: a failure here only costs this run the pane-level
	// disambiguation lingeringLabel uses to tell a later split pane apart
	// from the run's own, and it falls back to today's window-wide
	// behaviour for this window rather than losing the run itself.
	markSubagentPane(paneID, meta.ID) //nolint:errcheck // best effort, see above
	printCreated(meta, windowID, paneID)
	return nil
}

// printCreated prints what a spawn made, the line pi/kido-agents.ts
// parses the window, pane and run ids back out of. A bash run carries a
// fourth field, the file its output is teed to: where kido keeps a run's
// output is kido's own to say, and a tool deriving it would be a second
// copy of state.Dir's KIDO_STATE_DIR/XDG precedence.
func printCreated(meta subrun.Meta, windowID, paneID string) {
	if meta.EffectiveKind() == subrun.KindBash {
		fmt.Printf("%s %s %s %s\n", windowID, paneID, meta.ID, subrun.OutputPath(meta.ID))
		return
	}
	fmt.Printf("%s %s %s\n", windowID, paneID, meta.ID)
}

// liveSession reports whether some record in states is session's, and
// its own and is still alive - the same reading internal/reap's rule 2
// uses to decide a subagent's parent is gone, spelled out here so a
// spawn can refuse before creating a window rule 2 would only close
// moments later.
//
// It takes the whole live slice rather than the pane-keyed map for the
// reason the sweep does: the question is whether a session is running
// anywhere, and a pane collision drops a record from the per-pane view.
func liveSession(sessions []state.Session, session string) bool {
	for _, s := range sessions {
		if s.ID == session && state.Alive(s.PID) {
			return true
		}
	}
	return false
}

// spawnResume implements `kido spawn_subagent --resume RUN_ID`: it creates a
// detached window through the identical tmux.NewWindow / markSubagent
// path a fresh spawn uses, but launches `pi --session RUN_ID` instead of
// minting a new one, and continues run id's existing run record instead
// of creating a second one - its task, its history and its id stay
// (docs/design.md, "kido spawn_subagent --resume"). command is fs.Args(): the
// COMMAND after "--", defaulting to plain pi exactly as a fresh spawn
// does.
func spawnResume(runID string, parentPID int, parentSession string, command []string, keepAlive, noParent bool) error {
	meta, err := subrun.ReadMeta(runID)
	if err != nil {
		return fmt.Errorf("run %q: %w", runID, err)
	}

	// EffectiveOutcome's ok is false exactly when the run is still alive
	// and has recorded nothing about itself yet - the one case resuming
	// makes no sense, since the run's own process already holds the
	// session. Any recorded outcome, whatever it says, means the pid is
	// gone (or kido stop_subagent said so), and resuming is what this command is for.
	if _, ok, err := subrun.EffectiveOutcome(runID, meta.PID); err != nil {
		return err
	} else if !ok {
		return fmt.Errorf("run %q is still running (pid %d); resuming a live agent makes no sense", runID, meta.PID)
	}

	// A run with no pi session file on disk has nothing for `pi --session`
	// to resume - the id is free, not stale, since it is also the child's
	// own session id (docs/design-subagents.md, "The run record") - so this
	// mints a fresh session under that same id instead, further down, and
	// redelivers the stored task as if this were a fresh spawn.
	sessionExists := piSessionFileExists(meta.Cwd, runID)

	pane, _, err := callerPane()
	if err != nil {
		return err
	}

	// A caller with no state record - a bare human shell - gets no parent
	// pid or session defaulted for it, exactly as an unreported caller's
	// own depth defaults to 0 below: the resumed run simply has no current
	// parent, same as any other pi session kido never spawned. A caller
	// that does have a record (another agent, or `kido runs`'s printed
	// resume line run from inside a kido-tracked pane) becomes the run's
	// new parent without --parent-pid/--parent-session having to name it.
	// Given explicitly, those flags still win, the same as a fresh spawn,
	// and --no-parent asks for a parentless resume outright: an agent that
	// does have a record can hand over a run it does not want to own.
	live, err := state.LoadLive()
	if err != nil {
		return err
	}
	self := state.ByPane(live)[pane.PaneID]
	if !noParent {
		if parentPID == 0 {
			parentPID = self.PID
		}
		if parentSession == "" {
			parentSession = self.ID
		}
	}
	// internal/reap's rule 2 closes any marked window whose child reports
	// a ParentSession that names nobody currently alive - it has no
	// memory of history, so "never heard of that session" and "that
	// session's process has since died" read identically to it, and
	// KIDO_AGENT_PARENT_SESSION below is exactly what makes the resumed
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
	if parentSession != "" && !liveSession(live, parentSession) {
		return fmt.Errorf("--parent-session %q names no currently live agent; the resumed run would be reaped within moments as an orphan (internal/reap's rule 2) - omit --parent-pid/--parent-session for a parentless resume, or give the session id of an agent that is actually running", parentSession)
	}

	if len(command) == 0 {
		command = []string{"pi"}
	}
	if command[0] == "pi" {
		if sessionExists {
			command = slices.Insert(command, 1, "--session", runID)
		} else {
			// No pi session file for this run id, so there is nothing to
			// resume by --session; --session-id mints a fresh one under the
			// same id instead, which is free precisely because no file claims
			// it.
			command = slices.Insert(command, 1, "--session-id", runID)
		}
		// A bare `--resume` with no `-- pi --model ...` used to come up on
		// pi's default provider, which may have no API key configured -
		// the run's own meta already remembers what it ran under, and a
		// caller who wants something else still wins by naming --model
		// explicitly in the command after --.
		if meta.Model != "" && !slices.Contains(command[1:], "--model") {
			command = append(command, "--model", meta.Model)
		}
		// The tool allowlist comes back for the same reason the model does,
		// and more urgently: a narrow toolset is the blast-radius bound the
		// depth ceiling is not, and a resume that quietly handed the full set
		// back widened it without anyone asking. A command naming its own
		// --tools still wins.
		if len(meta.Tools) > 0 && !slices.Contains(command[1:], "--tools") {
			command = append(command, "--tools", strings.Join(meta.Tools, ","))
		}
	}
	if err := validateModel(extractModel(command)); err != nil {
		return err
	}
	// keepAlive is the run's own too: a deliberately long-lived helper that
	// came back arming a thirty-second idle timer was not the helper that
	// was spawned. An explicit --keep-alive still wins, and there is no way
	// to turn it back off, which is the same asymmetry --model has - the
	// recorded value is the default, not a ceiling.
	keepAlive = keepAlive || meta.KeepAlive

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
	if !sessionExists {
		// The fresh session minted above starts holding the same task file,
		// and pi/kido-agents.ts's deliverTask skips redelivering it once the
		// sibling "delivered" marker exists - which it does, left by the
		// attempt that read the task and then never ran a turn on it. Without
		// clearing it here the respawned session would come up idle with no
		// task at all, and thirty seconds later end exactly as the one before
		// it did.
		if err := subrun.ClearDelivered(runID); err != nil {
			return err
		}
	}

	// The parent edge the resume claims is the run's from here on, and
	// meta.Cwd is left as the run's own: pi sessions are project-scoped,
	// and `pi --session` run from any other directory asks to fork into
	// the current one instead of resuming, so the window is created there
	// rather than at the caller's.
	meta.ParentSession, meta.Depth, meta.KeepAlive = parentSession, depth, keepAlive
	return createRunWindow(meta, pane.SessionID, runEnv(runID, parentPID, parentSession, depth, keepAlive), command)
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

// listModels runs `pi --list-models`, indirected so a test never shells
// out to a real pi. It is run with kido's own environment untouched -
// the caller's PATH and HOME, exactly what the spawn itself would use to
// resolve a bare "pi" - since which providers are configured is a
// per-user setting, not kido's to guess at.
var listModels = func() ([]byte, error) {
	return exec.Command("pi", "--list-models").Output()
}

// extractModel returns the --model argument on a `pi` command line, or ""
// when there is none or command is not literally pi: that is the one
// value that will actually reach pi's own model resolution, whether it
// arrived as a fresh spawn's child argv or spawnResume's meta-derived
// default.
func extractModel(command []string) string {
	if len(command) == 0 || command[0] != "pi" {
		return ""
	}
	for i, a := range command {
		if a == "--model" && i+1 < len(command) {
			return command[i+1]
		}
	}
	return ""
}

// modelRow is one line of `pi --list-models`'s table.
type modelRow struct{ provider, id string }

// parseModelRows reads pi --list-models's own table: a header line,
// then one row per model with the provider in column 1 and the model id
// in column 2, whitespace-separated. The header is skipped by position,
// not matched by wording, since that wording is pi's to change.
func parseModelRows(out []byte) []modelRow {
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	var rows []modelRow
	for i, line := range lines {
		if i == 0 || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		rows = append(rows, modelRow{provider: fields[0], id: fields[1]})
	}
	return rows
}

// describeModels renders a refusal's "configured: ..." list, grouped by
// provider so a machine with many models does not spell every one of them
// out on its own line.
func describeModels(rows []modelRow) string {
	byProvider := map[string][]string{}
	var providers []string
	for _, r := range rows {
		if _, ok := byProvider[r.provider]; !ok {
			providers = append(providers, r.provider)
		}
		byProvider[r.provider] = append(byProvider[r.provider], r.id)
	}
	parts := make([]string, len(providers))
	for i, p := range providers {
		parts[i] = p + "/{" + strings.Join(byProvider[p], ",") + "}"
	}
	return strings.Join(parts, ", ")
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
func validateModel(model string) error {
	if model == "" {
		return nil
	}
	out, err := listModels()
	if err != nil {
		return fmt.Errorf("could not validate model %q: pi --list-models: %w", model, err)
	}
	rows := parseModelRows(out)
	for _, row := range rows {
		if row.provider+"/"+row.id == model {
			return nil
		}
	}
	return fmt.Errorf("model %q is not a model of a configured provider; configured: %s", model, describeModels(rows))
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
