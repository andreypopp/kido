// Package tmux talks to the tmux server that owns this process.
package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	binaryOnce sync.Once
	binaryPath = "tmux"
)

// binary returns the tmux executable to run, in order: $KIDO_TMUX when
// set; else "kido-tmux" beside the kido binary itself, the way an install
// ships it; else whatever "tmux" resolves to on PATH, for a developer
// running from a checkout with neither.
func binary() string {
	binaryOnce.Do(func() {
		binaryPath = resolveBinary(os.Getenv("KIDO_TMUX"), os.Args[0])
	})
	return binaryPath
}

// Binary is the tmux executable kido runs, for a caller that has to run
// it itself rather than through this package - the launcher, which starts
// a server rather than talking to one.
func Binary() string { return binary() }

// GlobalOption reads a global tmux option, empty when it is unset or when
// there is no server to ask (-q, so an unknown user option is empty
// rather than an error).
func GlobalOption(name string) string {
	out, err := run("show-options", "-gqv", name)
	if err != nil {
		return ""
	}
	return out
}

// resolveBinary is binary()'s logic taking its inputs as arguments, so the
// order can be tested without a real KIDO_TMUX or a real kido binary on
// disk.
func resolveBinary(kidoTmuxEnv, arg0 string) string {
	if kidoTmuxEnv != "" {
		return kidoTmuxEnv
	}
	exe, err := invokedPath(arg0)
	if err == nil {
		if sib := siblingTmux(exe); sib != "" {
			return sib
		}
	}
	return "tmux"
}

// invokedPath returns the path kido was started as, with symlinks left
// alone. Mirrors cmd/kido/setup.go's invokedPath, and for the same reason:
// os.Executable resolves through /proc/self/exe on Linux and always comes
// back fully resolved, which would defeat siblingTmux's unresolved-first
// ordering below on exactly the platform where nobody tests it.
func invokedPath(arg0 string) (string, error) {
	var p string
	switch {
	case strings.ContainsRune(arg0, filepath.Separator):
		p = arg0
	case arg0 != "":
		if found, err := exec.LookPath(arg0); err == nil {
			p = found
		}
	}
	if p != "" {
		if abs, err := filepath.Abs(p); err == nil {
			if fi, err := os.Stat(abs); err == nil && !fi.IsDir() {
				return abs, nil
			}
		}
	}
	return os.Executable()
}

// siblingTmux returns the absolute path of "kido-tmux" beside exe, or ""
// when there is none. The unresolved exe is tried first and its symlink
// target only as a fallback - the same ordering findShared uses in
// cmd/kido/setup.go, and for the same reason: Homebrew's bin directory is
// a symlink it repoints on every upgrade, and the unresolved spelling
// survives a `brew cleanup` that deletes the resolved one.
func siblingTmux(exe string) string {
	candidates := []string{exe}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil && resolved != exe {
		candidates = append(candidates, resolved)
	}
	for _, c := range candidates {
		sib := filepath.Join(filepath.Dir(c), "kido-tmux")
		if fi, err := os.Stat(sib); err == nil && !fi.IsDir() {
			return sib
		}
	}
	return ""
}

func run(args ...string) (string, error) {
	out, err := exec.Command(binary(), args...).Output()
	if err != nil {
		return "", fmt.Errorf("tmux %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out)), nil
}

// runStdin is run for a tmux command that reads standard input, such as
// load-buffer -.
func runStdin(stdin string, args ...string) (string, error) {
	cmd := exec.Command(binary(), args...)
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("tmux %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out)), nil
}

// Pane is one tmux pane plus the window and session it belongs to.
type Pane struct {
	SessionName    string
	SessionID      string // e.g. "$3"; stable while the session lives, unlike SessionName
	SessionCreated int64  // unix time
	WindowIndex    int
	WindowID       string // e.g. "@7"; unique server-wide, unlike WindowIndex
	WindowName     string
	WindowLayout   string
	PaneID         string // e.g. "%18"
	Active         bool   // the session's current pane
	PanePID        int
	CurrentCommand string
	CurrentPath    string
	// OSC 133 shell integration, reported by tmux only for shells that
	// emit the markers (kido ships a zsh integration in shell/zsh, which
	// every primed pane sources). A shell that
	// never emits them leaves LastPromptTime zero; see ShellStatus.
	// AlternateOn is tmux's own answer to "a program owns this terminal":
	// vim, a pager, top and friends all take the screen by switching to
	// the alternate buffer. It is the innermost program that does so, so
	// unlike pane_current_command - which names the process group leader -
	// it sees less running under git, or nvim running under sudo.
	AlternateOn      bool
	CommandRunning   bool
	CommandStartTime int64 // unix time of the last 133;C
	LastPromptTime   int64 // unix time of the last 133;A
	// The last finished command's exit status, from the last 133;D.
	// tmux prints pane_command_status empty when it has none (it keeps
	// -1 internally), so the flag is what tells "no status yet" from a
	// clean exit; CommandEndTime is the unix time of that 133;D.
	CommandStatus   int
	CommandStatusOK bool
	CommandEndTime  int64
	// CommandLine is the command line the shell reported with its 133;C,
	// empty for a shell that reports none. tmux keeps it until the next
	// 133;C, so it still names the last command while the pane is idle.
	// tmux sanitises it: control bytes are dropped and "#(" is rewritten,
	// so it can carry neither the format separator nor a format
	// substitution.
	CommandLine string
	// Dead is tmux's own #{pane_dead}: the command has exited and
	// remain-on-exit kept the pane on screen. DeadTime is when it exited,
	// in unix seconds; unlike pane_command_duration neither field ticks.
	Dead     bool
	DeadTime int64
	// Subagent is the @kido_subagent window option kido spawn_subagent sets on a
	// window of its own making, read through the pane because one
	// list-panes is the only listing kido takes. tmux's option lookup
	// falls back from pane to window scope, so this reads the same value
	// on every pane of a marked window, split panes included.
	Subagent string
	// SubagentPane is the @kido_subagent_pane *pane*-scoped option
	// (SubagentPaneOption), set only on the one pane createRunWindow made
	// the run in. Unlike Subagent it does not fall back to the window: a
	// pane the user split off later carries no pane-scoped option of its
	// own and no window-scoped fallback exists for this name, so it reads
	// "" - which is what tells lingeringLabel that pane apart from the
	// run's own. Empty on every pane of a window marked before this field
	// existed, which is the fallback lingeringLabel keeps today's
	// behaviour for.
	SubagentPane string
	// SessionAttached is whether any client is attached to this pane's
	// session; see Watched.
	SessionAttached bool
	Title           string
}

// ShellStatus reports whether pane p is running a command right now, and
// whether its shell reports that at all.
//
// ok is false when the shell has no OSC 133 integration - no prompt has
// ever been marked - and then running means nothing: the caller must draw
// the pane exactly as it did before. Every pane started before the user
// loaded the integration is in that state.
//
// The running rule is deliberately not just CommandRunning. A program that
// emits 133;C and exits without the matching 133;D (pi does this, as does
// anything else with partial integration) would leave tmux believing a
// command is still running forever. The shell's own precmd emits 133;A at
// the next prompt, which puts LastPromptTime after CommandStartTime, and
// that is what heals such a pane back to idle.
func (p Pane) ShellStatus() (running, ok bool) {
	if p.LastPromptTime == 0 {
		return false, false
	}
	return p.CommandRunning && !(p.LastPromptTime > p.CommandStartTime), true
}

const sep = "\x1f"

// pane_title is last because it may contain anything.
var paneFormat = strings.Join([]string{
	"#{session_name}",
	"#{session_id}",
	"#{session_created}",
	"#{window_index}",
	"#{window_id}",
	"#{window_name}",
	"#{window_layout}",
	"#{pane_id}",
	"#{&&:#{window_active},#{pane_active}}",
	"#{pane_pid}",
	"#{pane_current_command}",
	"#{pane_current_path}",
	// OSC 133. pane_command_duration is deliberately left out: it ticks
	// every second, which would defeat the snapshot change-detection.
	"#{alternate_on}",
	"#{pane_command_running}",
	"#{pane_command_start_time}",
	"#{pane_last_prompt_time}",
	"#{pane_command_status}",
	"#{pane_command_end_time}",
	"#{pane_command_line}",
	"#{pane_dead}",
	"#{pane_dead_time}",
	"#{session_attached}",
	"#{" + SubagentOption + "}",
	"#{" + SubagentPaneOption + "}",
	"#{pane_title}",
}, sep)

// SubagentOption is the tmux window option kido spawn_subagent sets on a window it
// creates, and the only thing that marks a window as kido's to close
// (docs/design.md, "Window options, for facts that must survive kido's
// own cleanup").
const SubagentOption = "@kido_subagent"

// SubagentPaneOption is the tmux *pane*-scoped option createRunWindow sets
// on the one pane a run actually runs in (MarkSubagentPane), naming the
// same run id SubagentOption's "run=" token carries. It exists because
// SubagentOption is a window option and tmux's format lookup falls back
// from pane to window scope, so every pane of a marked window - including
// one the user splits off later - reads a non-empty Subagent; only a
// pane-scoped option can tell the run's own pane apart from a sibling the
// user added.
const SubagentPaneOption = "@kido_subagent_pane"

// paneFields is the number of #{...} entries paneFormat asks tmux for;
// parsePanes' SplitN count and len(f) guard both use it so the two cannot
// drift apart (TestPaneFieldsMatchParsePanes).
const paneFields = 25

// parsePanes turns list-panes output lines into panes. Shared by the exec
// and control-mode paths, which ask for the same format.
func parsePanes(lines []string) []Pane {
	var panes []Pane
	for _, line := range lines {
		f := strings.SplitN(line, sep, paneFields)
		if len(f) < paneFields {
			continue
		}
		p := Pane{SessionName: f[0], SessionID: f[1], WindowID: f[4], WindowName: f[5], WindowLayout: f[6],
			PaneID: f[7], Active: f[8] == "1", CurrentCommand: f[10],
			CurrentPath: f[11], AlternateOn: f[12] == "1",
			CommandRunning: f[13] == "1", CommandLine: f[18], Dead: f[19] == "1",
			SessionAttached: f[21] != "" && f[21] != "0",
			Subagent:        f[22], SubagentPane: f[23], Title: f[24]}
		p.SessionCreated, _ = strconv.ParseInt(f[2], 10, 64)
		p.WindowIndex, _ = strconv.Atoi(f[3])
		p.PanePID, _ = strconv.Atoi(f[9])
		p.CommandStartTime, _ = strconv.ParseInt(f[14], 10, 64)
		p.LastPromptTime, _ = strconv.ParseInt(f[15], 10, 64)
		// An empty status field means tmux has no exit status for this
		// pane, which is not the same as a status of 0.
		if n, err := strconv.Atoi(f[16]); err == nil {
			p.CommandStatus, p.CommandStatusOK = n, true
		}
		p.CommandEndTime, _ = strconv.ParseInt(f[17], 10, 64)
		p.DeadTime, _ = strconv.ParseInt(f[20], 10, 64)
		panes = append(panes, p)
	}
	return panes
}

// paneNum is the numeric part of a pane id ("%12" -> 12), tmux's own
// creation-order counter. A pane id that fails to parse - which never
// happens against a real tmux server - sorts first rather than panicking
// or being dropped.
func paneNum(id string) int {
	n, _ := strconv.Atoi(strings.TrimPrefix(id, "%"))
	return n
}

// Session is one session's windows, grouped the way kido shows and walks
// them: Windows[i] is one window's panes in creation order (paneNum), so
// Windows[i][0] identifies the window (SessionName, WindowID) but is not
// necessarily its lowest #{pane_index}.
type Session struct {
	Name string
	// ID is the session id ("$3"), and it is what every command that
	// targets this session must pass. A name goes through tmux's target
	// parser, which splits on "." and ":" before it ever compares names,
	// so a session called "team.build" is looked for as pane "build" of
	// window "team" and not found. An id has neither character.
	ID      string
	Windows [][]Pane
}

// OrderSessions groups panes into sessions and windows in kido's order:
// sessions oldest first (session_created), ties broken by name, and
// within a session each window's own panes oldest first - the numeric
// part of the pane id, which tmux allocates monotonically, so a pane
// never changes place once made regardless of where a later split lands
// it in tmux's own list-panes order. #{pane_index} is a layout position,
// not an age: `split-window -b` puts the new pane first, which is
// exactly the case this sidebar has to draw a run's own pane before a
// split the user made afterwards (see internal/ui's SubagentPane, whose
// first-pane-is-the-run assumption this ordering exists to keep true).
// This is kido's one true order, derived from one list-panes: the
// sidebar's grouping, `kido switch-session` and `kido switch-window` all
// walk it, so they cannot drift apart.
func OrderSessions(panes []Pane) []Session {
	type group struct {
		created int64
		sess    Session
	}
	var order []*group
	bySess := map[string]*group{}
	for _, p := range panes {
		g, ok := bySess[p.SessionName]
		if !ok {
			g = &group{created: p.SessionCreated, sess: Session{Name: p.SessionName, ID: p.SessionID}}
			bySess[p.SessionName] = g
			order = append(order, g)
		}
		n := len(g.sess.Windows)
		if n == 0 || g.sess.Windows[n-1][0].WindowID != p.WindowID {
			g.sess.Windows = append(g.sess.Windows, nil)
			n++
		}
		g.sess.Windows[n-1] = append(g.sess.Windows[n-1], p)
	}
	for _, g := range order {
		for _, w := range g.sess.Windows {
			sort.SliceStable(w, func(i, j int) bool {
				return paneNum(w[i].PaneID) < paneNum(w[j].PaneID)
			})
		}
	}
	sort.SliceStable(order, func(i, j int) bool {
		if order[i].created != order[j].created {
			return order[i].created < order[j].created
		}
		return order[i].sess.Name < order[j].sess.Name
	})

	sessions := make([]Session, 0, len(order))
	for _, g := range order {
		sessions = append(sessions, g.sess)
	}
	return sessions
}

// ListPanes returns every pane on the server, in tmux's own order.
func ListPanes() ([]Pane, error) {
	out, err := run("list-panes", "-a", "-F", paneFormat)
	if err != nil {
		return nil, err
	}
	return parsePanes(strings.Split(out, "\n")), nil
}

// CapturePane returns the visible contents of a pane as plain text, one
// line per screen row. Wrapped lines are deliberately not joined (-J):
// what the caller reads is the shape of the last few rows.
func CapturePane(pane string) ([]string, error) {
	out, err := run("capture-pane", "-p", "-t", pane)
	if err != nil {
		return nil, err
	}
	return strings.Split(out, "\n"), nil
}

// captureScreenLines bounds how far back CaptureScreen asks tmux for, so
// a pane with a large history-limit does not turn one capture-pane call
// into megabytes before internal/reap's own byte cap even gets a chance
// to trim it.
const captureScreenLines = 1000

// CaptureScreen returns pane's visible screen plus up to captureScreenLines
// of scrollback, joined as a single block of text. It exists for
// internal/reap, which saves a subagent window's last screen before
// closing it; unlike CapturePane it does not split into lines, since the
// caller only writes the block to a file.
func CaptureScreen(pane string) (string, error) {
	return run("capture-pane", "-p", "-t", pane, "-S", "-"+strconv.Itoa(captureScreenLines))
}

// CurrentClient asks tmux which client this process belongs to. Used when
// kido is started by hand in a pane rather than by the side status line.
func CurrentClient() string {
	out, _ := run("display-message", "-p", "#{client_name}")
	return out
}

// SwitchSession switches client to the session adjacent to its current one
// in kido's order (OrderSessions: oldest first, ties by name), wrapping
// around. next selects the following session, otherwise the preceding one.
// A server with one session, or a client not attached to any session kido
// can find, is a no-op.
func SwitchSession(client string, next bool) error {
	panes, err := ListPanes()
	if err != nil {
		return err
	}
	sessions := OrderSessions(panes)
	if len(sessions) < 2 {
		return nil
	}

	current, _ := ClientState(client)
	i := -1
	for j, s := range sessions {
		if s.Name == current {
			i = j
			break
		}
	}
	if i < 0 {
		return nil
	}
	delta := -1
	if next {
		delta = 1
	}
	target := sessions[(i+delta+len(sessions))%len(sessions)]

	_, err = run("switch-client", "-c", client, "-t", target.ID)
	return err
}

// SwitchWindow switches client to the window adjacent to its current one in
// kido's order (OrderSessions: sessions oldest first, windows in tmux's own
// order within a session), wrapping around the whole server. This crosses
// session boundaries: advancing past a session's last window moves to the
// next session's first window, unlike tmux's own next-window/previous-window
// which wrap inside one session.
//
// A subagent's window (marked with SubagentOption; see reap.Sweep, which
// keys off the same mark for the same reason - a state record can lag or
// outlive the pane it names, but the mark cannot) is skipped over rather
// than visited, dead or alive: the user asked to move between top-level
// windows, and a window still readable through the sidebar's Enter should
// not also flicker in and out of ⇧↓'s reach as its pane dies and is later
// swept. The walk steps through the full list, wrapping, until it lands on
// an unmarked window; landing back on the window it started from - because
// that is the only unmarked window on the server - is the one true no-op.
// Starting from a subagent window with exactly one top-level window
// elsewhere still reaches it: only the truly degenerate case (the current
// window is that lone top-level window, or every window is a subagent's)
// stays put. A client whose current window kido cannot find is also a
// no-op.
func SwitchWindow(client string, next bool) error {
	panes, err := ListPanes()
	if err != nil {
		return err
	}
	var windows [][]Pane
	for _, s := range OrderSessions(panes) {
		windows = append(windows, s.Windows...)
	}
	if len(windows) == 0 {
		return nil
	}

	session, _ := ClientState(client)
	activeWindowID := ""
	for _, p := range panes {
		if p.SessionName == session && p.Active {
			activeWindowID = p.WindowID
			break
		}
	}
	if activeWindowID == "" {
		return nil
	}
	i := -1
	for j, w := range windows {
		if w[0].WindowID == activeWindowID {
			i = j
			break
		}
	}
	if i < 0 {
		return nil
	}
	delta := -1
	if next {
		delta = 1
	}
	found := -1
	j := i
	for k := 0; k < len(windows); k++ {
		j = (j + delta + len(windows)) % len(windows)
		if windows[j][0].Subagent == "" {
			found = j
			break
		}
	}
	if found < 0 || found == i {
		return nil
	}
	target := windows[found][0]

	_, err = run("switch-client", "-c", client, "-t", target.SessionID, ";",
		"select-window", "-t", target.WindowID)
	return err
}

// sideFocusFlag is the patched tmux's client flag that routes keys to the
// side status line's job.
const sideFocusFlag = "side-status-focus"

// clientFormat is what ClientState asks for, one line per client.
// display-message -c would be shorter, but it only honours -c for the
// formats when the target client happens to be on the command's own target
// session (cmd-display-message.c), which is not so over the control
// connection: that client has a session of its own.
var clientFormat = strings.Join([]string{
	"#{client_name}",
	"#{client_session}",
	"#{client_flags}",
	"#{client_control_mode}",
}, sep)

// parseClientState picks client's line out of list-clients output.
func parseClientState(lines []string, client string) (session string, focused bool) {
	for _, line := range lines {
		f := strings.SplitN(line, sep, 4)
		if len(f) < 4 || f[0] != client {
			continue
		}
		return f[1], strings.Contains(f[2], sideFocusFlag)
	}
	return "", false
}

// ClientState returns the client's session and whether the side status
// line has its keyboard focus.
func ClientState(client string) (session string, focused bool) {
	out, err := run("list-clients", "-F", clientFormat)
	if err != nil {
		return "", false
	}
	return parseClientState(strings.Split(out, "\n"), client)
}

// realClients picks out the non-control-mode client names attached to a
// session from list-clients output in clientFormat. Kido's own control
// connections (Conn, one dialled per real client by side-status-command)
// are attached to that same session and would otherwise be counted as
// people to jump; #{client_control_mode} is the literal property that
// makes a client unjumpable, unlike an empty #{client_tty} - which a
// control client happens to have too, but so would some future client
// type that is not one.
func realClients(lines []string) []string {
	var out []string
	for _, line := range lines {
		f := strings.SplitN(line, sep, 4)
		if len(f) < 4 || f[0] == "" || f[3] == "1" {
			continue
		}
		out = append(out, f[0])
	}
	return out
}

// paneSessionTarget resolves the session a standalone kido should look at
// to find its own client: pane's own session from a live lookup, when
// pane still names a pane tmux knows about (panes move, so nothing but a
// fresh query is trustworthy) - or, when pane names nothing tmux can find,
// the session id tmux substituted into $TMUX (tmuxEnv) at launch. That
// fallback is what a popup needs: display-popup gives its command no pane
// of its own, so the popup's $TMUX_PANE is absent from tmux's pane list
// entirely, but its $TMUX carries "socket,pid,session-id" for the session
// it was opened from - safe to trust for a popup's few-second life, which
// cannot outlast a session rename or move.
func paneSessionTarget(pane, tmuxEnv string) string {
	if pane != "" {
		if out, err := run("display-message", "-p", "-t", pane, "#{session_id}"); err == nil && out != "" {
			return out
		}
	}
	f := strings.Split(tmuxEnv, ",")
	if len(f) < 3 || f[2] == "" {
		return ""
	}
	return "$" + f[2]
}

// ResolveClient answers "who is attached to this pane's session", ignoring
// kido's own control connections, so a standalone kido (a plain pane, or a
// popup with no -client of its own) can pick its client without asking
// tmux the unanswerable #{client_name} question - see the comment on
// Options.Client in cmd/kido/main.go for why that is a different question
// with no good answer from inside. It returns "" - the caller's existing
// ambiguous case - when zero or more than one real client is attached.
func ResolveClient(pane, tmuxEnv string) string {
	target := paneSessionTarget(pane, tmuxEnv)
	if target == "" {
		return ""
	}
	out, err := run("list-clients", "-t", target, "-F", clientFormat)
	if err != nil {
		return ""
	}
	real := realClients(strings.Split(out, "\n"))
	if len(real) == 1 {
		return real[0]
	}
	return ""
}

// ActivePane returns the pane ID of the active pane of session within
// panes, or "" if none is found.
func ActivePane(panes []Pane, session string) string {
	for _, p := range panes {
		if p.SessionName == session && p.Active {
			return p.PaneID
		}
	}
	return ""
}

// Jump makes paneID the active pane of client, switching session and
// window as needed, and hands it the keyboard.
//
// The side-focus flag is cleared here in every mode, standalone included.
// Clearing a flag a client does not have is a no-op, checked by hand on a
// server with side-status off, where the jump goes through unharmed; and
// when the client does happen to be showing a focused sidebar, a jump made
// from a popup should hand it the keyboard just as one made from the
// sidebar does.
func Jump(client, paneID string) error {
	_, err := run("switch-client", "-c", client, "-t", paneID, ";",
		"select-window", "-t", paneID, ";",
		"select-pane", "-t", paneID, ";",
		"refresh-client", "-t", client, "-f", "!"+sideFocusFlag)
	return err
}

// ReleaseSideFocus hands keyboard focus from the side status line back to
// the client's active pane.
func ReleaseSideFocus(client string) error {
	_, err := run("refresh-client", "-t", client, "-f", "!"+sideFocusFlag)
	return err
}

// promptKeyDelay is the pause between delivering a prompt's text and
// pressing Enter: without it, a paste-sensitive reader (Claude Code
// included) can see the Enter as part of the pasted text rather than a
// submission.
const promptKeyDelay = 100 * time.Millisecond

// promptBufferPrefix names the tmux buffer SendPrompt loads a prompt
// into. tmux's own buffers are named buffer0, buffer1 and so on, and a
// name a user picks by hand is theirs to choose, so nothing of theirs can
// carry this prefix; the pid keeps two kido processes on one server off
// each other's buffer. Pasting with -d deletes it again, leaving the
// user's buffer stack and its ordering exactly as it was.
const promptBufferPrefix = "kido-prompt"

// promptBuffer is the buffer name for this process.
func promptBuffer() string { return fmt.Sprintf("%s-%d", promptBufferPrefix, os.Getpid()) }

// SendPrompt delivers text to pane as a paste, then presses Enter after
// promptKeyDelay.
//
// A paste rather than literal keys, because send-keys -l writes the bytes
// to the pty as they are: an application that has enabled bracketed paste
// - Claude Code, zsh's zle, most TUIs - reads a bare newline as a submit,
// so a multi-line prompt would arrive as one input per line, the first
// submitted alone and the rest left dangling. paste-buffer -p wraps the
// text in the paste brackets when the application asked for them, which
// makes its newlines part of a single input; when it did not ask, -p
// pastes the raw bytes, exactly today's behaviour for a plain shell pane.
//
// Enter stays a separate key after promptKeyDelay: sent before the text
// has landed, the submit cuts the paste mid-line.
func SendPrompt(pane, text string) error {
	buf := promptBuffer()
	if _, err := runStdin(text, "load-buffer", "-b", buf, "-"); err != nil {
		return err
	}
	if _, err := run("paste-buffer", "-b", buf, "-d", "-t", pane, "-p"); err != nil {
		// -d never ran, so the buffer would otherwise outlive the failure.
		run("delete-buffer", "-b", buf)
		return err
	}
	time.Sleep(promptKeyDelay)
	_, err := run("send-keys", "-t", pane, "Enter")
	return err
}

// newWindowArgs builds the new-window invocation NewWindow runs, split out
// so it can be checked without a tmux server. -d keeps the caller's turn
// where it is; -c is needed because the new pane otherwise starts in the
// session's default directory; -e because new-window otherwise runs
// command with the server's environment, not the caller's; -P -F returns
// the new ids synchronously.
func newWindowArgs(session, name, cwd string, env, command []string) []string {
	args := []string{
		"new-window", "-d", "-P", "-F", "#{window_id}:#{pane_id}:#{pane_pid}",
		"-t", session + ":", "-n", name, "-c", cwd,
	}
	for _, kv := range env {
		args = append(args, "-e", kv)
	}
	return append(args, command...)
}

// NewWindow creates a detached window in session running command (each
// element execed directly; tmux routes a single-word command through the
// pane's shell instead), in cwd, with env (each "KEY=VALUE") set for that
// command alone. It returns the new window and pane ids and the pid of
// the exec'd command itself, and turns on remain-on-exit for the pane it
// made - a pane-scoped option ("-p"), not a window-scoped one: the
// latter applies to every pane of the window including one a user splits
// off later, and would keep an ordinary shell pane on screen as a
// "Pane is dead" corpse once its own command exits.
//
// remain-on-exit is set by a second tmux call, and a command that exits
// fast enough beats it every time: measured against the fork, a window
// running /bin/true was gone before the option landed in 20 attempts out
// of 20. The fixes all cost more than the gap: folding the option into
// one invocation means naming the window before its id is known, and
// `-t '{end}'` is only usually right (new-window takes the lowest free
// index, and two spawns can race); a shell wrapper reintroduces the
// three-parser quoting hazard; creating the window empty and
// respawn-pane'ing into it costs two more round-trips and a second query
// for the pid.
func NewWindow(session, name, cwd string, env, command []string) (windowID, paneID string, panePID int, err error) {
	out, err := run(newWindowArgs(session, name, cwd, env, command)...)
	if err != nil {
		return "", "", 0, err
	}
	parts := strings.SplitN(out, ":", 3)
	if len(parts) != 3 {
		return "", "", 0, fmt.Errorf("new-window: unexpected output %q", out)
	}
	windowID, paneID = parts[0], parts[1]
	pid, err := strconv.Atoi(parts[2])
	if err != nil {
		return "", "", 0, fmt.Errorf("new-window: unexpected pane_pid %q", parts[2])
	}
	if _, err := run("set-option", "-p", "-t", paneID, "remain-on-exit", "on"); err != nil {
		// Losing the race above is not a failure to create the window: the
		// command ran, and what it cost is the corpse on screen. A window
		// tmux can no longer find is exactly that case, and reporting it as
		// an error would make every fast-exiting command - the typo, the
		// `true` - look like a window that was never made.
		if !WindowExists(windowID) {
			return windowID, paneID, pid, nil
		}
		return "", "", 0, err
	}
	return windowID, paneID, pid, nil
}

// WindowExists reports whether the server still has windowID. It answers
// the one question that tells a tmux command failing because the server
// is unreachable from one failing because the window it named has since
// closed - which, for a window holding a command of its own, is an
// ordinary ending rather than an error.
//
// The answer is the id it echoes back, not the exit status: measured on
// the fork, `display-message -p -t @1 '#{window_id}'` for a window that
// has closed exits 0 and prints an empty line, where `set-window-option
// -t @1` on the same window fails with "no such window: @1".
func WindowExists(windowID string) bool {
	out, err := run("display-message", "-p", "-t", windowID, "#{window_id}")
	return err == nil && out == windowID
}

// Watched reports whether p is a pane somebody is looking at right now:
// its session's current pane, in a session some client is attached to.
// Being the current pane is not enough on its own - a detached session
// still has one, with nobody there to read it.
func (p Pane) Watched() bool { return p.Active && p.SessionAttached }

// WindowFocused reports whether windowID holds such a pane, which for a
// window means the user is reading it. It answers from the pane list
// alone, and is the one definition of focus the linger helper and the
// reaper share: a window one refuses to close, the other must too.
func WindowFocused(panes []Pane, windowID string) bool {
	for _, p := range panes {
		if p.WindowID == windowID && p.Watched() {
			return true
		}
	}
	return false
}

// LastWindow reports whether windowID is the only window of its session.
// Closing it would destroy the session and detach every client.
func LastWindow(panes []Pane, windowID string) bool {
	session := ""
	for _, p := range panes {
		if p.WindowID == windowID {
			session = p.SessionID
			break
		}
	}
	if session == "" {
		return false
	}
	windows := map[string]bool{}
	for _, p := range panes {
		if p.SessionID == session {
			windows[p.WindowID] = true
		}
	}
	return len(windows) <= 1
}

// WindowAllDead reports whether every pane of windowID is a
// remain-on-exit corpse. A split window is finished only once all of it
// is: close-window and the sweep (internal/reap's foldWindows) share the
// rule, since a subagent that split its own window and left something
// running in the other pane is still working.
func WindowAllDead(panes []Pane, windowID string) bool {
	found := false
	for _, p := range panes {
		if p.WindowID != windowID {
			continue
		}
		found = true
		if !p.Dead {
			return false
		}
	}
	return found
}

// LastPane reports whether windowID has exactly one pane. Killing a
// window's only pane closes the window as tmux's own side effect.
func LastPane(panes []Pane, windowID string) bool {
	n := 0
	for _, p := range panes {
		if p.WindowID == windowID {
			n++
		}
	}
	return n <= 1
}

// KillWindow destroys windowID. A window that is already gone is an
// error from tmux and nothing more; every caller is one of several
// processes racing to close the same window.
func KillWindow(windowID string) error {
	_, err := run("kill-window", "-t", windowID)
	return err
}

// KillPane destroys paneID, leaving any other pane in its window alone.
func KillPane(paneID string) error {
	_, err := run("kill-pane", "-t", paneID)
	return err
}

// SubagentMark, SubagentRunID and SubagentParentInstance are the parts of
// the mark's value, kept together so the tokens anything parses cannot
// drift from the code that writes them. The rest is free text for a
// human reading `tmux show-options -w`. A missing token yields "", and a
// sweep (for run=) or the sidebar (for parent=) still works without it.
func SubagentMark(runID, parentInstance string, depth int) string {
	return fmt.Sprintf("run=%s parent=%s depth=%d", runID, parentInstance, depth)
}

func SubagentRunID(info string) string {
	return subagentField(info, "run=")
}

// SubagentParentInstance is the sidebar's fallback anchor once a
// subagent's own state record is gone: the mark is set once, when kido
// spawn creates the window, and outlives the record the way the window
// itself does.
func SubagentParentInstance(info string) string {
	return subagentField(info, "parent=")
}

func subagentField(info, prefix string) string {
	for _, field := range strings.Fields(info) {
		if v, ok := strings.CutPrefix(field, prefix); ok {
			return v
		}
	}
	return ""
}

// MarkSubagent sets SubagentOption on windowID to info (SubagentMark).
func MarkSubagent(windowID, info string) error {
	_, err := run("set-option", "-w", "-t", windowID, SubagentOption, info)
	return err
}

// MarkSubagentPane sets SubagentPaneOption on paneID to runID, a
// pane-scoped option ("-p") rather than the window-scoped one
// MarkSubagent writes: it must not be readable through the window-option
// fallback on any other pane of the same window, which is the whole
// point of having it.
func MarkSubagentPane(paneID, runID string) error {
	_, err := run("set-option", "-p", "-t", paneID, SubagentPaneOption, runID)
	return err
}
