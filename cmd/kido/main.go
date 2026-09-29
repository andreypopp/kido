// Command kido renders a tmux sidebar listing sessions and panes, with
// agent sessions badged by activity status. It runs inside the side status
// line of the andreypopp/tmux fork (side-status-command).
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/sahilm/fuzzy"

	"kido/internal/hook"
	"kido/internal/msg"
	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
	"kido/internal/ui"
)

// commands are the subcommands that report an error and exit 1 on
// failure (dispatch): every kido subcommand except the irregular cases
// in main's switch and exitCommands below.
var commands = map[string]func([]string) error{
	"set_status":         setStatusCmd,
	"list_agents":        listAgentsCmd,
	"agent-alive":        agentAliveCmd,
	"children-alive":     childrenAliveCmd,
	"snapshot":           func([]string) error { return snapshot(os.Stdout) },
	"switch-session":     func(args []string) error { return switchCmd("switch-session", args, tmux.SwitchSession) },
	"switch-window":      func(args []string) error { return switchCmd("switch-window", args, tmux.SwitchWindow) },
	"interrupt_subagent": interruptSubagentCmd,
	"stop_subagent":      stopSubagentCmd,
	"spawn_subagent":     spawnSubagentCmd,
	"async_bash":         asyncBashCmd,
	"close-run":          closeRunCmd,
	"window-focused":     windowFocusedCmd,
	"reap":               reapCmd,
	"run-outcome":        runOutcomeCmd,
	"runs":               runsCmd,
	"ssh":                sshCmd,
	"shell":              shellCmd,
}

// exitCommands are the subcommands that return their own process exit
// code rather than going through dispatch: prompt and the message-sending
// commands, which distinguish more outcomes than success/failure.
var exitCommands = map[string]func([]string, io.Reader) int{
	"prompt":         prompt,
	"message_agent":  messageAgentCmd,
	"ask_agent":      askAgentCmd,
	"notify_parent":  notifyParentCmd,
	"steer_subagent": steerSubagentCmd,
}

// subcommands lists every kido subcommand, so unknownSubcommand can name
// them: commands and exitCommands' keys, sorted, plus the switch's own
// irregular cases, which take a shape neither table can hold (hook must
// never fail the caller; agent-status has its own exit code; debug-log
// and inbox-path print a path; async-run does not yet take the stdin
// exitCommands requires, since async_run.go is another phase's file).
var subcommands = func() []string {
	names := []string{"hook", "agent-status", "debug-log", "inbox-path", "async-run"}
	for name := range commands {
		names = append(names, name)
	}
	for name := range exitCommands {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}()

// suggestSubcommand returns the known subcommand that most plainly shares
// its letters, in order, with what the user typed, or "" when none does.
// It matches in both directions, because a near miss comes in both
// shapes: what was typed can be longer than the subcommand it meant
// (fuzzy.Find(cmd, [name]) - does cmd's spelling occur inside name) or
// shorter (fuzzy.Find(name, [cmd])). Only the first direction existed
// when every subagent tool's name was longer than its command's; now that
// the two vocabularies are one, the near miss that remains is the
// opposite shape - the old, short name (`agents`, `message`, `spawn`) for
// a command that has since grown a suffix - and it needs the second.
func suggestSubcommand(name string) string {
	best, bestScore := "", 0
	for _, cmd := range subcommands {
		score, ok := 0, false
		for _, m := range [][2]string{{cmd, name}, {name, cmd}} {
			if matches := fuzzy.Find(m[0], []string{m[1]}); len(matches) > 0 && (!ok || matches[0].Score > score) {
				score, ok = matches[0].Score, true
			}
		}
		if ok && (best == "" || score > bestScore) {
			best, bestScore = cmd, score
		}
	}
	return best
}

// unknownSubcommand reports that name is not a kido subcommand and exits
// 1. Falling through to the interactive UI's own "no tmux client" error
// used to hide this case entirely, describing a tmux problem when the
// real one was a typo or a wrong name.
func unknownSubcommand(name string) {
	fmt.Fprintf(os.Stderr, "kido: unknown subcommand %q\n", name)
	if suggestion := suggestSubcommand(name); suggestion != "" {
		fmt.Fprintf(os.Stderr, "did you mean %q?\n", suggestion)
	}
	fmt.Fprintln(os.Stderr, "subcommands:", strings.Join(subcommands, ", "))
	os.Exit(1)
}

// hookDebugEnv switches on the debug log `kido hook` appends every event
// it receives to. Claude Code runs the hook, so nothing kido is told can
// carry a flag; what reaches it is the environment of the pane Claude Code
// was started in.
const hookDebugEnv = "KIDO_HOOK_DEBUG"

// exitSessionHeld is what `kido agent-status` exits with when another
// live process holds the session id it was told to report under. It is a
// code of its own because the caller acts on it: pi/kido-status.ts stops
// reporting for the rest of the session and tells its user once, which
// it cannot do from a message it would have to match on (docs/design.md,
// "One holder per session id").
const exitSessionHeld = 6

// dispatch runs fn for a subcommand named name, printing "kido <name>:
// <err>" to stderr and exiting 1 on failure. hook (which must never fail
// the caller) and prompt and the message-sending commands (which return
// their own exit codes) do not go through it.
func dispatch(name string, fn func() error) {
	if err := fn(); err != nil {
		fmt.Fprintln(os.Stderr, "kido "+name+":", err)
		os.Exit(1)
	}
}

func main() {
	if len(os.Args) > 1 {
		switch name := os.Args[1]; name {
		case "hook":
			if len(os.Args) > 2 {
				fmt.Fprintln(os.Stderr, "usage: kido hook")
				return // never fail the Claude Code hook
			}
			if err := runHook(os.Stdin, os.Getenv(hookDebugEnv) != ""); err != nil {
				fmt.Fprintln(os.Stderr, "kido hook:", err)
			}
			return // never fail the Claude Code hook
		case "agent-status":
			if err := agentStatus(os.Args[2:]); err != nil {
				fmt.Fprintln(os.Stderr, "kido agent-status:", err)
				code := 1
				var held *state.HeldError
				if errors.As(err, &held) {
					code = exitSessionHeld
				}
				os.Exit(code)
			}
			return
		case "debug-log":
			fmt.Println(filepath.Join(state.Dir(), "debug.log"))
			return
		case "inbox-path":
			if len(os.Args) != 3 {
				fmt.Fprintln(os.Stderr, "usage: kido inbox-path NAME")
				os.Exit(1)
			}
			path, err := msg.InboxPath(os.Args[2])
			if err != nil {
				fmt.Fprintln(os.Stderr, "kido inbox-path:", err)
				os.Exit(1)
			}
			fmt.Println(path)
			return
		case "async-run":
			os.Exit(asyncRunCmd(os.Args[2:]))
		default:
			if fn, ok := commands[name]; ok {
				dispatch(name, func() error { return fn(os.Args[2:]) })
				return
			}
			if fn, ok := exitCommands[name]; ok {
				os.Exit(fn(os.Args[2:], os.Stdin))
			}
			// A leading flag (bare `kido -client NAME`, or any other flag)
			// falls through to the interactive UI below, same as always.
			// Anything else is a typo or an old name - every subagent tool
			// now names the subcommand it invokes, so what reaches here is
			// most often a command's former spelling - and the old
			// fallthrough reported a misleading tmux-client error instead
			// of naming the mismatch, so say so instead of guessing at a
			// client.
			if !strings.HasPrefix(name, "-") {
				unknownSubcommand(name)
				return
			}
		}
	}

	// Bare `kido` is the launcher: it starts or attaches to kido's own
	// server. The one exception is the side column, which the fork runs as
	// bare `kido` too and tells apart by $TMUX_SIDE_CLIENT - the variable
	// that already decides ui.Options.Standalone below. Anything with an
	// argument, a flag included, is a command or the picker, as before.
	if len(os.Args) == 1 && os.Getenv("TMUX_SIDE_CLIENT") == "" {
		if err := launch(); err != nil {
			fmt.Fprintln(os.Stderr, "kido:", err)
			os.Exit(1)
		}
		return
	}

	opts := ui.Options{}
	flag.DurationVar(&opts.Interval, "interval", 100*time.Millisecond, "refresh interval; tmux changes also refresh immediately")
	flag.StringVar(&opts.Client, "client", "", "tmux client to act on; defaults to $TMUX_SIDE_CLIENT, and is required without it")
	flag.Parse()

	if os.Getenv("TMUX") == "" {
		fmt.Fprintln(os.Stderr, "kido: must run inside tmux")
		os.Exit(1)
	}
	// The fork sets TMUX_SIDE_CLIENT only in the environment of the
	// side-status-command job (status.c, status_side_start), so its absence
	// is exactly "not started as a side column". See ui.Options.Standalone.
	side := os.Getenv("TMUX_SIDE_CLIENT")
	opts.Standalone = side == ""
	if opts.Client == "" {
		opts.Client = side
	}
	if opts.Client == "" {
		opts.Client = tmux.ResolveClient(os.Getenv("TMUX_PANE"), os.Getenv("TMUX"))
	}
	if opts.Client == "" {
		// Standalone with nothing safely inferrable: the client must be
		// named. Asking tmux #{client_name} from inside won't do it - a
		// popup is not a client, so tmux answers with whichever client it
		// saw last, measured (two clients attached) as the *other* client
		// than the one the popup was opened on. tmux.ResolveClient asks a
		// different, answerable question instead: who is attached to this
		// pane's session, ignoring kido's own control connections. This
		// message is only reached when even that is ambiguous - nobody
		// attached, or more than one real client - which is the genuinely
		// ambiguous case the original hazard was about: guessing would risk
		// silently jumping somebody else's screen. So the binding passes
		// the name explicitly (see README) and kido says so rather than
		// guessing.
		fmt.Fprintln(os.Stderr, "kido: no tmux client; pass -client '#{client_name}'")
		os.Exit(1)
	}
	if err := ui.Run(opts); err != nil {
		fmt.Fprintln(os.Stderr, "kido:", err)
		os.Exit(1)
	}
}

// switchCmd implements `kido switch-session`/`kido switch-window`
// next|prev [-client NAME]: it parses the argument shape the two share
// and calls fn (tmux.SwitchSession or tmux.SwitchWindow) with the
// resolved client and direction. client falls back to $TMUX_SIDE_CLIENT,
// then the current client, when -client is not given.
func switchCmd(cmd string, args []string, fn func(client string, next bool) error) error {
	var client, dir string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if name, value, ok := strings.Cut(arg, "="); ok && (name == "-client" || name == "--client") {
			client = value
			continue
		}
		switch arg {
		case "-client", "--client":
			i++
			if i >= len(args) {
				return fmt.Errorf("%s needs a value", arg)
			}
			client = args[i]
		case "next", "prev":
			if dir != "" {
				return fmt.Errorf("only one of next/prev allowed")
			}
			dir = arg
		default:
			return fmt.Errorf("unknown argument %q", arg)
		}
	}
	if dir == "" {
		return fmt.Errorf("usage: kido %s next|prev [-client NAME]", cmd)
	}
	if client == "" {
		client = os.Getenv("TMUX_SIDE_CLIENT")
	}
	if client == "" {
		client = tmux.CurrentClient()
	}
	return fn(client, dir == "next")
}

// runHook is the Claude Code hook: it reads the event from stdin and
// records the session's status for the sidebar. The session's last record
// is read first, for the one thing an event alone cannot say: whether the
// session is already parked at running waiting on background work
// (state.Session.Background). With debug, every event
// (mapped or not) is appended to debug.log before anything else runs.
func runHook(r io.Reader, debug bool) error {
	raw, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	var in hook.Input
	if err := json.Unmarshal(raw, &in); err != nil {
		return err
	}
	var parked bool
	if in.SessionID != "" {
		prev, _, _ := state.Get(in.SessionID)
		parked = prev.Background
	}
	e := hook.Apply(in, parked)
	if debug {
		logHookEvent(raw, in, e)
	}
	switch e := e.(type) {
	case hook.Ignore:
		return nil
	case hook.Remove:
		return state.Remove(in.SessionID, procs.ReporterPID())
	case hook.Report:
		return record(in.SessionID, state.Session{
			Agent:       state.AgentClaude,
			Pane:        os.Getenv("TMUX_PANE"),
			PID:         procs.ReporterPID(),
			Status:      e.Status,
			TS:          time.Now().UTC(),
			Background:  e.Background,
			ToolPending: e.ToolPending,
		}, e.Ended)
	}
	return nil
}

// record writes a whole fresh session for one status report, applying the
// Ended rule: an idle report's end time describes when the turn ended, not
// when kido noticed it. If an earlier report already recorded this session
// as idle with an end time, it is a more authoritative observation of the
// same turn ending than this one; keep it rather than stamping s.TS and
// making an old end look freshly done.
func record(id string, s state.Session, ended bool) error {
	if ended {
		s.Ended = s.TS
		if prev, ok, _ := state.Get(id); ok && prev.Status == state.Idle && !prev.Ended.IsZero() {
			s.Ended = prev.Ended
		}
	}
	return state.Record(id, s)
}

// statusList joins state.Statuses() with "|", the form usage text shows,
// so help text cannot drift from what state.Valid accepts.
func statusList() string {
	names := make([]string, len(state.Statuses()))
	for i, s := range state.Statuses() {
		names[i] = string(s)
	}
	return strings.Join(names, "|")
}

// agentStatusUsage is what `kido agent-status` accepts.
func agentStatusUsage() string {
	return "usage: kido agent-status --agent NAME --session ID " +
		"--status " + statusList() + " [--title TITLE] [--inbox PATH] " +
		"[--activity TEXT] [--parent-pid PID] [--parent-session ID] " +
		"[--depth N] [--model NAME] [--ended] [--remove]"
}

// agentStatus implements `kido agent-status`, how an agent that is not
// Claude Code reports itself: the same record `kido hook` writes, from
// plain arguments. It runs from inside the agent's own pane ($TMUX_PANE)
// and records the calling agent's pid so the record goes stale when the
// agent dies. Every report is a whole fresh state.Session: nothing is
// carried forward from the previous record, so a caller that wants a
// field to persist sends it again on every call (docs/design.md,
// "Every report is whole").
func agentStatus(args []string) error {
	fs := flag.NewFlagSet("agent-status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	agent := fs.String("agent", "", "name of the reporting agent, e.g. pi")
	session := fs.String("session", "", "the agent's session id; one state file per session")
	status := fs.String("status", "", statusList())
	title := fs.String("title", "", "the session's name, shown as the pane's label")
	inbox := fs.String("inbox", "",
		"path of the unix socket the agent takes prompts on, speaking kido's own protocol (see `kido inbox-path`); empty means none")
	activity := fs.String("activity", "", "free text describing what the agent is doing, one line of at most 256 bytes")
	parentPID := fs.Int("parent-pid", 0, "pid of the agent that spawned this one, 0 for a root agent")
	parentSession := fs.String("parent-session", "", "session id of the agent that spawned this one, empty for a root agent")
	depth := fs.Int("depth", 0, "depth in the spawn tree, 0 for a root agent")
	model := fs.String("model", "", "name of the model the agent is currently running")
	ended := fs.Bool("ended", false, "a turn just finished")
	remove := fs.Bool("remove", false, "delete the session's record")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, agentStatusUsage())
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unknown argument %q\n%s", fs.Arg(0), agentStatusUsage())
	}
	if *agent == "" || *session == "" {
		return fmt.Errorf("--agent and --session are required\n%s", agentStatusUsage())
	}
	if *remove {
		return state.Remove(*session, os.Getppid())
	}
	if !state.Valid(state.Status(*status)) {
		return fmt.Errorf("unknown status %q\n%s", *status, agentStatusUsage())
	}
	return record(*session, state.Session{
		Agent:    state.Agent(*agent),
		Pane:     os.Getenv("TMUX_PANE"),
		PID:      os.Getppid(),
		Status:   state.Status(*status),
		TS:       time.Now().UTC(),
		Title:    *title,
		Inbox:    *inbox,
		Activity: oneLine(*activity, maxActivity),
		Parent:   state.NewParent(*parentSession, *parentPID),
		Depth:    *depth,
		Model:    *model,
	}, *ended)
}

// maxActivity caps the activity both `kido agent-status --activity` and
// `kido set_status` record. Any same-uid process can run either command,
// so this is the cap that matters regardless of what a caller enforces
// on its own side.
const maxActivity = 256

// oneLine makes model-authored free text safe to put in a state record:
// control characters become spaces and the result is cut to max bytes on
// a rune boundary. The sidebar budgets one terminal line per row and
// `kido list_agents` prints a tab-separated table, and neither defends itself.
func oneLine(s string, max int) string {
	s = strings.Map(func(r rune) rune {
		if r == utf8.RuneError || unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
	for len(s) > max {
		_, n := utf8.DecodeLastRuneInString(s)
		s = s[:len(s)-n]
	}
	return strings.TrimRight(s, " ")
}

// logHookEvent appends one line to <state.Dir()>/debug.log: a timestamp,
// TMUX_PANE, the raw hook payload compacted to one line, and the effect
// hook.Apply returned. A failure to log is ignored; it must never break
// the hook.
func logHookEvent(raw []byte, in hook.Input, e hook.Effect) {
	path := filepath.Join(state.Dir(), "debug.log")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if os.IsNotExist(err) {
		if err = os.MkdirAll(state.Dir(), 0o755); err != nil {
			return
		}
		f, err = os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	}
	if err != nil {
		return
	}
	defer f.Close()
	var compact bytes.Buffer
	if json.Compact(&compact, raw) != nil {
		compact.Reset()
		compact.Write(bytes.ReplaceAll(raw, []byte("\n"), []byte(" ")))
	}
	line := fmt.Sprintf("%s\t%s\t%s\t%s\n",
		time.Now().Format(time.RFC3339Nano), os.Getenv("TMUX_PANE"), compact.String(), hook.Describe(in.Event, e))
	f.WriteString(line) //nolint:errcheck // logging must never fail the hook
}
