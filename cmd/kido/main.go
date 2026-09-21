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
		case "debug-log":
			fmt.Println(filepath.Join(state.Dir(), "debug.log"))
			return
		case "inbox-path":
			// Like debug-log: kido owns where its state lives, so an
			// agent's extension asks rather than reimplementing Dir().
			if len(os.Args) != 3 {
				fmt.Fprintln(os.Stderr, "usage: kido inbox-path NAME")
				os.Exit(1)
			}
			path, err := inboxPath(os.Args[2])
			if err != nil {
				// Nothing on stdout: the caller can then simply go
				// without an inbox instead of listening where kido
				// cannot dial.
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
	// a plain pane. There kido is a one-shot picker that can be quit, since
	// handing the keyboard back to a side column nobody is showing would
	// trap the user in a program with no exit.
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

	// One pass over every known event: strip any kido entry (left by a
	// previous run, in either mode), then append the new one when the
	// event is in the target set. An event left with nothing is dropped
	// rather than kept as an empty list.
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
// either order. The client flag may come before or after the direction,
// since a key binding's run-shell command is easiest to write with the flag
// last (bind -n S-Down run-shell "kido switch-session next -client
// '#{client_name}'"). client falls back to $TMUX_SIDE_CLIENT, then the
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
// order (internal/tmux.OrderSessions), wrapping around the whole server and
// crossing session boundaries, unlike tmux's own next-window/previous-window
// which wrap inside one session.
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
// records the session's status for the sidebar. With debug, every event
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
	// Claude Code runs the hook through `sh -c`, so the immediate parent
	// is that shell, not claude; ReporterPID(true) walks past it.
	return recordSession(state.AgentClaude, in.SessionID, procs.ReporterPID(true), e, "", "")
}

// recordSession builds and writes the state.Session for one agent report:
// the pane ($TMUX_PANE) and the pid the caller supplies (procs.ReporterPID,
// walked past a wrapping shell or not depending on which path can be
// behind one), e's status, e's end time (via endedAt) when e.Ended, and
// title and inbox. Shared by runHook and agentStatus, which differ only in
// which agent, pid, effect, title and inbox they report (Claude Code has
// neither a title nor an inbox).
func recordSession(agent, sessionID string, pid int, e hook.Effect, title, inbox string) error {
	now := time.Now().UTC()
	s := state.Session{
		Agent:  agent,
		Pane:   os.Getenv("TMUX_PANE"),
		PID:    pid,
		Status: e.Status,
		TS:     now,
		Title:  title,
		Inbox:  inbox,
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
		"--status " + statusList() + " [--title TITLE] [--inbox PATH] [--ended] [--remove]"
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
// speaking kido's own line protocol and no other (write the prompt,
// half-close, answer "ok\n"; see cmd/kido/inbox.go). It is not a general
// "send a message here" address, so an agent with a socket of its own
// that frames messages differently must not report it here. `kido prompt`
// then delivers over it instead of typing into the pane. `kido inbox-path
// NAME` says where to put the socket. It is carried across calls that omit it the way
// --title is, but unlike --title an explicit empty value clears it:
// `--inbox ""` is how an agent says its socket is gone, and a stale path
// would otherwise keep kido dialling a socket nobody is listening on. That
// is why presence is read from fs.Visit rather than from the value.
func agentStatus(args []string) error {
	fs := flag.NewFlagSet("agent-status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	agent := fs.String("agent", "", "name of the reporting agent, e.g. pi")
	session := fs.String("session", "", "the agent's session id; one state file per session")
	status := fs.String("status", "", statusList())
	title := fs.String("title", "", "the session's name, shown as the pane's label")
	inbox := fs.String("inbox", "",
		"path of the unix socket the agent takes prompts on, speaking kido's own protocol (see `kido inbox-path`); empty clears it")
	ended := fs.Bool("ended", false, "a turn just finished")
	remove := fs.Bool("remove", false, "delete the session's record")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, agentStatusUsage())
	}
	gaveInbox := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "inbox" {
			gaveInbox = true
		}
	})
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
	sessionTitle, sessionInbox := *title, *inbox
	if sessionTitle == "" || !gaveInbox {
		if prev, ok, _ := state.Get(*session); ok {
			if sessionTitle == "" {
				sessionTitle = prev.Title
			}
			if !gaveInbox {
				sessionInbox = prev.Inbox
			}
		}
	}
	e := hook.Effect{Status: state.Status(*status), Ended: *ended}
	// Spawned directly by the agent's extension, with no shell wrapper to
	// walk past: ReporterPID(false) is the immediate parent, no ps call.
	return recordSession(*agent, *session, procs.ReporterPID(false), e, sessionTitle, sessionInbox)
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
