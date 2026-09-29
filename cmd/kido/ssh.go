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

// `kido ssh` is also a supported interface on its own (docs/design.md),
// so it resolves the real ssh itself rather than taking it as an argument.
func sshCmd(args []string) error {
	path, err := realOnPath("ssh")
	if err != nil {
		return err
	}
	info, statErr := os.Stdin.Stat()
	tty := statErr == nil && info.Mode()&os.ModeCharDevice != 0
	return syscall.Exec(path, sshArgs(args, tty), os.Environ())
}
