package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"kido/internal/tmux"
)

func shellCmd(args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("usage: kido shell")
	}
	path, command := shellCommand(resolveLoginShell(tmux.GlobalOption("default-shell"), os.Getenv("SHELL")), tmux.GlobalOption(userCommandOption))
	mode := localPrimeMode(path)
	env := os.Environ()
	bin, _ := ownBinDir()
	add, err := primeLocal(mode, bin)
	if err != nil {
		// A pane that cannot be primed is a pane with no markers, never a
		// pane with no shell.
		mode = primePlain
	}
	argv := shellArgv(path, mode, command)
	return syscall.Exec(path, argv, withEnv(env, add))
}

func bareShellWord(command string) (word string, ok bool) {
	word = strings.TrimSpace(command)
	if word == "" || strings.ContainsAny(word, " \t\n\"'$`\\;|&<>(){}[]*?~!#") {
		return "", false
	}
	return word, true
}

// tmux itself would start a bare "zsh" as an interactive, non-login
// shell; kido primes every shell with -l regardless (primeShellArgs), so
// what the user gets here is a primed *login* zsh, not the exact shell
// tmux would have.
func shellCommand(loginShellPath, command string) (path, effective string) {
	word, ok := bareShellWord(command)
	if !ok {
		return loginShellPath, command
	}
	resolved := word
	if !strings.Contains(word, "/") {
		if p, err := exec.LookPath(word); err == nil {
			resolved = p
		}
	}
	switch filepath.Base(resolved) {
	case "zsh", "bash":
		return resolved, ""
	}
	if fa, errA := os.Stat(resolved); errA == nil {
		if fb, errB := os.Stat(loginShellPath); errB == nil && os.SameFile(fa, fb) {
			return loginShellPath, ""
		}
	}
	return loginShellPath, command
}

// withEnv is base with each assignment in add replacing any it already
// had for that name. Appending would not do: execve takes the list as it
// is given, and getenv answers with the *first* match, so a second
// ZDOTDIR after the session's own is one the shell never reads - and the
// zsh priming is exactly the case where there is one to replace.
func withEnv(base, add []string) []string {
	names := map[string]bool{}
	for _, kv := range add {
		name, _, _ := strings.Cut(kv, "=")
		names[name] = true
	}
	out := make([]string, 0, len(base)+len(add))
	for _, kv := range base {
		if name, _, ok := strings.Cut(kv, "="); !ok || !names[name] {
			out = append(out, kv)
		}
	}
	return append(out, add...)
}

const userCommandOption = "@kido-user-command"

// tmux itself defaults default-shell to the $SHELL of whoever started
// the server, so a user who set one wins and a user who did not loses
// nothing.
func resolveLoginShell(candidates ...string) string {
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if fi, err := os.Stat(candidate); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return "/bin/sh"
}

// An unprimed shell is started the way tmux itself starts one, by dashing
// argv[0] rather than by passing -l: a shell kido knows nothing about is
// exactly the shell that might not take -l. The ssh bootstrap has to pass
// -l there instead, because sh gives it no way to set another process's
// argv[0].
func shellArgv(path string, mode primeMode, command string) []string {
	argv := []string{path}
	switch {
	case mode != primePlain:
		argv = append(argv, primeShellArgs(mode)...)
	case command == "":
		argv[0] = "-" + filepath.Base(path)
	}
	if command != "" {
		argv = append(argv, "-c", command)
	}
	return argv
}
