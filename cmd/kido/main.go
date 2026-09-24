// Command kido renders a tmux sidebar listing sessions and panes, with
// agent sessions badged by activity status. It runs inside the side status
// line of the andreypopp/tmux fork (side-status-command).
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/sahilm/fuzzy"

	"kido/internal/hook"
	"kido/internal/procs"
	"kido/internal/reap"
	"kido/internal/state"
	"kido/internal/tmux"
	"kido/internal/ui"
)

// subcommands lists every kido subcommand the switch in main recognises,
// kept in one place so unknownSubcommand can name them; a subcommand
// added to the switch and forgotten here just gets a plainer error.
var subcommands = []string{
	"hook", "agent-status", "set_status", "list_agents", "agent-alive", "children-alive", "debug-log",
	"inbox-path", "snapshot", "switch-session", "switch-window", "prompt",
	"message_agent", "ask_agent", "notify_parent", "steer_subagent",
	"interrupt_subagent", "stop_subagent", "spawn_subagent", "async_bash",
	"async-run", "close-run",
	"window-focused", "reap", "run-outcome", "runs", "ssh", "shell",
}

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
		switch os.Args[1] {
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
			dispatch("agent-status", func() error { return agentStatus(os.Args[2:]) })
			return
		case "set_status":
			dispatch("set_status", func() error { return setStatusCmd(os.Args[2:]) })
			return
		case "list_agents":
			dispatch("list_agents", func() error { return listAgentsCmd(os.Args[2:]) })
			return
		case "agent-alive":
			dispatch("agent-alive", func() error { return agentAliveCmd(os.Args[2:]) })
			return
		case "children-alive":
			dispatch("children-alive", func() error { return childrenAliveCmd(os.Args[2:]) })
			return
		case "debug-log":
			fmt.Println(filepath.Join(state.Dir(), "debug.log"))
			return
		case "inbox-path":
			if len(os.Args) != 3 {
				fmt.Fprintln(os.Stderr, "usage: kido inbox-path NAME")
				os.Exit(1)
			}
			path, err := inboxPath(os.Args[2])
			if err != nil {
				fmt.Fprintln(os.Stderr, "kido inbox-path:", err)
				os.Exit(1)
			}
			fmt.Println(path)
			return
		case "snapshot":
			dispatch("snapshot", func() error { return snapshot(os.Stdout) })
			return
		case "switch-session":
			dispatch("switch-session", func() error { return switchSession(os.Args[2:]) })
			return
		case "switch-window":
			dispatch("switch-window", func() error { return switchWindow(os.Args[2:]) })
			return
		case "prompt":
			os.Exit(prompt(os.Args[2:], os.Stdin))
		case "message_agent":
			os.Exit(messageAgentCmd(os.Args[2:], os.Stdin))
		case "ask_agent":
			os.Exit(askAgentCmd(os.Args[2:], os.Stdin))
		case "notify_parent":
			os.Exit(notifyParentCmd(os.Args[2:], os.Stdin))
		case "steer_subagent":
			os.Exit(steerSubagentCmd(os.Args[2:], os.Stdin))
		case "interrupt_subagent":
			dispatch("interrupt_subagent", func() error { return interruptSubagentCmd(os.Args[2:]) })
			return
		case "stop_subagent":
			dispatch("stop_subagent", func() error { return stopSubagentCmd(os.Args[2:]) })
			return
		case "spawn_subagent":
			dispatch("spawn_subagent", func() error { return spawnSubagentCmd(os.Args[2:]) })
			return
		case "async_bash":
			dispatch("async_bash", func() error { return asyncBashCmd(os.Args[2:]) })
			return
		case "async-run":
			os.Exit(asyncRunCmd(os.Args[2:]))
		case "close-run":
			dispatch("close-run", func() error { return closeRunCmd(os.Args[2:]) })
			return
		case "window-focused":
			dispatch("window-focused", func() error { return windowFocusedCmd(os.Args[2:]) })
			return
		case "reap":
			dispatch("reap", func() error { return reapCmd(os.Args[2:]) })
			return
		case "run-outcome":
			dispatch("run-outcome", func() error { return runOutcomeCmd(os.Args[2:]) })
			return
		case "runs":
			dispatch("runs", func() error { return runsCmd(os.Args[2:]) })
			return
		case "ssh":
			dispatch("ssh", func() error { return sshCmd(os.Args[2:]) })
			return
		case "shell":
			dispatch("shell", func() error { return shellCmd(os.Args[2:]) })
			return
		default:
			// A leading flag (bare `kido -client NAME`, or any other flag)
			// falls through to the interactive UI below, same as always.
			// Anything else is a typo or an old name - every subagent tool
			// now names the subcommand it invokes, so what reaches here is
			// most often a command's former spelling - and the old
			// fallthrough reported a misleading tmux-client error instead
			// of naming the mismatch, so say so instead of guessing at a
			// client.
			if !strings.HasPrefix(os.Args[1], "-") {
				unknownSubcommand(os.Args[1])
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
	// The sidebar's sweep is one of the observers that can discover a bash
	// run's ending, and the only one that is not a kido subcommand; this is
	// where it is given the sending half it cannot import.
	ui.NotifyRunEnded = func(n reap.Notice) { noticeFor(n).send("sidebar") }
	if err := ui.Run(opts); err != nil {
		fmt.Fprintln(os.Stderr, "kido:", err)
		os.Exit(1)
	}
}

// parseSwitchArgs parses the argument shape shared by switch-session and
// switch-window: next|prev plus an optional -client/--client flag, in
// either order. client falls back to $TMUX_SIDE_CLIENT, then the
// current client, when -client is not given.
func parseSwitchArgs(cmd string, args []string) (client, dir string, err error) {
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
				return "", "", fmt.Errorf("%s needs a value", arg)
			}
			client = args[i]
		case "next", "prev":
			if dir != "" {
				return "", "", fmt.Errorf("only one of next/prev allowed")
			}
			dir = arg
		default:
			return "", "", fmt.Errorf("unknown argument %q", arg)
		}
	}
	if dir == "" {
		return "", "", fmt.Errorf("usage: kido %s next|prev [-client NAME]", cmd)
	}
	if client == "" {
		client = os.Getenv("TMUX_SIDE_CLIENT")
	}
	if client == "" {
		client = tmux.CurrentClient()
	}
	return client, dir, nil
}

// switchSession implements `kido switch-session next|prev [-client NAME]`:
// it switches the current client to the adjacent session in kido's order
// (internal/tmux.OrderSessions), wrapping around.
func switchSession(args []string) error {
	client, dir, err := parseSwitchArgs("switch-session", args)
	if err != nil {
		return err
	}
	return tmux.SwitchSession(client, dir == "next")
}

// switchWindow implements `kido switch-window next|prev [-client NAME]`: it
// switches the current client to the adjacent window in the sidebar's
// order (internal/tmux.OrderSessions), wrapping around the whole server.
func switchWindow(args []string) error {
	client, dir, err := parseSwitchArgs("switch-window", args)
	if err != nil {
		return err
	}
	return tmux.SwitchWindow(client, dir == "next")
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
	if in.SessionID != "" {
		prev, _, _ := state.Get(in.SessionID)
		in.Background = prev.Background
	}
	e := hook.Apply(in)
	if debug {
		logHookEvent(raw, in, e)
	}
	switch {
	case e.Ignore:
		return nil
	case e.Remove:
		return state.Remove(in.SessionID)
	}
	return recordSession(state.AgentClaude, in.SessionID, procs.ReporterPID(true), e, agentReport{})
}

// agentReport is what an agent may say about itself beyond its status:
// the fields only `kido agent-status` can set. runHook passes the zero
// value, Claude Code's hooks reporting none of them.
type agentReport struct {
	Title          string
	Inbox          string
	Protocol       int
	Activity       string
	Instance       string
	ParentPID      int
	ParentInstance string
	Depth          int
	Model          string
}

// recordSession builds and writes a whole fresh state.Session for one
// agent report; anything not in e or r is blank unless the caller carried
// it forward.
func recordSession(agent, sessionID string, pid int, e hook.Effect, r agentReport) error {
	now := time.Now().UTC()
	s := state.Session{
		Agent:          agent,
		Pane:           os.Getenv("TMUX_PANE"),
		PID:            pid,
		Status:         e.Status,
		TS:             now,
		Title:          r.Title,
		Inbox:          r.Inbox,
		Protocol:       r.Protocol,
		Background:     e.Background,
		ToolPending:    e.ToolPending,
		Activity:       r.Activity,
		Instance:       r.Instance,
		ParentPID:      r.ParentPID,
		ParentInstance: r.ParentInstance,
		Depth:          r.Depth,
		Model:          r.Model,
	}
	if e.Ended {
		s.Ended = endedAt(sessionID, now)
	}
	return state.Record(sessionID, s)
}

// endedAt is the time to record as the end of session id's turn, now being
// when kido noticed it. An end time describes when the turn ended, not when
// kido noticed. If an earlier report already recorded this session as idle
// with an Ended time, it is a more authoritative observation of the same
// turn ending than this one; keep it rather than stamping now and making an
// old end look freshly done.
func endedAt(id string, now time.Time) time.Time {
	if prev, ok, _ := state.Get(id); ok && prev.Status == state.Idle && !prev.Ended.IsZero() {
		return prev.Ended
	}
	return now
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
		"--status " + statusList() + " [--title TITLE] [--inbox PATH] [--protocol N] " +
		"[--activity TEXT] [--instance ID] [--parent-pid PID] [--parent-instance ID] " +
		"[--depth N] [--model NAME] [--ended] [--remove]"
}

// agentStatus implements `kido agent-status`, how an agent that is not
// Claude Code reports itself: the same record `kido hook` writes, from
// plain arguments. It runs from inside the agent's own pane ($TMUX_PANE)
// and records the calling agent's pid so the record goes stale when the
// agent dies.
//
// Which fields are carried forward from the previous record when omitted
// is decided per field, by the flag's presence (fs.Visit) rather than its
// value, so an explicit empty value clears: docs/design.md, "Reporting,
// and what is carried forward". --title is the exception: an empty title
// keeps the old one.
func agentStatus(args []string) error {
	fs := flag.NewFlagSet("agent-status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	agent := fs.String("agent", "", "name of the reporting agent, e.g. pi")
	session := fs.String("session", "", "the agent's session id; one state file per session")
	status := fs.String("status", "", statusList())
	title := fs.String("title", "", "the session's name, shown as the pane's label")
	inbox := fs.String("inbox", "",
		"path of the unix socket the agent takes prompts on, speaking kido's own protocol (see `kido inbox-path`); empty clears it")
	protocol := fs.Int("protocol", 0,
		"highest inbox envelope version the agent understands (see internal/msg); omitted keeps the last reported value")
	activity := fs.String("activity", "", "free text describing what the agent is doing, one line of at most 256 bytes; omitted keeps the last reported value, empty clears it")
	instance := fs.String("instance", "", "opaque id the agent generates once per process and reports on every call")
	parentPID := fs.Int("parent-pid", 0, "pid of the agent that spawned this one, 0 for a root agent")
	parentInstance := fs.String("parent-instance", "", "instance id of the agent that spawned this one, empty for a root agent")
	depth := fs.Int("depth", 0, "depth in the spawn tree, 0 for a root agent")
	model := fs.String("model", "", "name of the model the agent is currently running; omitted keeps the last reported value, empty clears it")
	ended := fs.Bool("ended", false, "a turn just finished")
	remove := fs.Bool("remove", false, "delete the session's record")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, agentStatusUsage())
	}
	given := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { given[f.Name] = true })
	if fs.NArg() > 0 {
		return fmt.Errorf("unknown argument %q\n%s", fs.Arg(0), agentStatusUsage())
	}
	if *agent == "" || *session == "" {
		return fmt.Errorf("--agent and --session are required\n%s", agentStatusUsage())
	}
	if *remove {
		return state.Remove(*session)
	}
	if !state.Valid(state.Status(*status)) {
		return fmt.Errorf("unknown status %q\n%s", *status, agentStatusUsage())
	}
	r := agentReport{
		Title:          *title,
		Inbox:          *inbox,
		Protocol:       *protocol,
		Activity:       oneLine(*activity, maxActivity),
		Instance:       *instance,
		ParentPID:      *parentPID,
		ParentInstance: *parentInstance,
		Depth:          *depth,
		Model:          *model,
	}
	// The previous record is read unconditionally: the extension reports
	// --inbox/--protocol once and carries nothing else forward itself, so
	// a report with nothing to carry over essentially never arrives and a
	// guard restating each condition below would only duplicate them.
	if prev, ok, _ := state.Get(*session); ok {
		if r.Title == "" {
			r.Title = prev.Title
		}
		if !given["inbox"] {
			r.Inbox = prev.Inbox
		}
		if !given["protocol"] {
			r.Protocol = prev.Protocol
		}
		if !given["activity"] {
			r.Activity = prev.Activity
		}
		if !given["model"] {
			r.Model = prev.Model
		}
	}
	e := hook.Effect{Status: state.Status(*status), Ended: *ended}
	return recordSession(*agent, *session, procs.ReporterPID(false), e, r)
}

// maxActivity caps the activity both `kido agent-status --activity` and
// `kido set_status` record. The extension caps it too, but a model is
// free to ignore the schema and any same-uid process can run either
// command, so the cap that matters is this one.
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
