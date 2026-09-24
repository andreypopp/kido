package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"kido/internal/tmux"
)

// shellCmd implements `kido shell`, the default-command every pane of the
// kido server starts with: it execs the user's login shell with kido's
// integration arranged around it (see prime.go), so a pane reports its
// prompts and command lines without a line of kido in the user's dotfiles.
//
// It replaces this process with the shell. Nothing of kido's is left in
// the pane - not a wrapper process, not a file - which is what makes a
// pane under kido indistinguishable from one under stock tmux for
// everything except the markers.
func shellCmd(args []string) error {
	if len(args) > 0 {
		return fmt.Errorf("usage: kido shell")
	}
	path := loginShell()
	mode := localPrimeMode(path)
	env := os.Environ()
	bin, _ := ownBinDir()
	add, err := primeLocal(mode, bin)
	if err != nil {
		// A pane that cannot be primed is a pane with no markers, never a
		// pane with no shell.
		mode = primePlain
	}
	argv := shellArgv(path, mode, tmux.GlobalOption(userCommandOption))
	return syscall.Exec(path, argv, withEnv(env, add))
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

// userCommandOption is where the launcher parks a default-command the
// user set in their own kido.conf, before overriding it with `kido shell`
// (see writeServerConf). Empty is the ordinary case: no command, so the
// pane gets an interactive login shell.
const userCommandOption = "@kido-user-command"

// loginShell is the shell a kido pane runs: the server's default-shell
// when there is a server to ask - tmux itself defaults that to the $SHELL
// of whoever started the server, so a user who set one wins and a user
// who did not loses nothing - then $SHELL, then /bin/sh.
func loginShell() string {
	return resolveLoginShell(tmux.GlobalOption("default-shell"), os.Getenv("SHELL"))
}

// resolveLoginShell is loginShell's order over values it is given, so it
// can be tested without a tmux server answering for the machine the test
// runs on. A candidate that is not an executable file is skipped: an
// option naming a shell this host does not have must not cost the pane
// its shell.
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

// shellArgv is how the shell at path is exec'd: the arguments its priming
// mode needs, and the user's own default-command when they set one, in
// the place tmux would have put it.
//
// An unprimed shell is started the way tmux itself starts one, by dashing
// argv[0] rather than by passing -l: a shell kido knows nothing about is
// exactly the shell that might not take -l, and this cannot be got wrong.
// The ssh bootstrap has to pass -l there instead, because sh gives it no
// way to set another process's argv[0], which is why it probes first.
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
