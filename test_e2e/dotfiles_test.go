package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestShellDotfileIsolation(t *testing.T) {
	t.Parallel()
	if os.Getenv("KIDO_E2E_DOTFILE_PROBE") == "1" {
		h := start(t, "isolated")
		h.in("set-option", "-g", "remain-on-exit", "on")
		for _, name := range []string{"bash", "zsh", "sh"} {
			path, err := exec.LookPath(name)
			if err != nil {
				continue
			}
			for _, args := range [][]string{{"-l", "-i", "-c", ":"}, {"-i", "-c", ":"}, {"-c", ":"}} {
				cmd := exec.Command(path, args...)
				cmd.Env = cleanEnv()
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("%s %v: %v\n%s", name, args, err, out)
				}
			}
			h.in("set-option", "-g", "default-shell", path)
			pane := h.newWindow("isolated", "login-"+name, kidoBin, "shell", "--", "sh", "-c", "exit 0")
			h.waitFor(func() bool { return h.in("display-message", "-p", "-t", pane, "#{pane_dead}") == "1" }, settle, msgf("%s login command ends", name))
		}
		return
	}
	requireTmux(t)
	home := t.TempDir()
	marker := filepath.Join(home, "reads")
	for _, file := range []string{".profile", ".bash_profile", ".bash_login", ".bashrc", ".zshenv", ".zprofile", ".zshrc", ".zlogin", "startup"} {
		body := fmt.Sprintf("printf '%%s\\n' '%s' >> '%s'\n", file, marker)
		if err := os.WriteFile(filepath.Join(home, file), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(self, "-test.run=^TestShellDotfileIsolation$", "-test.v", "-test.timeout=30s")
	cmd.Env = append(os.Environ(), childPrefixEnv+"="+e2ePrefix, "KIDO_E2E_DOTFILE_PROBE=1", "HOME="+home, "ZDOTDIR="+home, "ENV="+filepath.Join(home, "startup"), "BASH_ENV="+filepath.Join(home, "startup"))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("shell probe: %v\n%s", err, out)
	}
	reads, err := os.ReadFile(marker)
	if err == nil {
		t.Fatalf("shells read inherited dotfiles:\n%s", strings.TrimSpace(string(reads)))
	}
	if !os.IsNotExist(err) {
		t.Fatal(err)
	}
}
