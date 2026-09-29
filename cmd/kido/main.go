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

var exitCommands = map[string]func([]string, io.Reader) int{
	"prompt":         prompt,
	"message_agent":  messageAgentCmd,
	"ask_agent":      askAgentCmd,
	"notify_parent":  notifyParentCmd,
	"steer_subagent": steerSubagentCmd,
}

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

func unknownSubcommand(name string) {
	fmt.Fprintf(os.Stderr, "kido: unknown subcommand %q\n", name)
	if suggestion := suggestSubcommand(name); suggestion != "" {
		fmt.Fprintf(os.Stderr, "did you mean %q?\n", suggestion)
	}
	fmt.Fprintln(os.Stderr, "subcommands:", strings.Join(subcommands, ", "))
	os.Exit(1)
}

// Claude Code runs the hook, so nothing kido is told can carry a flag;
// this is read from the environment of the pane Claude Code was started in.
const hookDebugEnv = "KIDO_HOOK_DEBUG"

// pi/kido-status.ts reads this exit code to stop reporting for a session
// another live process already holds.
const exitSessionHeld = 6

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
			if !strings.HasPrefix(name, "-") {
				unknownSubcommand(name)
				return
			}
		}
	}

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
		// #{client_name} from inside a popup answers with whichever client tmux
		// saw last, not the popup's own client, so it cannot be asked directly.
		fmt.Fprintln(os.Stderr, "kido: no tmux client; pass -client '#{client_name}'")
		os.Exit(1)
	}
	if err := ui.Run(opts); err != nil {
		fmt.Fprintln(os.Stderr, "kido:", err)
		os.Exit(1)
	}
}

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

func record(id string, s state.Session, ended bool) error {
	if ended {
		s.Ended = s.TS
		if prev, ok, _ := state.Get(id); ok && prev.Status == state.Idle && !prev.Ended.IsZero() {
			s.Ended = prev.Ended
		}
	}
	return state.Record(id, s)
}

func statusList() string {
	names := make([]string, len(state.Statuses()))
	for i, s := range state.Statuses() {
		names[i] = string(s)
	}
	return strings.Join(names, "|")
}

func agentStatusUsage() string {
	return "usage: kido agent-status --agent NAME --session ID " +
		"--status " + statusList() + " [--title TITLE] [--inbox PATH] " +
		"[--activity TEXT] [--parent-pid PID] [--parent-session ID] " +
		"[--depth N] [--model NAME] [--ended] [--remove]"
}

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

const maxActivity = 256

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
