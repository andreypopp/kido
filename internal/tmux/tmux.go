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

// Binary returns the tmux executable to run: $KIDO_TMUX if set, else
// "kido-tmux" beside the kido binary, else "tmux" on PATH.
func Binary() string {
	binaryOnce.Do(func() {
		binaryPath = resolveBinary(os.Getenv("KIDO_TMUX"), os.Args[0])
	})
	return binaryPath
}

// GlobalOption reads a global tmux option, empty when it is unset or when
// there is no server to ask (-q, so an unknown user option is empty
// rather than an error).
func GlobalOption(name string) string {
	out, err := runStdin("", "show-options", "-gqv", name)
	if err != nil {
		return ""
	}
	return out
}

func resolveBinary(kidoTmuxEnv, arg0 string) string {
	if kidoTmuxEnv != "" {
		return kidoTmuxEnv
	}
	exe, err := InvokedPath(arg0)
	if err == nil {
		if sib := siblingTmux(exe); sib != "" {
			return sib
		}
	}
	return "tmux"
}

// InvokedPath returns the path kido was started as, with symlinks left
// alone. os.Executable is not it on Linux, where it reads /proc/self/exe
// and always comes back fully resolved. argv[0] is used as-is when it
// has a separator, looked up on PATH otherwise; os.Executable is the
// fallback for a cleared argv[0] or a failed lookup.
func InvokedPath(arg0 string) (string, error) {
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

// Candidates returns exe and, if it differs, the path its symlinks
// resolve to - unresolved first. Homebrew's bin directory is a symlink
// repointed on every upgrade, so the unresolved spelling survives a
// `brew cleanup` that deletes the resolved one.
func Candidates(exe string) []string {
	c := []string{exe}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil && resolved != exe {
		c = append(c, resolved)
	}
	return c
}

func siblingTmux(exe string) string {
	for _, c := range Candidates(exe) {
		sib := filepath.Join(filepath.Dir(c), "kido-tmux")
		if fi, err := os.Stat(sib); err == nil && !fi.IsDir() {
			return sib
		}
	}
	return ""
}

func runStdin(stdin string, args ...string) (string, error) {
	cmd := exec.Command(Binary(), args...)
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
	// OSC 133 shell integration; a shell that never emits the markers
	// (shell/zsh's is what kido ships) leaves LastPromptTime zero.
	// AlternateOn is tmux's own #{alternate_on}: the innermost program
	// that has taken the terminal (vim, a pager) by switching to the
	// alternate buffer, unlike pane_current_command's process-group leader.
	AlternateOn      bool
	CommandRunning   bool
	CommandStartTime int64 // unix time of the last 133;C
	LastPromptTime   int64 // unix time of the last 133;A
	// LastExit is nil when tmux has no exit status on record:
	// pane_command_status prints empty rather than 0 for that case.
	LastExit *Exit
	// CommandLine is the shell's last-reported 133;C command line, kept by
	// tmux until the next one. tmux sanitises it: control bytes are
	// dropped and "#(" is rewritten.
	CommandLine string
	// DeadAt is tmux's #{pane_dead_time}, 0 for a live pane; unlike
	// pane_command_duration it does not tick. tmux sets #{pane_dead}
	// before #{pane_dead_time}, so a pane dead under one poll interval can
	// still read as alive here.
	DeadAt int64
	// Run is @kido_run (RunOption), pane-scoped so it does not fall back
	// to the window: a pane split off a run's window later reads "".
	Run string
	// SessionAttached is whether any client is attached to this pane's
	// session.
	SessionAttached bool
	Title           string
}

// Exit is a finished command's exit status, from tmux's #{pane_command_status}
// and #{pane_command_end_time}.
type Exit struct {
	Code int
	At   int64 // unix seconds of the 133;D
}

// Shell is a pane's OSC 133 shell-integration state.
type Shell uint8

const (
	ShellNone    Shell = iota // no prompt has ever been marked; the shell has no integration
	ShellIdle                 // at a prompt, nothing running
	ShellRunning              // a command is running
)

// Shell reports pane p's shell-integration state. ShellNone means no OSC
// 133 prompt has ever been marked - every pane started before the
// integration loaded.
//
// The running rule is deliberately not just CommandRunning: a program
// that emits 133;C without a matching 133;D (pi does this) would
// otherwise read as running forever. The shell's next 133;A puts
// LastPromptTime after CommandStartTime, healing the pane back to idle.
func (p Pane) Shell() Shell {
	if p.LastPromptTime == 0 {
		return ShellNone
	}
	if p.CommandRunning && !(p.LastPromptTime > p.CommandStartTime) {
		return ShellRunning
	}
	return ShellIdle
}

const sep = "\x1f"

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
	// pane_command_duration is deliberately left out: it ticks every
	// second, which would defeat the snapshot change-detection.
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
	"#{" + RunOption + "}",
	"#{pane_title}", // last: it may contain anything
}, sep)

// RunOption is the tmux pane-scoped option ("set-option -p") kido
// spawn_subagent sets to a run id on the one pane a run actually runs in;
// it does not fall back to the window, so a pane the user splits off
// later reads "".
const RunOption = "@kido_run"

// paneFields is the number of #{...} entries paneFormat asks tmux for;
// parsePanes' SplitN count and len(f) guard both use it so the two cannot
// drift apart (TestPaneFormatFieldCountMatchesConstant).
const paneFields = 24

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
			CommandRunning: f[13] == "1", CommandLine: f[18],
			SessionAttached: f[21] != "" && f[21] != "0",
			Run:             f[22], Title: f[23]}
		p.SessionCreated, _ = strconv.ParseInt(f[2], 10, 64)
		p.WindowIndex, _ = strconv.Atoi(f[3])
		p.PanePID, _ = strconv.Atoi(f[9])
		p.CommandStartTime, _ = strconv.ParseInt(f[14], 10, 64)
		p.LastPromptTime, _ = strconv.ParseInt(f[15], 10, 64)
		if n, err := strconv.Atoi(f[16]); err == nil { // empty means no exit status on record
			at, _ := strconv.ParseInt(f[17], 10, 64)
			p.LastExit = &Exit{Code: n, At: at}
		}
		if f[19] == "1" {
			p.DeadAt, _ = strconv.ParseInt(f[20], 10, 64)
		}
		panes = append(panes, p)
	}
	return panes
}

// paneNum is the numeric part of a pane id ("%12" -> 12), tmux's own
// creation-order counter.
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
	// ID is the session id ("$3") and what every command targeting this
	// session must pass: a name goes through tmux's target parser, which
	// splits on "." and ":", so "team.build" is looked for as pane
	// "build" of window "team" and not found.
	ID      string
	Windows [][]Pane
}

// OrderSessions groups panes into sessions and windows in kido's order:
// sessions oldest first (session_created), ties broken by name, and
// within a session each window's own panes oldest first - the numeric
// part of the pane id, which tmux allocates monotonically, unlike
// #{pane_index} (a layout position: `split-window -b` puts the new pane
// first). The sidebar's grouping, `kido switch-session` and `kido
// switch-window` all walk this one order.
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
	out, err := runStdin("", "list-panes", "-a", "-F", paneFormat)
	if err != nil {
		return nil, err
	}
	return parsePanes(strings.Split(out, "\n")), nil
}

// CapturePane returns the visible contents of a pane as plain text, one
// line per screen row. Wrapped lines are deliberately not joined (-J):
// what the caller reads is the shape of the last few rows.
func CapturePane(pane string) ([]string, error) {
	out, err := runStdin("", "capture-pane", "-p", "-t", pane)
	if err != nil {
		return nil, err
	}
	return strings.Split(out, "\n"), nil
}

// CaptureScreen returns pane's visible screen plus up to 1000 lines of
// scrollback, joined as a single block of text. The bound keeps a pane
// with a large history-limit from turning one capture-pane call into
// megabytes before internal/reap's own byte cap gets a chance to trim it.
func CaptureScreen(pane string) (string, error) {
	return runStdin("", "capture-pane", "-p", "-t", pane, "-S", "-1000")
}

// CurrentClient asks tmux which client this process belongs to. Used when
// kido is started by hand in a pane rather than by the side status line.
func CurrentClient() string {
	out, _ := runStdin("", "display-message", "-p", "#{client_name}")
	return out
}

// SwitchSession switches client to the session adjacent to its current
// one in kido's order (OrderSessions), wrapping around. next selects the
// following session, otherwise the preceding one. A server with one
// session, or a client not attached to any session kido can find, is a
// no-op.
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

	_, err = runStdin("", "switch-client", "-c", client, "-t", target.ID)
	return err
}

// SwitchWindow switches client to the window adjacent to its current one
// in kido's order (OrderSessions), wrapping around the whole server and
// crossing session boundaries - unlike tmux's own next-window/
// previous-window, which wrap inside one session.
//
// A subagent's window (one with a run pane, RunOption) is skipped over
// rather than visited: it stays reachable through the sidebar's Enter
// without flickering in and out of ⇧↓'s reach as its pane dies and is
// swept. Landing back on the starting window means it is the only
// unmarked one on the server. A client whose current window kido cannot
// find is a no-op.
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
		if _, ok := RunPane(windows[j], windows[j][0].WindowID); !ok {
			found = j
			break
		}
	}
	if found < 0 || found == i {
		return nil
	}
	target := windows[found][0]

	_, err = runStdin("", "switch-client", "-c", client, "-t", target.SessionID, ";",
		"select-window", "-t", target.WindowID)
	return err
}

// sideFocusFlag is the patched tmux's client flag that routes keys to the
// side status line's job.
const sideFocusFlag = "side-status-focus"

// clientFormat is what ClientState asks for, one line per client.
// display-message -c only honours -c for the formats when the target
// client is on the command's own target session (cmd-display-message.c),
// which is not so over the control connection.
var clientFormat = strings.Join([]string{
	"#{client_name}",
	"#{client_session}",
	"#{client_flags}",
	"#{client_control_mode}",
}, sep)

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
	out, err := runStdin("", "list-clients", "-F", clientFormat)
	if err != nil {
		return "", false
	}
	return parseClientState(strings.Split(out, "\n"), client)
}

// realClients picks out the non-control-mode client names attached to a
// session from list-clients output in clientFormat. Kido's own control
// connections would otherwise be counted as people to jump;
// #{client_control_mode} is what makes a client unjumpable, unlike an
// empty #{client_tty} which a control client happens to have too.
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
// to find its own client: pane's own session from a live lookup, or,
// when pane names nothing tmux can find, the session id tmux substituted
// into $TMUX (tmuxEnv) at launch. That fallback is what a popup needs:
// display-popup gives its command no pane of its own, so $TMUX_PANE is
// absent from tmux's pane list, but $TMUX carries "socket,pid,session-id"
// for the session it was opened from.
func paneSessionTarget(pane, tmuxEnv string) string {
	if pane != "" {
		if out, err := runStdin("", "display-message", "-p", "-t", pane, "#{session_id}"); err == nil && out != "" {
			return out
		}
	}
	f := strings.Split(tmuxEnv, ",")
	if len(f) < 3 || f[2] == "" {
		return ""
	}
	return "$" + f[2]
}

// ResolveClient answers "who is attached to this pane's session",
// ignoring kido's own control connections, so a standalone kido (a plain
// pane, or a popup with no -client of its own) can pick its client
// without asking tmux the unanswerable #{client_name} question. It
// returns "" when zero or more than one real client is attached.
func ResolveClient(pane, tmuxEnv string) string {
	target := paneSessionTarget(pane, tmuxEnv)
	if target == "" {
		return ""
	}
	out, err := runStdin("", "list-clients", "-t", target, "-F", clientFormat)
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
// window as needed, and hands it the keyboard. The side-focus flag is
// cleared unconditionally: clearing a flag the client does not have is a
// no-op.
func Jump(client, paneID string) error {
	_, err := runStdin("", "switch-client", "-c", client, "-t", paneID, ";",
		"select-window", "-t", paneID, ";",
		"select-pane", "-t", paneID, ";",
		"refresh-client", "-t", client, "-f", "!"+sideFocusFlag)
	return err
}

// ReleaseSideFocus hands keyboard focus from the side status line back to
// the client's active pane.
func ReleaseSideFocus(client string) error {
	_, err := runStdin("", "refresh-client", "-t", client, "-f", "!"+sideFocusFlag)
	return err
}

// promptKeyDelay is the pause between delivering a prompt's text and
// pressing Enter: without it, a paste-sensitive reader (Claude Code
// included) can see the Enter as part of the pasted text.
const promptKeyDelay = 100 * time.Millisecond

// SendPrompt delivers text to pane as a paste, then presses Enter after
// promptKeyDelay.
//
// A paste rather than literal keys: send-keys -l writes raw bytes, and
// under bracketed paste (Claude Code, zsh's zle, most TUIs) a bare
// newline submits, splitting a multi-line prompt into one input per
// line. paste-buffer -p brackets the text when the application asked for
// it, and pastes raw otherwise.
//
// Enter is a separate key after promptKeyDelay: sent with the paste, it
// cuts the paste mid-line.
func SendPrompt(pane, text string) error {
	// pid keeps two kido processes on one server off each other's buffer.
	buf := fmt.Sprintf("kido-prompt-%d", os.Getpid())
	if _, err := runStdin(text, "load-buffer", "-b", buf, "-"); err != nil {
		return err
	}
	if _, err := runStdin("", "paste-buffer", "-b", buf, "-d", "-t", pane, "-p"); err != nil {
		runStdin("", "delete-buffer", "-b", buf) // -d never ran
		return err
	}
	time.Sleep(promptKeyDelay)
	_, err := runStdin("", "send-keys", "-t", pane, "Enter")
	return err
}

// newWindowArgs builds the new-window invocation NewWindow runs. -d keeps
// the caller's turn where it is; -c is needed because the new pane
// otherwise starts in the session's default directory; -e because
// new-window otherwise runs command with the server's environment; -P -F
// returns the new ids synchronously.
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
// made - pane-scoped ("-p"), since a window-scoped one would keep an
// ordinary shell pane split off later on screen as a corpse once its own
// command exits.
//
// remain-on-exit is set by a second tmux call, and a command that exits
// fast enough beats it every time (measured against the fork: a window
// running /bin/true was gone before the option landed in 20 attempts out
// of 20). Folding it into one invocation, a shell wrapper, and a
// respawn-pane approach were all tried and cost more than the gap.
func NewWindow(session, name, cwd string, env, command []string) (windowID, paneID string, panePID int, err error) {
	out, err := runStdin("", newWindowArgs(session, name, cwd, env, command)...)
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
	if _, err := runStdin("", "set-option", "-p", "-t", paneID, "remain-on-exit", "on"); err != nil {
		// Losing the remain-on-exit race is not a failure to create the
		// window: the command ran, and what it cost is the corpse on screen.
		if !WindowExists(windowID) {
			return windowID, paneID, pid, nil
		}
		return "", "", 0, err
	}
	return windowID, paneID, pid, nil
}

// WindowExists reports whether the server still has windowID: for a
// window holding a command of its own, its absence is an ordinary
// ending, not an error. The answer is the id echoed back, not the exit
// status: measured on the fork, `display-message -p -t @1
// '#{window_id}'` on a closed window exits 0 and prints an empty line.
func WindowExists(windowID string) bool {
	out, err := runStdin("", "display-message", "-p", "-t", windowID, "#{window_id}")
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
	_, err := runStdin("", "kill-window", "-t", windowID)
	return err
}

// KillPane destroys paneID, leaving any other pane in its window alone.
func KillPane(paneID string) error {
	_, err := runStdin("", "kill-pane", "-t", paneID)
	return err
}

// MarkRun sets RunOption on paneID to runID: killing the pane later
// clears the option with it, so nothing ever has to unset it by hand.
func MarkRun(paneID, runID string) error {
	_, err := runStdin("", "set-option", "-p", "-t", paneID, RunOption, runID)
	return err
}

// RunPane finds the pane in windowID that carries RunOption, among
// panes - the run's own pane, if this window has one at all. A window
// with no such pane, a user's plain window included, reports false.
func RunPane(panes []Pane, windowID string) (Pane, bool) {
	for _, p := range panes {
		if p.WindowID == windowID && p.Run != "" {
			return p, true
		}
	}
	return Pane{}, false
}
