package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRPCControlClientDoesNotKeepPaneFocused(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	sidebar := h.waitControlClients(1)[0]
	feed := h.startFeed("alpha")
	h.in("refresh-client", "-t", feed.client, "-f", "no-output,ignore-size")
	var rpc string
	h.waitFor(func() bool {
		for _, name := range h.controlClients() {
			if name != sidebar && name != feed.client {
				rpc = name
				return true
			}
		}
		return false
	}, settle, msgf("RPC control client attached"))
	held := func() bool {
		found := 0
		for _, line := range strings.Split(h.in("list-clients", "-F", "#{client_name}\t#{client_control_mode}\t#{session_name}\t#{client_flags}"), "\n") {
			fields := strings.Split(line, "\t")
			if len(fields) == 4 && (fields[0] == feed.client || fields[0] == rpc) && fields[1] == "1" && fields[2] == "alpha" && strings.Contains(fields[3], "no-output") && strings.Contains(fields[3], "ignore-size") {
				found++
			}
		}
		return found == 2
	}
	h.waitFor(held, settle, msgf("anchor and RPC control clients attached to alpha without output"))
	h.in("set-option", "-g", "focus-events", "on")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	path := filepath.Join(h.dir, "focus-input")
	h.in("respawn-pane", "-k", "-t", pane, "sh", "-c", "stty raw -echo; printf '\033[?1004h\033]2;focus-ready\007'; exec cat > "+shellQuote(path))
	h.waitFor(func() bool {
		_, err := os.Stat(path)
		return err == nil && h.paneTitle(pane) == "focus-ready"
	}, settle, msgf("focus recorder ready"))
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !held() {
		t.Fatal("anchor or RPC client left alpha before switch")
	}
	h.in("switch-client", "-c", h.client, "-t", "beta")
	if !held() {
		t.Fatal("anchor or RPC client left alpha at switch")
	}
	want := string(before) + "\033[O"
	h.waitFor(func() bool { got, _ := os.ReadFile(path); return string(got) == want }, settle, msgf("focus-out while anchor and RPC clients stay in alpha"))
	if !held() {
		t.Fatal("anchor or RPC client left alpha before focus-out")
	}
	h.in("switch-client", "-c", h.client, "-t", "alpha")
	want += "\033[I"
	h.waitFor(func() bool { got, _ := os.ReadFile(path); return string(got) == want }, settle, msgf("focus-in after returning to alpha"))
	t.Logf("anchor %s and RPC client %s stayed in alpha; recorder received %q", feed.client, rpc, want[len(before):])
}
