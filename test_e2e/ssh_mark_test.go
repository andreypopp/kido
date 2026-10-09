package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestSSHMark(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	src := `package main
import("bufio"; "fmt"; "os"; "strings"; "time")
func main() {
 if len(os.Args)>1 && os.Args[1]=="-G" {
  if strings.Contains(strings.Join(os.Args," "),"bad-config") { os.Exit(1) }
  if strings.Contains(strings.Join(os.Args," "),"realm") { fmt.Print("user deploy@realm\nhostname next.test\n"); return }
  fmt.Print("user deploy\nhostname example.test\n"); return
 }
 fmt.Print("\x1b]133;C;cmdline=ssh alias\x07")
 sc:=bufio.NewScanner(os.Stdin)
 for sc.Scan() {
  line:=sc.Text()
  switch line {
  case "prompt": <-time.After(1100*time.Millisecond); fmt.Print("\x1b]133;A\x07")
  case "run": fmt.Print("\x1b]133;C;cmdline=sleep 45\x07")
  case "agent": fmt.Print("\x1b]2;Remote Claude\x07\x1b]7501;state=idle:app=claude-code\x07")
  case "quit": fmt.Print("\x1b]7501;state=clear\x07"); return
  default: fmt.Println("received:",line)
  }
 }
}
`
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	fake := filepath.Join(dir, "ssh")
	build := exec.Command("go", "build", "-o", fake, "main.go")
	build.Dir = dir
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build ssh: %v\n%s", err, out)
	}
	h := startPathPrefix(t, "alpha", dir)
	pane := h.newWindow("alpha", "", "bash", "--noprofile", "--norc", "-i")
	h.waitPaneCommand(pane, "bash")
	h.in("send-keys", "-t", pane, fmt.Sprintf("PATH=%s:$PATH %s ssh alias uptime", dir, kidoBin), "Enter")
	h.waitPaneCommand(pane, "ssh")
	mark := func() string { return h.in("show-options", "-p", "-v", "-t", pane, "@kido_ssh") }
	if got := mark(); got != "deploy@example.test" {
		t.Fatalf("ssh mark = %q", got)
	}
	h.waitShellRow("╶◼ssh deploy@example.test", "")
	h.newWindow("alpha", "tail", "cat", "-")
	h.in("send-keys", "-t", pane, "prompt", "Enter")
	h.waitShellRow("╶ ssh deploy@example.test", "")
	h.in("send-keys", "-t", pane, "run", "Enter")
	h.waitShellRow("╶◼ssh deploy@example.test: sleep 45", "")
	h.in("send-keys", "-t", pane, "agent", "Enter")
	h.waitRow("Remote Claude")
	out, rc := h.kidoAs(pane, "pasted remote message", nil, "prompt")
	if rc != 0 {
		t.Fatalf("remote prompt: exit %d\n%s", rc, out)
	}
	h.waitPaneText(pane, "received: pasted remote message")
	h.in("send-keys", "-t", pane, "quit", "Enter")
	h.waitPaneCommand(pane, "bash")
	if got := mark(); got != "deploy@example.test" {
		t.Fatalf("mark after ssh exit = %q", got)
	}
	stale := h.startFeed("alpha")
	stale.waitLast(func(s feedSnapshot) bool {
		for _, item := range feedItems(s.Sessions[0].Nodes) {
			if item.ID == pane {
				return item.Kind == "shell"
			}
		}
		return false
	}, "stale mark with bash ignored")
	h.in("send-keys", "-t", pane, fmt.Sprintf("PATH=%s:$PATH %s ssh -l deploy@realm realm uptime", dir, kidoBin), "Enter")
	h.waitPaneCommand(pane, "ssh")
	if got := mark(); got != "deploy@realm@next.test" {
		t.Fatalf("next ssh mark = %q", got)
	}
	h.waitShellRow("╶◼ssh deploy@realm@next.test", "")
	plain := h.newWindow("alpha", "plain", fake, "alias")
	h.waitPaneCommand(plain, "ssh")
	feed := h.startFeed("alpha")
	feed.waitLast(func(s feedSnapshot) bool {
		for _, item := range feedItems(s.Sessions[0].Nodes) {
			if item.ID == plain {
				return item.Kind == "shell"
			}
		}
		return false
	}, "absolute ssh is a terminal")
	failed := h.newWindow("alpha", "failed-config", "sh", "-c", fmt.Sprintf("PATH=%s:$PATH exec %s ssh bad-config uptime", dir, kidoBin))
	h.waitPaneCommand(failed, "ssh")
	if got := h.in("display-message", "-p", "-t", failed, "#{@kido_ssh}"); got != "" {
		t.Fatalf("failed -G marks pane: %q", got)
	}
	for _, c := range []struct{ name, prefix string }{
		{"failed-mark", "TMUX_PANE=%999999999"},
		{"no-pane", "unset TMUX_PANE;"},
	} {
		p := h.newWindow("alpha", c.name, "sh", "-c", fmt.Sprintf("%s PATH=%s:$PATH exec %s ssh alias uptime", c.prefix, dir, kidoBin))
		h.waitPaneCommand(p, "ssh")
		h.in("send-keys", "-t", p, c.name, "Enter")
		h.waitPaneText(p, "received: "+c.name)
		if got := h.in("display-message", "-p", "-t", p, "#{@kido_ssh}"); got != "" {
			t.Fatalf("%s marks pane: %q", c.name, got)
		}
	}
}
