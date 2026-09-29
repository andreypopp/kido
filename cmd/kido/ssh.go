package main

import (
	"os"
	"strings"
	"syscall"

	"kido/internal/procs"
)

// sshNoShellOpts are the ssh option letters that mean the connection is
// not an interactive login shell: no command of kido's may be attached to
// one, because there is nothing to attach it to (-N, -W), the remote
// command is a subsystem (-s), stdin is not the user's (-n, -f), a tty is
// refused outright (-T), or ssh is answering a question locally and never
// connecting at all (-Q, -V, -G, -O).
const sshNoShellOpts = "NTWfsnOQVG"

// canPrime reports whether in is the one shape kido can prime: an
// interactive login shell on a destination, with kido's own command free
// to be the remote one. Everything else is passed to ssh untouched - a
// plain ssh is never worse than no kido at all.
func canPrime(in procs.SSHArgs, tty bool) bool {
	return tty && in.Dest != "" && len(in.Command) == 0 &&
		!strings.ContainsAny(in.Letters, sshNoShellOpts)
}

// sshArgs is the ssh command line kido runs for args. It adds -t, because
// ssh allocates no tty for a command and the primed shell is interactive.
func sshArgs(args []string, tty bool) []string {
	in := procs.ParseSSH(args)
	if !canPrime(in, tty) {
		return append([]string{"ssh"}, args...)
	}
	out := append([]string{"ssh"}, in.Opts...)
	return append(out, "-t", in.Dest, sshBootstrap())
}

// sshCmd implements `kido ssh`: ssh to a host with its zsh primed to
// report to kido's sidebar, by way of a bootstrap sent as the remote
// command. It replaces this process with ssh, so signals, the exit status
// and the tty all behave as they would without kido in front of them.
//
// The ssh it runs is the one past kido's bin directory, whose own ssh is
// the shim that ran this.
func sshCmd(args []string) error {
	path, err := realOnPath("ssh")
	if err != nil {
		return err
	}
	argv := sshArgs(args, isTTY(os.Stdin))
	return syscall.Exec(path, argv, os.Environ())
}

// isTTY reports whether f is a terminal.
func isTTY(f *os.File) bool {
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
