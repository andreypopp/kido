package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSidebarDoesNotLeakTerminalReplies(t *testing.T) {
	h := start(t, "alpha")
	h.in("set-option", "-g", "allow-passthrough", "on")
	h.in("set-option", "-g", "status-interval", "1")
	h.in("set-option", "-g", "side-status-command", "")
	h.waitFor(func() bool { return len(controlClientPIDs(h.inner)) == 0 }, settle, msgf("old sidebar exits"))
	queries := filepath.Join(h.dir, "queries")
	h.out("pipe-pane", "-t", "host:side", "cat > "+shellQuote(queries))
	ready := filepath.Join(h.dir, "ready")
	stop := filepath.Join(h.dir, "stop")
	done := filepath.Join(h.dir, "done")
	replies := filepath.Join(h.dir, "replies")
	h.sendLiteral(fmt.Sprintf("stty raw -echo; : > %s; end=$((SECONDS+10)); reply=; while [ $SECONDS -lt $end ] && [ ! -e %s ]; do IFS= read -r -t 1 -n 1 byte && reply=$reply$byte; done; printf '%%s' \"$reply\" > %s; stty sane; : > %s",
		shellQuote(ready), shellQuote(stop), shellQuote(replies), shellQuote(done)))
	h.sendKeys("Enter")
	h.waitFor(func() bool { _, err := os.Stat(ready); return err == nil }, settle, msgf("shell reads terminal replies"))
	h.in("set-option", "-g", "side-status-command", kidoBin)
	h.waitFileContains(queries, "\033[?1016$p")
	h.waitFor(func() bool { return hasLine(h.sidebar(), "alpha") }, settle, msgf("sidebar renders after probing"))
	if _, err := os.Stat(done); err == nil {
		t.Fatal("active shell stopped listening before the sidebar finished probing")
	}
	if err := os.WriteFile(stop, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { _, err := os.Stat(done); return err == nil }, settle, msgf("shell finished reading terminal replies"))
	got, err := os.ReadFile(replies)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("sidebar query replies reached the active shell: %q", got)
	}
	paneReplies := filepath.Join(h.dir, "pane-replies")
	paneDone := filepath.Join(h.dir, "pane-done")
	payload := "\033Ptmux;\033\033[?1004$p\033\\\033Ptmux;\033\033[c\033\\"
	command := fmt.Sprintf("stty raw -echo; printf '%%s' %s; end=$((SECONDS+4)); reply=; while [ $SECONDS -lt $end ] && IFS= read -r -t 2 -n 1 byte; do reply=$reply$byte; done; printf '%%s' \"$reply\" > %s; : > %s",
		shellQuote(payload), shellQuote(paneReplies), shellQuote(paneDone))
	h.in("split-window", "-d", "/bin/bash", "--noprofile", "--norc", "-c", command)
	h.waitFor(func() bool { _, err := os.Stat(paneDone); return err == nil }, settle, msgf("inactive pane receives its query replies"))
	got, err = os.ReadFile(paneReplies)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), "\033[?1004;") || !strings.Contains(string(got), "\033[?1;2c") {
		t.Fatalf("querying inactive pane did not receive DECRPM and DA: %q", got)
	}
}

func TestTerminalProbeReceivesFragmentedReplies(t *testing.T) {
	h := start(t, "alpha")
	h.in("set-option", "-g", "allow-passthrough", "on")
	h.in("set-option", "-g", "status-interval", "1")
	h.in("set-option", "-g", "side-status-command", "")
	h.waitFor(func() bool { return len(controlClientPIDs(h.inner)) == 0 }, settle, msgf("old sidebar exits"))
	ready := filepath.Join(h.dir, "side-ready")
	done := filepath.Join(h.dir, "side-done")
	replies := filepath.Join(h.dir, "side-replies")
	queries := filepath.Join(h.dir, "side-queries")
	script := filepath.Join(h.dir, "side-probe")
	payload := "\033Ptmux;\033\033_Gi=31338,a=q;AAAA\033\033\\\033\\"
	body := fmt.Sprintf("stty raw -echo; : > %s; IFS= read -r -t 4 -n 1 trigger; printf '%%s' %s; end=$((SECONDS+4)); reply=; while [ $SECONDS -lt $end ] && IFS= read -r -t 2 -n 1 byte; do reply=$reply$byte; done; printf '%%s' \"$reply\" > %s; : > %s",
		shellQuote(ready), shellQuote(payload), shellQuote(replies), shellQuote(done))
	if err := os.WriteFile(script, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	h.out("pipe-pane", "-t", "host:side", "cat > "+shellQuote(queries))
	h.in("set-option", "-g", "side-status-command", "/bin/bash "+shellQuote(script))
	h.waitFor(func() bool { _, err := os.Stat(ready); return err == nil }, settle, msgf("side job ready for trigger"))
	h.in("refresh-client", "-t", h.client, "-f", "side-status-focus")
	h.sendLiteral("x")
	h.in("refresh-client", "-t", h.client, "-f", "!side-status-focus")
	h.waitFileContains(queries, "\033_Gi=31338,a=q;")
	h.sendLiteral("\033")
	h.sendLiteral("_Gi=31338;O")
	h.sendLiteral("K\033\\")
	h.waitFor(func() bool { _, err := os.Stat(done); return err == nil }, settle, msgf("side job finished reading reply"))
	got, err := os.ReadFile(replies)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "\033_Gi=31338;OK\033\\" {
		t.Fatalf("unfocused side job did not receive fragmented graphics reply: %q", got)
	}
}
