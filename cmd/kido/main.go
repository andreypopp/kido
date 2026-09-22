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

	"kido/internal/hook"
	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
	"kido/internal/ui"
)

// debugFlag parses a command's args for its one boolean --debug flag,
// erroring on anything else (an unknown flag, a positional argument), the
// same shape as prompt's flag.NewFlagSet.
func debugFlag(cmd string, args []string) (bool, error) {
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	debug := fs.Bool("debug", false, "")
	if err := fs.Parse(args); err != nil {
		return false, err
	}
	if fs.NArg() > 0 {
		return false, fmt.Errorf("unknown argument %q", fs.Arg(0))
	}
	return *debug, nil
}

// dispatch runs fn for a subcommand named name, printing "kido <name>:
// <err>" to stderr and exiting 1 on failure. It is the shape shared by
// every subcommand except hook, which must never fail the caller, and
// prompt, which returns its own exit codes - both stay as their own cases
// below.
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
			debug, err := debugFlag("hook", os.Args[2:])
			if err != nil {
				fmt.Fprintln(os.Stderr, "kido hook:", err)
				return // never fail the Claude Code hook
			}
			if err := runHook(os.Stdin, debug); err != nil {
				fmt.Fprintln(os.Stderr, "kido hook:", err)
			}
			return // never fail the Claude Code hook
		case "setup-pi":
			if len(os.Args) > 2 {
				fmt.Fprintln(os.Stderr, "usage: kido setup-pi")
				os.Exit(1)
			}
			dispatch("setup-pi", setupPi)
			return
		case "setup-zsh":
			if len(os.Args) > 2 {
				fmt.Fprintln(os.Stderr, "usage: kido setup-zsh")
				os.Exit(1)
			}
			dispatch("setup-zsh", setupZsh)
			return
		case "setup-tmux":
			if len(os.Args) > 2 {
				fmt.Fprintln(os.Stderr, "usage: kido setup-tmux")
				os.Exit(1)
			}
			dispatch("setup-tmux", setupTmux)
			return
		case "setup-claude":
			debug, err := debugFlag("setup-claude", os.Args[2:])
			if err != nil {
				fmt.Fprintln(os.Stderr, "kido setup-claude:", err)
				os.Exit(1)
			}
			dispatch("setup-claude", func() error { return setupClaude(debug) })
			return
		case "agent-status":
			dispatch("agent-status", func() error { return agentStatus(os.Args[2:]) })
			return
		case "agents":
			dispatch("agents", func() error { return agentsCmd(os.Args[2:]) })
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
		case "message":
			os.Exit(message(os.Args[2:], os.Stdin))
		case "interrupt":
			dispatch("interrupt", func() error { return interruptCmd(os.Args[2:]) })
			return
		case "stop":
			dispatch("stop", func() error { return stopCmd(os.Args[2:]) })
			return
		case "spawn":
			dispatch("spawn", func() error { return spawnCmd(os.Args[2:]) })
			return
		case "close-window":
			dispatch("close-window", func() error { return closeWindowCmd(os.Args[2:]) })
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
		}
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
	// side-status-command job (status.c, status_side_start). Its absence is
	// therefore exactly "kido was not started as a side column": a popup, or
	// a plain pane. See ui.Options.Standalone.
	side := os.Getenv("TMUX_SIDE_CLIENT")
	opts.Standalone = side == ""
	if opts.Client == "" {
		opts.Client = side
	}
	if opts.Client == "" {
		// Standalone, the client must be named: a popup is not a client, so
		// tmux answers #{client_name} inside one with whichever client it
		// saw last - measured, with two clients attached, as the *other*
		// client than the one the popup was opened on. Guessing there would
		// silently jump somebody else's screen, so the binding passes the
		// name (see README) and kido says so rather than guessing.
		fmt.Fprintln(os.Stderr, "kido: no tmux client; pass -client '#{client_name}'")
		os.Exit(1)
	}
	if err := ui.Run(opts); err != nil {
		fmt.Fprintln(os.Stderr, "kido:", err)
		os.Exit(1)
	}
}

// setupClaude registers `kido hook` (or, with debug, `kido hook --debug`
// for every Claude Code hook event) in the user's Claude Code settings
// file, replacing any earlier kido hooks and keeping everything else. The
// previous file is kept as settings.json.bak.
func setupClaude(debug bool) error {
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		dir = filepath.Join(home, ".claude")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, "settings.json")
	n, err := writeClaudeSettings(path, debug)
	if err != nil {
		return err
	}
	fmt.Printf("registered kido hook for %d events in %s\n", n, path)
	return nil
}

// writeClaudeSettings registers kido's hook command for the target event
// set (hook.Events(), or hook.AllEvents() when debug) at path, replacing
// any earlier kido hook entries (in either mode) and removing kido entries
// for events outside the target set, so switching modes back and forth is
// idempotent. It returns the number of events registered.
func writeClaudeSettings(path string, debug bool) (int, error) {
	settings := map[string]any{}
	old, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(old, &settings); err != nil {
			return 0, fmt.Errorf("%s: %w", path, err)
		}
	case !os.IsNotExist(err):
		return 0, err
	}
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}

	command := "kido hook"
	targetEvents := hook.Events()
	if debug {
		command = "kido hook --debug"
		targetEvents = hook.AllEvents()
	}
	target := map[string]bool{}
	for _, event := range targetEvents {
		target[event] = true
	}

	for _, event := range hook.AllEvents() {
		var kept []any
		if list, ok := hooks[event].([]any); ok {
			for _, entry := range list {
				if !isKidoHook(entry) {
					kept = append(kept, entry)
				}
			}
		}
		if target[event] {
			h := map[string]any{"type": "command", "command": command, "timeout": 5}
			if event != "SessionEnd" {
				h["async"] = true // never delay Claude; SessionEnd must finish
			}
			kept = append(kept, map[string]any{"hooks": []any{h}})
		}
		if len(kept) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = kept
		}
	}
	settings["hooks"] = hooks

	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return 0, err
	}
	if old != nil {
		if err := os.WriteFile(path+".bak", old, 0o644); err != nil {
			return 0, err
		}
	}
	if err := os.WriteFile(path, append(out, '\n'), 0o644); err != nil {
		return 0, err
	}
	return len(targetEvents), nil
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

// isKidoHook reports whether a hooks entry runs kido (any earlier form).
func isKidoHook(entry any) bool {
	m, _ := entry.(map[string]any)
	list, _ := m["hooks"].([]any)
	for _, h := range list {
		hm, _ := h.(map[string]any)
		if cmd, _ := hm["command"].(string); strings.Contains(cmd, "kido") {
			return true
		}
	}
	return false
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

// recordSession builds and writes the state.Session for one agent report:
// the pane ($TMUX_PANE) and the pid the caller supplies (procs.ReporterPID,
// walked past a wrapping shell or not depending on which path can be
// behind one), e's status, e's end time (via endedAt) when e.Ended, e's
// background wait, and r's fields. Shared by runHook and agentStatus,
// which differ only in which agent, pid, effect and report they supply
// (Claude Code reports a zero agentReport).
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
// Claude Code reports itself to the sidebar: the same record `kido hook`
// writes for Claude Code, from plain arguments rather than a hook payload.
// It is meant to be run from inside the agent's own pane, whose id it takes
// from $TMUX_PANE, and it records the calling agent's pid so the record
// goes stale when the agent dies.
//
// --status is the agent's new status; --ended says a turn just finished
// (meaningful with idle: it is what makes the sidebar show the pane as done
// until the user visits it); --remove deletes the record, for shutdown.
// --title is the session's name, shown as the pane's label in place of the
// pane title kido would otherwise strip a marker off (see internal/ui);
// when omitted, the previously recorded title (if any) is kept rather than
// blanked, since an extension's coalescing may not re-send it every time.
//
// --inbox is the path of a unix socket the agent listens on for prompts,
// speaking kido's own line protocol and no other (see cmd/kido/inbox.go).
// `kido prompt` then delivers over it instead of typing into the pane;
// `kido inbox-path NAME` says where to put the socket. It is carried
// across calls that omit it the way
// --title is, but unlike --title an explicit empty value clears it:
// `--inbox ""` is how an agent says its socket is gone, and a stale path
// would otherwise keep kido dialling a socket nobody is listening on. That
// is why presence is read from fs.Visit rather than from the value.
//
// --protocol is the highest inbox envelope version (internal/msg) the
// agent understands, carried forward the same way as --inbox and for the
// same reason: a sender that sees no advertised version must fall back to
// v0 raw text rather than deliver a v1 envelope an unupgraded receiver
// would show the user verbatim. Presence, not value, decides carry-forward,
// so `--protocol 0` explicitly clears it exactly as `--inbox ""` clears
// the socket path.
//
// --activity is free text describing what the agent is doing ("refactoring
// internal/ui"), shown in the sidebar after the status. It follows the same
// carry-forward rule as --inbox - presence, not value, decides it - because
// an extension's coalescing may report a fresh status without re-sending
// the activity that still applies; `--activity ""` is how it is cleared.
// It is the one field a model writes directly, so it is sanitised on the
// way in rather than trusted at either place it is drawn: see oneLine.
//
// --instance is an opaque id the agent generates once per process and
// reports on every call - it identifies the process, not the session, so
// it does not change across /resume or /reload the way a session id can.
//
// --parent-pid, --parent-instance and --depth describe a subagent's place
// in the spawn tree: the pid and instance id of the agent that spawned
// this one (zero/empty for a root agent), and its depth in that tree.
// Unlike --title, --inbox and --protocol these need no carry-forward -
// the agent reads them from its own environment (KIDO_AGENT_PARENT_PID,
// KIDO_AGENT_PARENT_INSTANCE, KIDO_AGENT_DEPTH) and can report them fresh
// on every call - so they are recorded exactly as given, defaulting to
// zero. A parent edge is matched on ParentInstance, not ParentPID: see
// cmd/kido/agents.go's parentID.
//
// --model is the name of the model the agent is currently running,
// shown in the sidebar. It follows the same carry-forward rule as
// --activity - presence, not value, decides it - since an extension's
// coalescing may report a fresh status without re-sending a model that
// has not changed.
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
	if r.Title == "" || !given["inbox"] || !given["protocol"] || !given["activity"] || !given["model"] {
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
	}
	e := hook.Effect{Status: state.Status(*status), Ended: *ended}
	return recordSession(*agent, *session, procs.ReporterPID(false), e, r)
}

// maxActivity caps what --activity records. The extension caps it too,
// but a model is free to ignore the schema and any same-uid process can
// run `kido agent-status`, so the cap that matters is the one here.
const maxActivity = 256

// oneLine is what makes model-authored free text safe to put in a state
// record: control characters become spaces and the result is cut to max
// bytes on a rune boundary.
//
// The sidebar draws one row per pane and View() budgets one terminal line
// per row, so a newline in the activity draws a line the row accounting
// does not know about and pushes everything below it down; an escape
// sequence would colour the rest of the column. `kido agents` prints a
// tab-separated table, which a tab or a newline breaks the same way. All
// of that is cheaper to prevent at the one place a Session is built from
// arguments than to defend at each of the two places one is drawn.
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
