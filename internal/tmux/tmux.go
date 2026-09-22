// Package tmux talks to the tmux server that owns this process.
package tmux

import (
	"fmt"
	"os"
	"os/exec"
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

// binary returns the tmux executable to run: the one running the server
// named by $TMUX when it can be found (so a patched tmux talks to itself),
// else whatever "tmux" resolves to on PATH.
func binary() string {
	binaryOnce.Do(func() {
		f := strings.Split(os.Getenv("TMUX"), ",")
		if len(f) < 2 {
			return
		}
		pid := f[1]

		// Linux: /proc/<pid>/exe is a symlink to the absolute binary path,
		// unlike "ps -o comm=" which only reports the basename.
		if p, err := os.Readlink("/proc/" + pid + "/exe"); err == nil {
			if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
				binaryPath = p
				return
			}
		}

		out, err := exec.Command("ps", "-o", "comm=", "-p", pid).Output()
		if err != nil {
			return
		}
		p := strings.TrimSpace(string(out))
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			binaryPath = p
		}
	})
	return binaryPath
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
	// emit the markers (kido ships a zsh integration in shell/zsh,
	// installed by `kido setup-zsh`). A shell that
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
	// Dead is tmux's own #{pane_dead}: the pane's command has exited and
	// remain-on-exit kept the pane - and with it the window - on screen
	// anyway. DeadTime is when it exited, in unix seconds, and is fixed
	// from then on: unlike pane_command_duration neither field ticks, so
	// neither defeats the snapshot change-detection.
	Dead     bool
	DeadTime int64
	// Subagent is the @kido_subagent window option kido spawn sets on a
	// window of its own making, read through the pane because one
	// list-panes is the only listing kido takes. It is what tells a window
	// kido spawned from every other window on the server; see
	// internal/reap.
	Subagent string
	// SessionAttached is whether any client is attached to this pane's
	// session. With Active - window_active && pane_active, so a session's
	// current pane - it is what WindowFocused means by a window somebody
	// is looking at.
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
	// Window lifecycle: a pane remain-on-exit left behind, when it died,
	// whether anyone is attached to look at it, and the mark kido spawn
	// puts on a window of its own making.
	"#{pane_dead}",
	"#{pane_dead_time}",
	"#{session_attached}",
	"#{" + SubagentOption + "}",
	"#{pane_title}",
}, sep)

// SubagentOption is the tmux window option kido spawn sets on a window it
// creates, and the only thing that marks a window as kido's to close (see
// internal/reap). A window option rather than a field of the state
// record: it lives in the tmux server, so it outlives the agent whose
// window it is, state.Load's dead-pid sweep cannot delete it, and it
// names a window that exists now rather than a pane id some later server
// may have handed to somebody else.

const SubagentOption = "@kido_subagent"

// parsePanes turns list-panes output lines into panes. Shared by the exec
// and control-mode paths, which ask for the same format.
func parsePanes(lines []string) []Pane {
	var panes []Pane
	for _, line := range lines {
		f := strings.SplitN(line, sep, 23)
		if len(f) < 23 {
			continue
		}
		p := Pane{SessionName: f[0], SessionID: f[1], WindowID: f[4], WindowName: f[5], WindowLayout: f[6],
			PaneID: f[7], Active: f[8] == "1", CurrentCommand: f[10],
			CurrentPath: f[11], AlternateOn: f[12] == "1",
			CommandRunning: f[13] == "1", Dead: f[18] == "1",
			SessionAttached: f[20] != "" && f[20] != "0",
			Subagent:        f[21], Title: f[22]}
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
		p.DeadTime, _ = strconv.ParseInt(f[19], 10, 64)
		panes = append(panes, p)
	}
	return panes
}

// Session is one session's windows, grouped the way kido shows and walks
// them: Windows[i] is one window's panes in pane order, so Windows[i][0]
// identifies the window (SessionName, WindowID).
type Session struct {
	Name    string
	Windows [][]Pane
}

// OrderSessions groups panes into sessions and windows in kido's order:
// sessions oldest first (session_created), ties broken by name, and within
// a session each window's panes kept in ListPanes' own order (tmux's
// natural window order). This is kido's one true order, derived from one
// list-panes: the sidebar's grouping, `kido switch-session` and `kido
// switch-window` all walk it, so they cannot drift apart.
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
			g = &group{created: p.SessionCreated, sess: Session{Name: p.SessionName}}
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

	_, err = run("switch-client", "-c", client, "-t", target.Name)
	return err
}

// SwitchWindow switches client to the window adjacent to its current one in
// kido's order (OrderSessions: sessions oldest first, windows in tmux's own
// order within a session), wrapping around the whole server. This crosses
// session boundaries: advancing past a session's last window moves to the
// next session's first window, unlike tmux's own next-window/previous-window
// which wrap inside one session. A server with one window, or a client whose
// current window kido cannot find, is a no-op.
func SwitchWindow(client string, next bool) error {
	panes, err := ListPanes()
	if err != nil {
		return err
	}
	var windows [][]Pane
	for _, s := range OrderSessions(panes) {
		windows = append(windows, s.Windows...)
	}
	if len(windows) < 2 {
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
	target := windows[(i+delta+len(windows))%len(windows)][0]

	_, err = run("switch-client", "-c", client, "-t", target.SessionName, ";",
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
}, sep)

// parseClientState picks client's line out of list-clients output.
func parseClientState(lines []string, client string) (session string, focused bool) {
	for _, line := range lines {
		f := strings.SplitN(line, sep, 3)
		if len(f) < 3 || f[0] != client {
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
// so it can be checked without a real tmux server: the flags are what a
// subagent's window depends on (see docs/subagents-plan.md's Spawning
// section and AGENTS.md), and getting one wrong is silent until a child
// starts in the wrong place or with a bare environment.
//
//   - -d: the caller's own turn is not yanked to the new window.
//   - -c: without it the new pane starts in the session's default
//     directory, not the caller's own; snapshot.go relies on the same flag
//     for the same reason.
//   - -e: new-window otherwise runs command with the server's and
//     session's own environment, not the caller's, so nothing - a child's
//     parent identity, its task file - arrives any other way.
//   - -P -F: the new ids come back synchronously, with no follow-up query.
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
// element execed directly, per newWindow's own comment in
// e2e/harness_test.go - a single-word command instead runs through the
// pane's shell), in cwd, with env (each "KEY=VALUE") set for that command
// alone. It returns the new window and pane ids, and the pid of command
// itself (the exec'd process, not a wrapping shell - see the comment
// above), from the one call. kido spawn (internal/subrun's Meta.PID)
// keeps that pid to answer "is this run still alive" without a live tmux
// session to ask, which is what lets `kido runs` work after the window -
// or the whole server - is gone.
//
// remain-on-exit is turned on for the new window before returning: a
// subagent's window (the only caller today, kido spawn) must survive its
// own command exiting, both for the ~30s the linger helper gives the user
// to read its last screen and for `kido reap` to find and close it
// afterward if the helper never ran at all - a window that vanished the
// instant its command exited would leave nothing for either to act on.
//
// It is set by a second tmux call, and a command that exits fast enough
// beats it every time: measured against the fork, a window running
// /bin/true was gone before the option landed in 20 attempts out of 20.
// So the case this most wants to preserve - a child that failed
// immediately, including one tmux could not exec at all - is exactly the
// one that loses its window, its last screen, and the sweep that would
// have recorded the run as died. What survives is the run record itself
// (internal/subrun), whose meta carries the pid, so `kido runs` still
// reports that run as died from EffectiveOutcome's own read-time guess.
// The fixes all cost more than the gap: folding the option into one tmux
// invocation means naming the new window before its id is known, and
// `-t '{end}'` is only usually right (new-window takes the lowest free
// index, and two spawns can race), so it would sometimes set the option
// on an innocent window instead; setting it from inside a shell wrapper
// around command reintroduces the three-parser quoting hazard AGENTS.md
// refuses elsewhere; and creating the window empty, setting the option,
// then respawn-pane'ing into it orders things correctly but costs two
// more round-trips and a second query for the new pid.
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
	if _, err := run("set-window-option", "-t", windowID, "remain-on-exit", "on"); err != nil {
		return "", "", 0, err
	}
	return windowID, paneID, pid, nil
}

// Watched reports whether p is a pane somebody is looking at right now:
// its session's current pane, in a session some client is attached to.
// Being the current pane is not enough on its own - a detached session
// still has one, with nobody there to read it.
func (p Pane) Watched() bool { return p.Active && p.SessionAttached }

// WindowFocused reports whether windowID holds such a pane, which for a
// window means the user is reading it.
//
// It answers from the pane list alone, with no list-clients call of its
// own, because both callers ask on a schedule: `kido close-window` once
// per finishing subagent, and the sidebar's reaper (internal/reap) on
// every poll. One definition of focus for both is also the point - a
// window the linger helper refuses to close must be one the reaper
// refuses to close, or the refusal buys the user nothing.
func WindowFocused(panes []Pane, windowID string) bool {
	for _, p := range panes {
		if p.WindowID == windowID && p.Watched() {
			return true
		}
	}
	return false
}

// LastWindow reports whether windowID is the only window of its session.
// Closing it would destroy the session - taking every pane in it, and
// detaching every client attached to it - so neither `kido close-window`
// nor the reaper (internal/reap) ever does, whatever else they think of
// the window.
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

// LastPane reports whether windowID has exactly one pane. Combined with
// LastWindow, this is the guard killTargetPane (cmd/kido/control.go)
// needs: killing a window's only pane closes the window as tmux's own
// side effect, so that is only dangerous when the window is also its
// session's only one - a window sharing its pane with another loses
// nothing by it.
func LastPane(panes []Pane, windowID string) bool {
	n := 0
	for _, p := range panes {
		if p.WindowID == windowID {
			n++
		}
	}
	return n <= 1
}

// KillWindow destroys windowID. A window that is already gone - closed by
// its own linger helper, or by another kido's reaper a moment earlier -
// is an error from tmux and nothing more: every caller here is one of
// several processes racing to close the same window, and losing that race
// is the expected outcome, not a failure.
func KillWindow(windowID string) error {
	_, err := run("kill-window", "-t", windowID)
	return err
}

// KillPane destroys paneID, leaving any other pane in its window alone -
// unlike KillWindow, which takes every pane in the window with it.
// Killing a window's last pane closes the window as tmux's own
// consequence of that, not anything this function does differently.
func KillPane(paneID string) error {
	_, err := run("kill-pane", "-t", paneID)
	return err
}

// SubagentMark and SubagentRunID are the two halves of the mark's value,
// kept together here - next to the option name itself - so the one token
// anything parses cannot drift away from the code that writes it: the
// producer is kido spawn and the consumer is internal/reap's sweep, and
// they have no other file in common.
//
// The rest is free text for a human reading `tmux show-options -w`. A
// missing or malformed "run=" token (an older kido's mark, or one
// hand-set by a test) yields "", and a sweep still works without it - it
// just has nothing to record an outcome against.
func SubagentMark(runID, parentInstance string, depth int) string {
	return fmt.Sprintf("run=%s parent=%s depth=%d", runID, parentInstance, depth)
}

func SubagentRunID(info string) string {
	for _, field := range strings.Fields(info) {
		if id, ok := strings.CutPrefix(field, "run="); ok {
			return id
		}
	}
	return ""
}

// MarkSubagent sets SubagentOption on windowID to info, which is how kido
// spawn tells the reaper that this window is one it created and may close
// (see internal/reap). info is what SubagentMark builds; internal/reap
// reads the run id back out of it to record a run's outcome as Died when
// it closes the window without one already recorded.
func MarkSubagent(windowID, info string) error {
	_, err := run("set-option", "-w", "-t", windowID, SubagentOption, info)
	return err
}
