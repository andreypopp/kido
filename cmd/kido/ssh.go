package main

import (
	"os"
	"strings"
	"syscall"
)

// sshValueOpts are the ssh option letters that take a value, so the
// parser can tell `-o BatchMode=yes` (two arguments) from `-tt` (one) and
// find where the destination starts. From ssh(1); a letter kido does not
// know about can only cost it the priming, never the connection, because
// an unparsed argument leaves no destination and an invocation with no
// destination is passed through untouched.
const sshValueOpts = "BbcDEeFIiJLlmOopQRSWw"

// sshNoShellOpts are the ssh option letters that mean the connection is
// not an interactive login shell: no command of kido's may be attached to
// one, because there is nothing to attach it to (-N, -W), the remote
// command is a subsystem (-s), stdin is not the user's (-n, -f), a tty is
// refused outright (-T), or ssh is answering a question locally and never
// connecting at all (-Q, -V, -G, -O).
const sshNoShellOpts = "NTWfsnOQVG"

// sshInvocation is an ssh command line as kido reads it.
type sshInvocation struct {
	opts    []string // everything before the destination, in order
	letters string   // the option letters given, values excluded
	dest    string
	command []string // the remote command, when one was given
}

// parseSSH splits an ssh command line at its destination. It only needs
// to be right about where the destination is and which letters were
// given; ssh itself parses the arguments again, and kido passes them
// through in the order it received them.
func parseSSH(args []string) sshInvocation {
	var in sshInvocation
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if in.dest != "" {
			in.command = append(in.command, arg)
			continue
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			in.dest = arg
			continue
		}
		in.opts = append(in.opts, arg)
		for j := 1; j < len(arg); j++ {
			in.letters += string(arg[j])
			if strings.IndexByte(sshValueOpts, arg[j]) >= 0 {
				// The value is the rest of this argument, or the next one.
				if j == len(arg)-1 && i+1 < len(args) {
					i++
					in.opts = append(in.opts, args[i])
				}
				break
			}
		}
	}
	return in
}

// canPrime reports whether this invocation is the one shape kido can
// prime: an interactive login shell on a destination, with kido's own
// command free to be the remote one. Everything else is passed to ssh
// untouched - a plain ssh is never worse than no kido at all.
func (in sshInvocation) canPrime(tty bool) bool {
	return tty && in.dest != "" && len(in.command) == 0 &&
		!strings.ContainsAny(in.letters, sshNoShellOpts)
}

// sshArgs is the ssh command line kido runs for args. It adds -t, because
// ssh allocates no tty for a command and the primed shell is interactive.
func sshArgs(args []string, tty bool) []string {
	in := parseSSH(args)
	if !in.canPrime(tty) {
		return append([]string{"ssh"}, args...)
	}
	out := append([]string{"ssh"}, in.opts...)
	return append(out, "-t", in.dest, sshBootstrap())
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
