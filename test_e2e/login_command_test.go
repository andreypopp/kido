package e2e

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoginCommand(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.hideSidebar()
	caller := h.firstPane("alpha")
	h.in("set-environment", "-g", "KIDO_LOGIN_TEST", "")
	h.programStatus(caller, "state=idle:app=pi")
	h.setPiOptions(caller, "parent-session", "Parent", "", "")
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			shell, err := exec.LookPath(name)
			if err != nil {
				t.Skip("no " + name + " in PATH")
			}
			home := t.TempDir()
			for file, contents := range map[string]string{
				".bash_profile": ". \"$HOME/.bashrc\"\n",
				".bashrc":       "export KIDO_LOGIN_TEST=from-dotfiles PATH=/usr/bin:/bin\n",
				".zshrc":        "export KIDO_LOGIN_TEST=from-dotfiles PATH=/usr/bin:/bin\n",
			} {
				if err := os.WriteFile(filepath.Join(home, file), []byte(contents), 0600); err != nil {
					t.Fatal(err)
				}
			}
			h.in("set-option", "-g", "default-shell", shell)
			h.in("set-environment", "-g", "HOME", home)
			h.in("set-environment", "-gu", "ZDOTDIR")
			if got := h.in("show-environment", "-g", "KIDO_LOGIN_TEST"); strings.Contains(got, "from-dotfiles") {
				t.Fatalf("server has dotfile variable: %q", got)
			}
			output := filepath.Join(home, "result")
			args := []string{"run-child", caller, "--name", "login-" + name, "--", kidoBin, "shell", "--", "sh", "-c", `printf '%s\n' "$KIDO_LOGIN_TEST" "$1" "${PATH%%:*}" > "$2"; exit 23`, "sh", "literal ; $HOME ' text", output}
			r := h.startRun(caller, args...)
			out, rc := h.kidoAs(caller, "", nil, "run-wait", "--json", r.ID)
			if rc != 0 || !strings.Contains(out, "exit 23") {
				t.Fatalf("outcome = %d %q, want exit 23", rc, out)
			}
			got, err := os.ReadFile(output)
			if err != nil || string(got) != "from-dotfiles\nliteral ; $HOME ' text\n"+filepath.Join(shareDir, "bin")+"\n" {
				t.Fatalf("login environment and argv = %q (%v)", got, err)
			}
			if got := h.in("display-message", "-p", "-t", r.Pane, "#{pane_dead_status}"); got != "23" {
				t.Fatalf("dead status = %q", got)
			}
			if got := h.in("display-message", "-p", "-t", r.Pane, "#{pane_last_prompt_time}"); reportedPrompt(got) {
				t.Fatalf("command emitted a prompt mark: %q", got)
			}
		})
	}
}
