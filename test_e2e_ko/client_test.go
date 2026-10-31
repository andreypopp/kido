package ko_test

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"github.com/gorilla/websocket"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const paneX = 25

func paneText(line string) string {
	if cells := []rune(line); len(cells) > paneX {
		return string(cells[paneX:])
	}
	return ""
}

type control struct {
	cmd   *exec.Cmd
	input io.WriteCloser
	lines chan string
	done  chan error
	stop  chan struct{}
	lock  sync.Mutex
}

type terminal struct {
	control                          *control
	t                                *testing.T
	bin, dir, socket, state, pidfile string
	env                              []string
	executable                       string
	arguments                        []string
}

func newTerminal(t *testing.T, state string, extended bool) *terminal {
	t.Helper()
	key, err := exec.Command(filepath.Join(root, "scripts/install-tmux-fork.sh"), "--print-build-key").Output()
	if err != nil {
		t.Fatal(err)
	}
	expected := strings.TrimSpace(string(key))
	bin := os.Getenv("KIDO_TMUX")
	if bin == "" {
		bin = filepath.Join(root, "build/tmux-fork", expected, "bin/kido-tmux")
	}
	path, err := exec.LookPath(bin)
	if err != nil {
		if os.Getenv("KIDO_E2E_REQUIRED") == "1" {
			t.Fatal(err)
		}
		t.Skip("pinned outer tmux missing: " + err.Error())
	}
	stamp := filepath.Join(filepath.Dir(path), "../share/kido-tmux/BUILD_KEY")
	actual, err := os.ReadFile(stamp)
	if err != nil || strings.TrimSpace(string(actual)) != expected {
		t.Fatalf("outer tmux BUILD_KEY mismatch at %s: rebuild pinned fork", stamp)
	}
	dir, err := os.MkdirTemp("/tmp", "ko-tui-")
	if err != nil {
		t.Fatal(err)
	}
	o := &terminal{t: t, bin: path, dir: dir, socket: filepath.Join(dir, "tmux"), state: state, pidfile: filepath.Join(dir, "pid"), executable: koBin}
	o.env = append(testEnv(dir), "SHELL=/bin/sh", "TERM=xterm-256color")
	o.tmux("-f", "/dev/null", "new-session", "-d", "-s", "outer", "-x", "120", "-y", "30", "/bin/sh")
	o.tmux("pipe-pane", "-t", "outer:0.0", "cat > "+quote(filepath.Join(dir, "output")))
	t.Cleanup(func() {
		if t.Failed() {
			data, _ := os.ReadFile(filepath.Join(dir, "output"))
			if len(data) > 12000 {
				data = data[len(data)-12000:]
			}
			t.Logf("outer output: %q", data)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, o.bin, "-S", o.socket, "kill-server")
		cmd.Env = o.env
		_ = cmd.Run()
		if ctl := o.control; ctl != nil {
			close(ctl.stop)
			ctl.input.Close()
			select {
			case <-ctl.done:
			case <-ctx.Done():
				ctl.cmd.Process.Kill()
				t.Error("outer control did not exit")
			}
		}
		os.RemoveAll(dir)
	})
	o.tmux("set-option", "-g", "status", "off")
	o.tmux("set-option", "-w", "-t", "outer:0", "window-size", "manual")
	mode := "off"
	if extended {
		mode = "on"
	}
	o.tmux("set-option", "-s", "extended-keys", mode)
	o.tmux("set-option", "-s", "extended-keys-format", "csi-u")

	cmd := exec.Command(o.bin, "-u", "-S", o.socket, "-C", "attach-session", "-f", "no-output,ignore-size", "-t", "outer")
	cmd.Env = o.env
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	ctl := &control{cmd: cmd, input: input, lines: make(chan string, 100), done: make(chan error, 1), stop: make(chan struct{})}
	go func() {
		scanner := bufio.NewScanner(stdout)
		defer func() { close(ctl.lines); ctl.done <- cmd.Wait() }()
		for scanner.Scan() {
			select {
			case ctl.lines <- scanner.Text():
			case <-ctl.stop:
				return
			}
		}
	}()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	ready := false
	for !ready {
		select {
		case line, ok := <-ctl.lines:
			if !ok {
				t.Fatal("outer control client closed")
			}
			ready = strings.HasPrefix(line, "%end ")
		case <-deadline.C:
			t.Fatal("outer control client did not attach")
		}
	}
	o.control = ctl
	return o
}
func (o *terminal) tmux(args ...string) string {
	o.t.Helper()
	if ctl := o.control; ctl != nil && len(args) > 0 && (args[0] == "capture-pane" || args[0] == "display-message") {
		ctl.lock.Lock()
		defer ctl.lock.Unlock()
		quoted := make([]string, len(args))
		for i, arg := range args {
			quoted[i] = "\"" + strings.ReplaceAll(strings.ReplaceAll(arg, `\`, `\\`), `"`, `\"`) + "\""
		}
		if _, err := fmt.Fprintln(ctl.input, strings.Join(quoted, " ")); err != nil {
			o.t.Fatal(err)
		}
		timer := time.NewTimer(5 * time.Second)
		defer timer.Stop()
		var output strings.Builder
		active := false
		for {
			select {
			case line, ok := <-ctl.lines:
				if !ok {
					o.t.Fatal("outer control closed")
				}
				if strings.HasPrefix(line, "%begin ") {
					active = true
				} else if active && strings.HasPrefix(line, "%end ") {
					return output.String()
				} else if active && strings.HasPrefix(line, "%error ") {
					o.t.Fatalf("outer control %v: %s", args, output.String())
				} else if active {
					output.WriteString(line)
					output.WriteByte('\n')
				}
			case <-timer.C:
				o.t.Fatalf("outer control timeout: %v", args)
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, o.bin, append([]string{"-u", "-S", o.socket}, args...)...)
	cmd.Env = o.env
	out, err := cmd.CombinedOutput()
	if err != nil {
		o.t.Fatalf("outer tmux %v: %v %s", args, err, out)
	}
	return string(out)
}
func (o *terminal) screen() string { return o.tmux("capture-pane", "-p", "-t", "outer:0.0") }
func (o *terminal) wait(check func() bool, what string) {
	o.t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		if check() {
			return
		}
		select {
		case <-deadline.C:
			o.t.Fatalf("wait for %s; screen:\n%s", what, o.screen())
		case <-tick.C:
		}
	}
}
func (o *terminal) contains(text string) {
	o.t.Helper()
	o.wait(func() bool { return strings.Contains(o.screen(), text) }, text)
}
func (o *terminal) raw(text string) { o.tmux("send-keys", "-t", "outer:0.0", "-l", "--", text) }
func (o *terminal) chord(code int)  { o.raw(fmt.Sprintf("\x1b[%d;6u", code)) }
func (o *terminal) attach(pager string) {
	o.t.Helper()
	pagerEnv := "PAGER=" + quote(pager)
	if pager == "" {
		pagerEnv = "-u PAGER LESS=-RiF"
	}
	program := quote(o.executable)
	for _, arg := range o.arguments {
		program += " " + quote(arg)
	}
	command := fmt.Sprintf("/bin/sh -c %s; printf '\\nKO-DETACHED\\n'", quote(fmt.Sprintf("echo $$ > %s; exec env %s %s --server %s", quote(o.pidfile), pagerEnv, program, quote(o.state))))
	o.raw(command)
	o.tmux("send-keys", "-t", "outer:0.0", "Enter")
}
func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
func (o *terminal) serverPID() int {
	o.t.Helper()
	server, err := strconv.Atoi(strings.TrimSpace(o.tmux("display-message", "-p", "#{pid}")))
	if err != nil {
		o.t.Fatal(err)
	}
	return server
}
func (o *terminal) clientPID() int {
	o.t.Helper()
	data, err := os.ReadFile(o.pidfile)
	if err != nil {
		o.t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		o.t.Fatal(err)
	}
	return pid
}
func (o *terminal) detach() { o.t.Helper(); o.chord(113); o.contains("KO-DETACHED") }
func (s *server) text(pane, text string) {
	s.request("POST", "/panes/"+pane+"/input", []any{"text", base64.StdEncoding.EncodeToString([]byte(text))}, 200, nil)
}
func pagerFixture(t *testing.T, dir string) (string, string) {
	t.Helper()
	path := filepath.Join(dir, "pager")
	record := filepath.Join(dir, "pager-path")
	script := "#!/bin/sh\nprintf '%s' \"$1\" > " + quote(record) + "\nprintf '\\nPAGER-OPEN\\n'\nread answer\n"
	if err := os.WriteFile(path, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	return path, record
}

func TestClientLifecycle(t *testing.T) {
	t.Parallel()
	s := start(t)
	p1 := s.pane("printf '\033]0;one\007pane-one\\n'; exec /bin/sh")
	s.pane("printf '\033]0;two\007pane-two\\n'; exec /bin/sh")
	o := newTerminal(t, s.dir, true)
	pager, record := pagerFixture(t, o.dir)
	o.attach(pager)
	o.contains("pane-one")
	o.wait(func() bool {
		return strings.TrimSpace(o.tmux("display-message", "-p", "-t", "outer:0.0", "#{mouse_standard_flag},#{mouse_sgr_flag}")) == "1,1"
	}, "outer mouse reporting on")
	o.contains("1 one")
	o.chord(115)
	o.wait(func() bool { return !strings.Contains(o.screen(), "1 one") }, "sidebar hidden")
	o.chord(115)
	o.contains("1 one")
	o.raw("\x1b[1;6B")
	o.contains("pane-two")
	o.raw("\x1b[1;6A")
	o.contains("pane-one")
	o.raw("\x1b[<0;3;2M\x1b[<0;3;2m")
	o.contains("pane-two")
	o.chord(101)
	o.contains("PAGER-OPEN")
	data, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	file := string(data)
	st, err := os.Stat(file)
	if err != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("pager file mode: %v %v", st, err)
	}
	o.raw("done")
	o.tmux("send-keys", "-t", "outer:0.0", "Enter")
	o.contains("pane-two")
	o.wait(func() bool { _, err := os.Stat(file); return os.IsNotExist(err) }, "pager temporary file removed after exit")
	o.chord(110)
	o.wait(func() bool {
		var rows []map[string]any
		s.request("GET", "/panes", nil, 200, &rows)
		return len(rows) == 3
	}, "new pane")
	o.raw("\x1b[100;5u")
	o.contains("†")
	o.raw("\x1b[100;5u")
	o.wait(func() bool {
		var rows []map[string]any
		s.request("GET", "/panes", nil, 200, &rows)
		return len(rows) == 2
	}, "remove dead pane")
	o.detach()
	s.text(p1, "printf 'AFTER-DETACH\\n'\n")
	o.attach("")
	o.contains("AFTER-DETACH")
	o.chord(101)
	o.contains("(END)")
	o.raw("q")
	o.wait(func() bool {
		return strings.TrimSpace(o.tmux("display-message", "-p", "-t", "outer:0.0", "#{mouse_standard_flag},#{mouse_sgr_flag}")) == "1,1"
	}, "outer mouse reporting on")
	signalOwned(t, o.serverPID(), syscall.SIGHUP, o.clientPID())
	o.contains("KO-DETACHED")
}

func TestClientHistoryAndTop(t *testing.T) {
	t.Parallel()
	s := start(t)
	historyPane := s.pane("seq 300; printf '\033]0;history\007HISTORY-READY\\n'; exec cat")
	o := newTerminal(t, s.dir, true)
	pager, record := pagerFixture(t, o.dir)
	o.attach(pager)
	o.contains("HISTORY-READY")
	o.raw("\x1b[<64;40;5M")
	o.wait(func() bool { return !strings.Contains(o.screen(), "HISTORY-READY") }, "wheel moved viewport")
	o.raw("x")
	o.contains("HISTORY-READY")
	o.detach()
	o.attach(pager)
	o.contains("HISTORY-READY")
	o.chord(101)
	o.contains("PAGER-OPEN")
	path, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(string(path))
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, line := range strings.Split(string(data), "\n") {
		n, e := strconv.Atoi(strings.TrimSpace(line))
		if e == nil && n >= 1 && n <= 300 {
			count++
		}
	}
	if count != 300 {
		t.Fatalf("history has %d numeric lines, want 300", count)
	}
	o.raw("done")
	o.tmux("send-keys", "-t", "outer:0.0", "Enter")
	o.contains("HISTORY-READY")
	o.detach()
	s.request("DELETE", "/panes/"+historyPane, nil, 200, nil)
	command := "seq 300; top; printf 'AFTER-TOP\\n'; exec /bin/sh"
	topPane := s.pane(command)
	o.attach(pager)
	o.contains("PID")
	o.detach()
	o.attach(pager)
	o.contains("PID")
	o.raw("q")
	o.contains("AFTER-TOP")
	o.chord(101)
	o.contains("PAGER-OPEN")
	path, _ = os.ReadFile(record)
	data, _ = os.ReadFile(string(path))
	if !strings.Contains(string(data), "299") {
		t.Fatal("top round trip lost primary history")
	}
	o.raw("done")
	o.tmux("send-keys", "-t", "outer:0.0", "Enter")
	o.contains("AFTER-TOP")
	client, server := o.clientPID(), o.serverPID()
	shellPID, err := strconv.Atoi(strings.TrimSpace(o.tmux("display-message", "-p", "-t", "outer:0.0", "#{pane_pid}")))
	if err != nil {
		t.Fatal(err)
	}
	shellStopped, clientStopped := false, false
	t.Cleanup(func() {
		if clientStopped {
			signalOwned(t, server, syscall.SIGCONT, client)
		}
		if shellStopped {
			signalOwned(t, server, syscall.SIGCONT, shellPID)
		}
	})
	// An interactive shell takes the tty back when its child stops.
	signalOwned(t, server, syscall.SIGSTOP, shellPID, client)
	shellStopped = true
	clientStopped = true
	producer := "for i in range(100000): print('H%05d'%i+'x'*70)"
	s.text(topPane, "python3 -c "+quote(producer)+"; printf 'FLOOD-%s\\n' DONE\n")
	o.wait(func() bool {
		return strings.Contains(s.request("GET", "/panes/"+topPane+"/screen?format=plain", nil, 200, nil), "FLOOD-DONE")
	}, "output while client is stopped")
	signalOwned(t, server, syscall.SIGCONT, client)
	clientStopped = false
	o.contains("FLOOD-DONE")
	o.raw("\x1b[<64;40;5M")
	o.contains("H99970")
	o.chord(113)
	o.wait(func() bool {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, "ps", "-o", "stat=", "-p", strconv.Itoa(client)).Output()
		return err != nil || strings.HasPrefix(strings.TrimSpace(string(out)), "Z")
	}, "client exits before its shell resumes")
	signalOwned(t, server, syscall.SIGCONT, shellPID)
	shellStopped = false
	o.contains("KO-DETACHED")
}

func TestClientWinchAndOuterModes(t *testing.T) {
	t.Parallel()
	s := start(t)
	counter := filepath.Join(s.dir, "winch")
	py := "import os,signal\nn=0\ndef changed(*args):\n global n\n n+=1\n open(" + strconv.Quote(counter) + ",'w').write(str(n))\nsignal.signal(signal.SIGWINCH,changed)\nopen(" + strconv.Quote(counter) + ",'w').write('0')\nprint('WINCH-READY',flush=True)\nwhile True: signal.pause()"
	s.pane("exec python3 -c " + quote(py))
	o := newTerminal(t, s.dir, true)
	o.wait(func() bool { _, e := os.Stat(counter); return e == nil }, "WINCH handler")
	flags := "#{pane_private_modes}"
	o.raw("printf '\\033[?1003h\\033[?1006h\\033[?1004h\\033[?2004h\\033[?25l'")
	o.tmux("send-keys", "-t", "outer:0.0", "Enter")
	o.wait(func() bool {
		m := "," + strings.TrimSpace(o.tmux("display-message", "-p", "-t", "outer:0.0", flags)) + ","
		return strings.Contains(m, ",1003,") && strings.Contains(m, ",1004,") && strings.Contains(m, ",1006,") && strings.Contains(m, ",2004,") && !strings.Contains(m, ",25,")
	}, "pre-existing outer modes")
	before := o.tmux("display-message", "-p", "-t", "outer:0.0", flags)
	o.attach("cat")
	o.contains("WINCH-READY")
	o.wait(func() bool { b, _ := os.ReadFile(counter); return string(b) == "1" }, "one attach resize")
	o.detach()
	after := o.tmux("display-message", "-p", "-t", "outer:0.0", flags)
	if before != after {
		t.Fatalf("outer modes changed: %q -> %q", before, after)
	}
	o.attach("cat")
	o.contains("WINCH-READY")
	o.chord(115)
	o.wait(func() bool { b, _ := os.ReadFile(counter); return string(b) == "2" }, "one real width change and no same-size attach resize")
	o.tmux("resize-window", "-t", "outer:0", "-x", "130", "-y", "31")
	o.wait(func() bool { b, _ := os.ReadFile(counter); return string(b) == "3" }, "one outer terminal resize")
	o.tmux("resize-window", "-t", "outer:0", "-x", "130", "-y", "31")
	o.tmux("resize-window", "-t", "outer:0", "-x", "131", "-y", "31")
	o.wait(func() bool { b, _ := os.ReadFile(counter); return string(b) == "4" }, "same-size resize sends no WINCH")
	o.detach()
}

func TestClientAttachOrStartAndWarning(t *testing.T) {
	t.Parallel()
	dir, err := os.MkdirTemp("/tmp", "ko-auto-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, "socket"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	stale.SetUnlinkOnClose(false)
	stale.Close()
	o := newTerminal(t, dir, false)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, koBin, "kill-server", "--server", dir)
		cmd.Env = o.env
		_ = cmd.Run()
	})
	peer := newTerminal(t, dir, true)
	replyPath := filepath.Join(peer.dir, "kitty-reply")
	probe := "import os,tty,select\ntty.setraw(0)\nos.write(1,b'\\x1b[?u')\nr,_,_=select.select([0],[],[],0.15)\ndata=os.read(0,1024) if r else b''\nopen(" + strconv.Quote(replyPath) + ",'w').write(data.hex())"
	peer.tmux("new-window", "-d", "-n", "key-probe", "python3 -c "+quote(probe))
	peer.wait(func() bool { _, err := os.Stat(replyPath); return err == nil }, "kitty query completes")
	reply, err := os.ReadFile(replyPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("tmux extended-keys=on: kitty query=1b5b3f75 reply=%q", reply)
	o.attach("cat")
	peer.attach("cat")
	o.contains("ko: extended keys were not confirmed")
	peer.chord(115)
	peer.wait(func() bool { return !strings.Contains(peer.screen(), "extended keys were not confirmed") }, "extended peer removes the warning after a distinct chord")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", filepath.Join(dir, "socket"))
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	o.chord(113)
	o.contains("KO-DETACHED")
	peer.chord(113)
	peer.contains("KO-DETACHED")
	cmd := exec.CommandContext(ctx, koBin, "kill-server", "--server", dir)
	cmd.Env = o.env
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("kill autostarted server: %v %s", err, out)
	}
}

func click(col int) string {
	return hex.EncodeToString([]byte(fmt.Sprintf("\x1b[<0;%d;5M", col)))
}

func TestClientModesBeforeAttachAndUnattachedDA1(t *testing.T) {
	t.Parallel()
	s := start(t)
	py := "import os,select,tty\ntty.setraw(0)\nos.write(1,b'\\x1b[c')\nif not select.select([0],[],[],3)[0]: raise RuntimeError('no DA1')\nr=os.read(0,1024)\nprint('DA1-ANSWERED' if r.startswith(b'\\x1b[?') else repr(r),flush=True)\nos.write(1,b'\\x1b[?1h\\x1b[?1000h\\x1b[?1002h\\x1b[?1004h\\x1b[?1006h\\x1b[?2004h\\x1b[=3;1uMODE-READY')\nwhile True:\n r=os.read(0,1024)\n print('INPUT:'+r.hex(),end='\\r\\n',flush=True)"
	pane := s.pane("exec python3 -c " + quote(py))
	o := newTerminal(t, s.dir, true)
	o.wait(func() bool {
		return strings.Contains(s.request("GET", "/panes/"+pane+"/screen?format=plain&history=all", nil, 200, nil), "MODE-READY")
	}, "server answers DA1 without a view")
	o.attach("cat")
	o.contains("DA1-ANSWERED")
	o.contains("MODE-READY")
	o.raw("\x1b[O")
	o.contains("INPUT:1b5b4f")
	o.raw("\x1b[I")
	o.contains("INPUT:1b5b49")
	o.raw("\x1b[A")
	o.contains("INPUT:1b5b313b313a3141")
	o.raw("\x1b[<0;40;5M")
	o.contains(click(40 - paneX))
	o.raw(fmt.Sprintf("\x1b[<0;%d;5M\x1b[<0;%d;5M", paneX, paneX+1))
	o.contains(click(1))
	if strings.Contains(o.screen(), click(0)) {
		t.Fatal("a click on the bar reached the pane")
	}
	o.raw("\x1b[200~abc\x1b[201~")
	o.contains("INPUT:1b5b3230307e6162631b5b3230317e")
	o.detach()
	o.attach("cat")
	o.contains("MODE-READY")
	o.raw("\x1b[A")
	o.wait(func() bool { return strings.Count(o.screen(), "INPUT:1b5b313b313a3141") == 2 }, "kitty mode input survives reattach")
	o.detach()
}

func interactiveFixture(s *server) string {
	program := "import os,tty\ntty.setraw(0)\nos.write(1,b'\\x1b]0;fixture\\x07BASE')\nwhile True:\n c=os.read(0,1)\n if c==b'o': os.write(1,b'\\r\\nOUTPUT-WITHOUT-INPUT\\r\\n')\n if c==b'f':\n  w,h=os.get_terminal_size()\n  for y in range(h): os.write(1,('\\x1b[%d;1H'%(y+1)+'P'*w).encode())\n if c==b'h': os.write(1,b'\\x1b[?2026h\\x1b[1;1HHOLD-CHANGED')\n if c==b'r': os.write(1,b'\\x1b[?2026l')"
	return s.pane("exec python3 -u -c " + quote(program))
}

const quietWindow = 200 * time.Millisecond

func (o *terminal) quiet() {
	o.t.Helper()
	size := int64(-1)
	changed := time.Now()
	o.wait(func() bool {
		st, err := os.Stat(filepath.Join(o.dir, "output"))
		if err != nil {
			return false
		}
		if st.Size() != size {
			size = st.Size()
			changed = time.Now()
		}
		return time.Since(changed) >= quietWindow
	}, "terminal output becomes quiet")
}
func TestClientOutputWithoutOuterInput(t *testing.T) {
	t.Parallel()
	s := start(t)
	pane := s.pane("printf '\\033]0;fixture\\007'; exec /bin/sh")
	o := newTerminal(t, s.dir, true)
	o.attach("cat")
	o.contains("1 fixture")
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("server screen: %s", s.request("GET", "/panes/"+pane+"/screen?format=plain", nil, 200, nil))
		}
	})
	o.quiet()
	o.raw("echo abc")
	o.tmux("send-keys", "-t", "outer:0.0", "Enter")
	o.wait(func() bool {
		for _, line := range strings.Split(o.screen(), "\n") {
			if strings.TrimSpace(paneText(line)) == "abc" {
				return true
			}
		}
		return false
	}, "complete echo output without another input")
	s.text(pane, "printf 'POST-%s\\n' OUTPUT\n")
	o.contains("POST-OUTPUT")
	s.text(pane, "printf 'COLORS:%s\\n' \"$(tput colors)\"\n")
	o.contains("COLORS:256")
	o.detach()
}
func TestClientInitialCursorAndSynchronizedOutput(t *testing.T) {
	t.Parallel()
	s := start(t)
	pane := interactiveFixture(s)
	o := newTerminal(t, s.dir, true)
	o.attach("cat")
	o.contains("BASE")
	o.wait(func() bool {
		data, _ := os.ReadFile(filepath.Join(o.dir, "output"))
		first := strings.Index(string(data), "BASE")
		return first >= 0 && strings.Contains(string(data[first+4:]), "\x1b[?2026l")
	}, "first pane frame completes")
	data, err := os.ReadFile(filepath.Join(o.dir, "output"))
	if err != nil {
		t.Fatal(err)
	}
	first := strings.Index(string(data), "BASE")
	if first < 0 {
		t.Fatal("first pane frame missing")
	}
	firstFrame := string(data[first+4:])
	if next := strings.Index(firstFrame, "\x1b[?2026l"); next >= 0 {
		firstFrame = firstFrame[:next]
	}
	if strings.Contains(firstFrame, "\x1b[?25l") {
		t.Fatal("first pane frame leaves its cursor hidden")
	}
	o.wait(func() bool {
		return strings.TrimSpace(o.tmux("display-message", "-p", "-t", "outer:0.0", "#{cursor_flag}:#{cursor_x}:#{cursor_y}")) == fmt.Sprintf("1:%d:0", paneX+4)
	}, "visible initial pane cursor at pane column 4")
	s.text(pane, "h")
	deadline := time.NewTimer(400 * time.Millisecond)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for !strings.Contains(o.screen(), "HOLD-CHANGED") {
		select {
		case <-deadline.C:
			t.Fatal("synchronized output did not expire within 400 ms")
		case <-tick.C:
		}
	}
	o.detach()
}
func TestClientSidebarOwnership(t *testing.T) {
	t.Parallel()
	s := start(t)
	pane := interactiveFixture(s)
	o := newTerminal(t, s.dir, true)
	o.attach("cat")
	o.contains("BASE")
	for y, line := range strings.Split(o.screen(), "\n")[:29] {
		if cells := []rune(line); len(cells) < paneX || cells[paneX-1] != '│' {
			t.Fatalf("no bar left of the pane in row %d: %q", y, line)
		}
	}
	o.chord(115)
	s.text(pane, "f")
	o.wait(func() bool {
		o.raw("z")
		lines := strings.Split(o.screen(), "\n")
		return len(lines) > 3 && strings.HasPrefix(lines[3], strings.Repeat("P", 24))
	}, "pane draws across the hidden sidebar")
	if strings.Contains(o.screen(), "│") {
		t.Fatal("bar drawn while the sidebar is hidden")
	}
	o.chord(115)
	o.contains("1 fixture")
	for y, line := range strings.Split(o.screen(), "\n") {
		if len(line) > 24 {
			line = line[:24]
		}
		text := strings.TrimSpace(line)
		if y == 0 && text == "1 fixture" {
			continue
		}
		if strings.HasPrefix(text, "ko:") {
			continue
		}
		if text != "" {
			t.Fatalf("stale sidebar cells in row %d: %q", y, line)
		}
	}
	narrow := newTerminal(t, s.dir, false)
	narrow.tmux("resize-window", "-t", "outer:0", "-x", "80", "-y", "30")
	narrow.attach("cat")
	narrow.contains("extended keys were not confirmed")
	narrow.contains("1 fixture")
	narrow.detach()
	o.detach()
}

func TestClientUnknownCursorModeAndKeyboardStack(t *testing.T) {
	t.Parallel()
	s := start(t)
	interactiveFixture(s)
	o := newTerminal(t, s.dir, true)
	proxy := filepath.Join(o.dir, "terminal-proxy")
	source := `#!/usr/bin/env python3
import fcntl,os,pty,re,select,struct,sys,termios,tty,time
saved=termios.tcgetattr(0)
pid,fd=pty.fork()
if pid==0:
 w,h=os.get_terminal_size(1)
 fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',h,w,0,0))
 os.execv(sys.argv[1],[sys.argv[1]]+sys.argv[2:])
tty.setraw(0)
pending=b''
try:
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  ready,_,_=select.select([0,fd],[],[],min(1,deadline-time.monotonic()))
  if 0 in ready: os.write(fd,os.read(0,65536))
  if fd in ready:
   try: data=os.read(fd,65536)
   except OSError: break
   if not data: break
   pending+=data
   if b'\x1b[?25$p' in pending:
    os.write(fd,b'\x1b[?25;0$y')
    pending=pending.replace(b'\x1b[?25$p',b'')
   if b'\x1b[?u' in pending:
    os.write(fd,b'\x1b[?0u')
    pending=pending.replace(b'\x1b[?u',b'')
   last=pending.rfind(b'\x1b')
   if last>=0 and not re.fullmatch(rb'\x1b\[[0-?]*[ -/]*[@-~]',pending[last:]) and len(pending)-last<16:
    os.write(1,pending[:last]);pending=pending[last:]
   else: os.write(1,pending);pending=b''
finally:
 if pending: os.write(1,pending)
 termios.tcsetattr(0,termios.TCSANOW,saved)
 os.close(fd)
 deadline=time.monotonic()+2
 killed=False
 while True:
  done,_=os.waitpid(pid,os.WNOHANG)
  if done: break
  if time.monotonic()>=deadline:
   if killed: raise RuntimeError('client did not exit')
   os.kill(pid,9);killed=True;deadline=time.monotonic()+1
  select.select([],[],[],0.01)
`
	if err := os.WriteFile(proxy, []byte(source), 0700); err != nil {
		t.Fatal(err)
	}
	o.executable = proxy
	o.arguments = []string{koBin}
	o.attach("cat")
	o.contains("BASE")
	o.detach()
	if got := strings.TrimSpace(o.tmux("display-message", "-p", "-t", "outer:0.0", "#{cursor_flag}")); got != "1" {
		t.Errorf("unknown saved cursor mode restored hidden: %s", got)
	}
	data, err := os.ReadFile(filepath.Join(o.dir, "output"))
	if err != nil {
		t.Fatal(err)
	}
	pushes := len(regexp.MustCompile("\x1b\\[>[0-9;]*u").FindAll(data, -1))
	pops := len(regexp.MustCompile("\x1b\\[<[0-9]*u").FindAll(data, -1))
	if pushes != 1 || pops != pushes {
		t.Fatalf("kitty stack: pushes=%d pops=%d, want one owned entry", pushes, pops)
	}
}

func TestClientDifferentSizesAndSignalCleanup(t *testing.T) {
	t.Parallel()
	s := start(t)
	interactiveFixture(s)
	large := newTerminal(t, s.dir, true)
	large.attach("cat")
	large.contains("BASE")
	small := newTerminal(t, s.dir, true)
	small.tmux("resize-window", "-t", "outer:0", "-x", "85", "-y", "20")
	small.attach("cat")
	small.contains("BASE")
	large.contains("BASE")
	small.detach()
	large.detach()
	o := newTerminal(t, s.dir, true)
	for _, sig := range []syscall.Signal{syscall.SIGHUP, syscall.SIGTERM} {
		before := o.tmux("display-message", "-p", "-t", "outer:0.0", "#{pane_private_modes}")
		o.attach("cat")
		o.contains("BASE")
		data, err := os.ReadFile(o.pidfile)
		if err != nil {
			t.Fatal(err)
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
		if err != nil {
			t.Fatal(err)
		}
		signalOwned(t, o.serverPID(), sig, pid)
		o.contains("KO-DETACHED")
		after := o.tmux("display-message", "-p", "-t", "outer:0.0", "#{pane_private_modes}")
		if before != after {
			t.Errorf("signal %v: modes before %q after %q", sig, before, after)
		}
	}
	data, err := os.ReadFile(filepath.Join(o.dir, "output"))
	if err != nil {
		t.Fatal(err)
	}
	push := len(regexp.MustCompile("\x1b\\[>[0-9;]*u").FindAll(data, -1))
	pop := len(regexp.MustCompile("\x1b\\[<[0-9]*u").FindAll(data, -1))
	if push != pop {
		t.Errorf("signal cleanup kitty pushes=%d pops=%d", push, pop)
	}
}

func TestClientSidebarRelease(t *testing.T) {
	t.Parallel()
	s := start(t)
	for _, name := range []string{"A", "B", "C"} {
		s.pane("printf '\\033]0;row" + name + "\\007SELECTED-" + name + "'; exec cat")
	}
	o := newTerminal(t, s.dir, true)
	o.attach("cat")
	o.contains("rowC")
	o.chord(115)
	o.chord(115)
	o.raw("\x1b[1;1:1B\x1b[1;1:3B\r")
	o.contains("SELECTED-B")
	o.detach()
}
func TestClientWarningMouseBounds(t *testing.T) {
	t.Parallel()
	s := start(t)
	for i := 1; i <= 5; i++ {
		program := "import os,tty\ntty.setraw(0)\nos.write(1,b'\\x1b[?1000h\\x1b[?1006hSELECTED-" + strconv.Itoa(i) + "')\nb=b''\nwhile not b.endswith(b'x'): b+=os.read(0,4096)\nos.write(1,('INPUT:'+b.hex()).encode())\nwhile True: os.read(0,4096)"
		s.pane("exec python3 -u -c " + quote(program))
	}
	o := newTerminal(t, s.dir, false)
	o.tmux("resize-window", "-t", "outer:0", "-x", "120", "-y", "1")
	o.attach("cat")
	o.contains("extended keys were not confirmed")
	o.raw("\x1b[<0;30;1M")
	o.tmux("resize-window", "-t", "outer:0", "-x", "120", "-y", "5")
	o.contains("SELECTED-1")
	o.raw("\x1b[<0;1;5M\x1b[<0;30;5M")
	o.raw("x")
	o.contains("INPUT:78")
	o.contains("SELECTED-1")
	o.detach()
}

func TestClientSnapshotInterruption(t *testing.T) {
	t.Parallel()
	s := start(t)
	interactiveFixture(s)
	for _, marker := range []bool{false, true} {
		dir, err := os.MkdirTemp("/tmp", "ko-proxy-")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.RemoveAll(dir) })
		listener, err := net.Listen("unix", filepath.Join(dir, "socket"))
		if err != nil {
			t.Fatal(err)
		}
		transport := &http.Transport{DialContext: s.dial}
		proxy := &httputil.ReverseProxy{Director: func(r *http.Request) { r.URL.Scheme = "http"; r.URL.Host = "ko" }, Transport: transport}
		handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasSuffix(r.URL.Path, "/view") {
				proxy.ServeHTTP(w, r)
				return
			}
			dialer := websocket.Dialer{NetDialContext: s.dial, HandshakeTimeout: 5 * time.Second}
			headers := http.Header{"Ko-Protocol": []string{"1"}, "Ko-Vt": []string{s.vt}}
			headers.Set("Ko-Protocol", r.Header.Get("Ko-Protocol"))
			headers.Set("Ko-Client", r.Header.Get("Ko-Client"))
			back, _, err := dialer.Dial("ws://ko"+r.URL.RequestURI(), headers)
			if err != nil {
				return
			}
			defer back.Close()
			upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
			front, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer front.Close()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() {
				defer cancel()
				defer back.Close()
				for {
					kind, data, err := front.ReadMessage()
					if err != nil {
						return
					}
					if back.WriteMessage(kind, data) != nil {
						return
					}
				}
			}()
			injected := false
			for ctx.Err() == nil {
				replaced := false
				kind, data, err := back.ReadMessage()
				if err != nil {
					return
				}
				if !injected && kind == websocket.BinaryMessage && len(data) > 50 && data[0] == 2 {
					first := append([]byte(nil), data[:40]...)
					first[9] = 1
					if front.WriteMessage(kind, first) != nil {
						return
					}
					if marker {
						if front.WriteMessage(websocket.TextMessage, []byte(`["marked",{"offset":0,"marker":["resize",{"cols":37,"rows":9}]}]`)) != nil {
							return
						}
					}
					if marker {
						replaced = true
						tail := append([]byte(nil), data[:11]...)
						tail[9] = data[9] &^ byte(1)
						data = append(tail, data[40:]...)
					}
					injected = true
				}
				if front.WriteMessage(kind, data) != nil {
					return
				}
				if replaced {
					record := append(make([]byte, 9), []byte("\x1b[1;50HR")...)
					record[0] = 1
					if front.WriteMessage(websocket.BinaryMessage, record) != nil {
						return
					}
				}
			}
		})
		server := &http.Server{Handler: handler}
		go server.Serve(listener)
		t.Cleanup(func() { server.Close(); transport.CloseIdleConnections() })
		o := newTerminal(t, dir, true)
		o.attach("cat")
		o.contains("BASE")
		if marker {
			o.wait(func() bool {
				return strings.TrimSpace(o.tmux("display-message", "-p", "-t", "outer:0.0", "#{cursor_x}")) == strconv.Itoa(paneX+36)
			}, "queued resize applies before following output")
		}
		o.detach()
	}
}

func TestClientDeadPaneLine(t *testing.T) {
	t.Parallel()
	s := start(t)
	fill := "yes '' | head -40; printf last; "
	s.pane(fill + "exit 3")
	s.pane(fill + "kill -TERM $$")
	s.pane("printf 'live\\n'; exec cat")
	o := newTerminal(t, s.dir, true)
	o.attach("cat")
	line := func(text string) {
		o.wait(func() bool {
			lines := strings.Split(o.screen(), "\n")
			for y, l := range lines {
				if strings.HasPrefix(paneText(l), text) {
					if y == 0 || !strings.HasPrefix(paneText(lines[y-1]), "last") {
						t.Fatalf("no program output directly above the line:\n%s", strings.Join(lines, "\n"))
					}
					return true
				}
			}
			return false
		}, text)
	}
	line("[exited 3 \u2014 Ctrl+D to remove]")
	o.raw("\x1b[<0;3;2M\x1b[<0;3;2m")
	line("[killed by SIGTERM \u2014 Ctrl+D to remove]")
	o.raw("\x1b[<0;3;3M\x1b[<0;3;3m")
	o.contains("live")
	o.wait(func() bool { return !strings.Contains(o.screen(), "Ctrl+D") }, "dead line gone after switching away")
	o.detach()
}

func TestClientLegacyShiftedKey(t *testing.T) {
	t.Parallel()
	hx := func(s string) string { return hex.EncodeToString([]byte(s)) }
	cases := []struct {
		name  string
		flags int
		typed string
		want  string
	}{
		{"flags 3, plain colon", 3, ":", hx(":")},
		{"flags 3, plain A", 3, "A", hx("A")},
		{"flags 3, plain É", 3, "É", hx("É")},
		{"flags 3, CSI u colon without text", 3, "\x1b[59;2u", hx(":")},
		{"flags 3, CSI u A without text", 3, "\x1b[97;2u", hx("A")},
		{"flags 3, CSI u ! without text", 3, "\x1b[49;2u", hx("!")},
		{"flags 3, CSI u é without text", 3, "\x1b[233;2u", hx("É")},
		{"flags 3, CSI u with explicit text", 3, "\x1b[97;2;937u", hx("Ω")},
		{"flags 3, Shift+Space", 3, "\x1b[32;2u", hx("\x1b[32;2u")},
		{"flags 3, Shift+Enter", 3, "\x1b[13;2u", hx("\x1b[13;2u")},
		{"flags 3, Alt+Shift+A", 3, "\x1b[97;4u", hx("\x1b[97;4u")},
		{"flags 31, plain colon", 31, ":", hx("\x1b[59:58;2;58u")},
		{"flags 31, plain A", 31, "A", hx("\x1b[97:65;2;65u")},
		{"flags 31, CSI u A without text", 31, "\x1b[97;2u", hx("\x1b[97:65;2;65u")},
		{"legacy pane, plain A", 0, "A", hx("A")},
		{"legacy pane, CSI u A without text", 0, "\x1b[97;2u", hx("A")},
		{"legacy pane, Alt+Shift+A", 0, "\x1b[97;4u", hx("\x1bA")},
		{"legacy pane, Alt+b", 0, "\x1b[98;3u", hx("\x1bb")},
	}
	plan := make([]string, len(cases))
	for i, c := range cases {
		plan[i] = strconv.Itoa(c.flags)
	}
	s := start(t)
	program := "import os,tty\ntty.setraw(0)\nf=[" + strings.Join(plan, ",") + `]
os.write(1,b'\x1b[>%du'%f[0]+b'KEY-READY')
n=0
while True:
 b=os.read(0,4096)
 n+=1
 nxt=b'\x1b[=%d;1u'%f[n] if n<len(f) else b''
 os.write(1,nxt+('\r\nKEY%d:'%n+b.hex()+'\r\n').encode())`
	s.pane("exec python3 -u -c " + quote(program))
	o := newTerminal(t, s.dir, true)
	o.attach("cat")
	o.contains("KEY-READY")
	for i, c := range cases {
		o.raw(c.typed)
		o.contains(fmt.Sprintf("KEY%d:%s\n", i+1, c.want))
	}
	o.detach()
}

func TestClientNvimNormalModeShiftedKeys(t *testing.T) {
	t.Parallel()
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim missing")
	}
	s := start(t)
	file := filepath.Join(s.dir, "typed")
	s.pane("exec nvim -u NONE -i NONE -n " + quote(file))
	o := newTerminal(t, s.dir, true)
	o.attach("cat")
	o.contains("typed")
	insert := func(append, text string) {
		o.raw(append)
		o.contains("-- INSERT --")
		o.raw(text + "\x1b")
		o.wait(func() bool { return !strings.Contains(o.screen(), "-- INSERT --") }, "normal mode")
	}
	insert("A", "x")
	o.raw(":w\r")
	o.wait(func() bool { data, _ := os.ReadFile(file); return string(data) == "x\n" }, "A, x, Esc, :w to write x")
	insert("\x1b[97;2u", "y")
	o.raw("\x1b[59;2uwq\r")
	o.wait(func() bool { data, _ := os.ReadFile(file); return string(data) == "xy\n" }, "CSI u A, y, Esc, CSI u colon, wq to write xy")
	o.detach()
}
