package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCaffeinate(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	dir, err := os.MkdirTemp("/tmp", "caffeinate-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	log := filepath.Join(dir, "starts")
	script := fmt.Sprintf("#!/bin/sh\nprintf '%%s %%s\\n' \"$$\" \"$*\" >> %q\nsleep 0.3\nexec /usr/bin/caffeinate \"$@\"\n", log)
	if err := os.WriteFile(filepath.Join(dir, "caffeinate"), []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	h := startPathPrefix(t, "alpha", dir)
	hold := func(pid int) {
		t.Helper()
		until := time.Now().Add(300 * time.Millisecond)
		h.waitFor(func() bool {
			if syscall.Kill(pid, 0) != nil {
				t.Fatal("caffeinate stopped before grace")
			}
			return time.Now().After(until)
		}, time.Second, msgf("caffeinate survives brief idle"))
	}
	h.waitRow("☕ off")
	h.click(5, outerRows)
	h.waitRow("☕ ● on")
	pid := 0
	h.waitFor(func() bool {
		pid, _ = strconv.Atoi(h.in("show-option", "-sv", "@kido-caffeinate-pid"))
		return pid > 0 && syscall.Kill(pid, 0) == nil
	}, settle, msgf("caffeinate running unconditionally"))
	h.click(5, outerRows)
	h.waitFor(func() bool { return hasLine(h.sidebar(), "when agents running") }, settle,
		func() string {
			return fmt.Sprintf("agents toggle: option=%q rows=%q", h.in("show-option", "-sv", "@kido-caffeinate"), h.sidebar())
		})
	// Leaving on starts the idle grace, rather than interrupting the assertion immediately.
	hold(pid)
	h.waitFor(func() bool { return syscall.Kill(pid, 0) != nil }, settle, msgf("stops after idle grace"))
	pane := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.agentStatus("cafe", pane, "pi", "running")
	h.waitRow("☕ ● when agents running")
	pid, _ = strconv.Atoi(h.in("show-option", "-sv", "@kido-caffeinate-pid"))
	h.agentStatus("cafe", pane, "pi", "idle")
	hold(pid)
	h.waitFor(func() bool { return syscall.Kill(pid, 0) != nil }, settle, msgf("idle agents stop after grace"))
	h.agentStatus("cafe", pane, "pi", "waiting")
	h.waitRow("☕ ● when agents running")
	pid, _ = strconv.Atoi(h.in("show-option", "-sv", "@kido-caffeinate-pid"))
	hold(pid)
	h.click(5, outerRows)
	h.waitRow("☕ off")
	h.waitFor(func() bool { return syscall.Kill(pid, 0) != nil }, time.Second, msgf("off stops immediately"))
	b, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	starts := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(starts) != 3 {
		t.Fatalf("expected three starts, got %q", b)
	}
	server := h.in("display-message", "-p", "#{pid}")
	for _, start := range starts {
		if !strings.HasSuffix(start, " -i -w "+server) {
			t.Fatalf("wrong invocation: %s", start)
		}
	}
}

func TestCaffeinateIgnoresUnrelatedPID(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	t.Parallel()
	h := start(t, "alpha")
	sleep := exec.Command("sleep", "300")
	if err := sleep.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { sleep.Wait(); close(exited) }()
	t.Cleanup(func() { sleep.Process.Kill(); <-exited })
	pid := strconv.Itoa(sleep.Process.Pid)
	h.in("set-option", "-s", "@kido-caffeinate-pid", pid)
	h.in("set-option", "-s", "@kido-caffeinate", "on")
	h.waitRow("☕ ● on")
	h.in("set-option", "-s", "@kido-caffeinate", "off")
	h.waitRow("☕ off")
	until := time.Now().Add(300 * time.Millisecond)
	h.waitFor(func() bool {
		select {
		case <-exited:
			t.Fatal("unrelated sleep was killed")
		default:
		}
		return time.Now().After(until)
	}, time.Second, msgf("unrelated sleep survives switching off"))
}

func TestCaffeinateUnavailable(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.in("set-option", "-s", "@kido-caffeinate", "on")
	h.in("set-option", "-g", "side-status-command", "PATH=/nonexistent exec "+kidoBin)
	h.waitFor(func() bool {
		h.in("refresh-client", "-S", "-t", h.client)
		return hasLine(h.sidebar(), "alpha") && !hasLine(h.sidebar(), "☕")
	}, settle, func() string { return fmt.Sprintf("sidebar without unavailable toggle: %q", h.sidebar()) })
	if got := h.in("show-option", "-sqv", "@kido-caffeinate-pid"); got != "" {
		t.Fatalf("unavailable caffeinate started: %s", got)
	}
}
