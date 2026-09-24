package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"kido/shell"
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
func sshCmd(args []string) error {
	path, err := exec.LookPath("ssh")
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

// kidoZshenv is the .zshenv kido puts in the throwaway ZDOTDIR it hands
// the remote zsh. It is the whole of the ZDOTDIR technique: zsh looks up
// $ZDOTDIR again for each startup file, so restoring it here - before the
// user's own .zshenv is sourced - leaves .zprofile, .zshrc and .zlogin to
// come from the real dotfiles directory, and the remote $HOME is never
// written to.
//
// The integration is read into a parameter and sourced at the first
// precmd rather than here: a .zshrc that replaces precmd_functions
// wholesale, or prints its own OSC 133, would otherwise land on top of
// hooks registered before it ran. Reading it first means the directory
// can go now (unlinking a file zsh still has open is harmless), which is
// what leaves nothing at all on the remote host.
const kidoZshenv = `# Written by ` + "`kido ssh`" + ` into a throwaway ZDOTDIR on this host.
# It removes itself; nothing kido sends is meant to outlive the session.
if [[ -n ${KIDO_ORIG_ZDOTDIR+X} ]]; then
  export ZDOTDIR=$KIDO_ORIG_ZDOTDIR
else
  unset ZDOTDIR
fi
unset KIDO_ORIG_ZDOTDIR
# Every expansion is quoted: /etc/zshenv runs before this file and may
# have set SH_WORD_SPLIT, under which an unquoted eval would rejoin the
# integration's lines with spaces.
{
  _kido_dir="${${(%):-%x}:A:h}"
  _kido_src="$(<"$_kido_dir/integration.zsh")"
  command rm -rf -- "$_kido_dir"
  unset _kido_dir
  _kido_zshenv="${ZDOTDIR-~}/.zshenv"
  [[ ! -r $_kido_zshenv ]] || source -- "$_kido_zshenv"
  unset _kido_zshenv
} always {
  if [[ -o interactive && -n $_kido_src ]]; then
    typeset -ag precmd_functions
    precmd_functions+=(_kido_ssh_init)
  else
    unset _kido_src
  fi
}
_kido_ssh_init() {
  precmd_functions=(${precmd_functions:#_kido_ssh_init})
  eval "$_kido_src"
  unset _kido_src
  unfunction _kido_ssh_init
  (( $+functions[kido_osc133_precmd] )) && kido_osc133_precmd
}
`

// kidoBashEnv is the $ENV file kido hands a login bash through --posix,
// in the same throwaway directory as the integration. A login bash
// ignores $ENV - and --rcfile, which only a non-login bash reads - so
// --posix is the one lever that gets a file of kido's choosing read
// before anything of the user's; this is exec_bash_with_integration from
// kitty's ssh kitten, cut down the same way the zsh path is.
//
// Once sourced it turns posix mode back off - so nothing else about the
// session runs posix, all the way to the interactive shell the user
// types at - reads the login files bash itself would have (/etc/profile,
// then the first of ~/.bash_profile, ~/.bash_login, ~/.profile, exactly
// as a login bash run with no kido in front of it would), sources the
// integration, and removes the directory it came from. Unlike the zsh
// path there is no deferral to the first prompt: nothing else runs after
// this file, so there are no later hooks for the integration to land in
// front of.
//
// Nothing here reads $BASH_VERSINFO: the bootstrap has already asked this
// bash its version and sent a bash too old for PS0 down kido_plain, which
// never reaches --posix at all.
const kidoBashEnv = `# Written by ` + "`kido ssh`" + ` into a throwaway $ENV file on this host.
# It removes itself; nothing kido sends is meant to outlive the session.
unset ENV
set +o posix
# Resetting posix mode does not clear this on its own - kitty's bash
# integration carries the same comment, against the same bash behaviour.
shopt -u inherit_errexit 2>/dev/null
_kido_dir="${BASH_SOURCE%/*}"
[ ! -r /etc/profile ] || . /etc/profile
for _kido_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -r "$_kido_f" ]; then . "$_kido_f"; break; fi
done
unset _kido_f
[ ! -f "$_kido_dir/integration.bash" ] || . "$_kido_dir/integration.bash"
rm -rf -- "$_kido_dir"
unset _kido_dir
`

// sshBootstrap is the POSIX sh program kido sends as the remote command.
// It decodes the integration for the remote's login shell into a fresh
// temporary directory and execs that shell primed; anything it cannot do
// ends in the same login shell unprimed, so a failure costs the session
// nothing.
//
// The payload rides in the ssh command line, where the remote's `ps` can
// read it. That is a deliberate trade and not an oversight: it is a
// public shell script with no secrets in it, and the alternative channel
// - stdin - is the interactive session's own tty. See docs/design.md,
// "Priming a remote shell".
//
// zsh and bash are primed; anything else stays kido_plain. The login
// shell is read from $SHELL, which sshd sets from the password database,
// so the detection costs no extra round trip.
//
// A bash is asked its own version before anything else is done to it.
// That costs one process on the remote and buys the only reliable
// answer: Apple's bash 3.2 never reads $ENV under --posix, so a floor
// checked inside the $ENV file would be a floor that host never reaches,
// leaving the session in posix mode for its whole life and the temporary
// directory behind it.
//
// The decode is tried twice because the flag is not portable: GNU
// coreutils spells it -d, and the BSD base64 some remotes carry spells it
// -D and rejects -d.
func sshBootstrap() string {
	zshPayload := base64.StdEncoding.EncodeToString(shell.ZshIntegration)
	bashPayload := base64.StdEncoding.EncodeToString(shell.BashIntegration)
	return fmt.Sprintf(`kido_zsh_b64='%s'
kido_bash_b64='%s'
kido_dir=''
kido_shell=${SHELL:-/bin/sh}
[ -x "$kido_shell" ] || kido_shell=/bin/sh
kido_name=${kido_shell##*/}
kido_plain() {
  [ -n "$kido_dir" ] && rm -rf "$kido_dir"
  "$kido_shell" -l -c : >/dev/null 2>&1 && exec "$kido_shell" -l
  exec "$kido_shell"
}
kido_decode() {
  printf %%s "$1" | base64 -d > "$2" 2>/dev/null
  [ -s "$2" ] || printf %%s "$1" | base64 -D > "$2" 2>/dev/null
  [ -s "$2" ]
}
kido_bash_has_ps0() {
  kido_v=$("$kido_shell" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)
  kido_maj=${kido_v%%%%.*}
  kido_min=${kido_v#*.}
  case "$kido_maj$kido_min" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$kido_maj" -gt 4 ] || { [ "$kido_maj" -eq 4 ] && [ "$kido_min" -ge 4 ]; }
}
case "$kido_name" in
  zsh) ;;
  # PS0 arrived in bash 4.4. An older bash is left alone here rather than
  # inside the $ENV file, which it may never read: it gets its own login
  # files and no markers, the "unprimed but not broken" outcome kido_plain
  # gives a remote with no zsh, no mktemp or no base64.
  bash) kido_bash_has_ps0 || kido_plain ;;
  *) kido_plain ;;
esac
command -v mktemp >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 || kido_plain
kido_dir=$(mktemp -d "${TMPDIR:-/tmp}/kido-ssh.XXXXXXXX" 2>/dev/null) && [ -d "$kido_dir" ] || kido_plain
trap 'rm -rf "$kido_dir"' EXIT HUP INT TERM
if [ "$kido_name" = zsh ]; then
  kido_decode "$kido_zsh_b64" "$kido_dir/integration.zsh" || kido_plain
  kido_zdotdir=${ZDOTDIR:-$HOME}
  [ -f "$kido_zdotdir/.zshrc" ] || [ -f "$kido_zdotdir/.zshenv" ] ||
    [ -f "$kido_zdotdir/.zprofile" ] || [ -f "$kido_zdotdir/.zlogin" ] || kido_plain
  cat > "$kido_dir/.zshenv" <<'KIDO_ZSHENV' || kido_plain
%sKIDO_ZSHENV
  [ -n "$ZDOTDIR" ] && export KIDO_ORIG_ZDOTDIR="$ZDOTDIR"
  export ZDOTDIR="$kido_dir"
  exec "$kido_shell" -l
fi
# No dotfile guard here, unlike the zsh branch above: kitty's
# exec_bash_with_integration has none either, and the guard it does have
# in exec_zsh_with_integration is commented "dont prevent
# zsh-newuser-install from running". bash has no first-login installer to
# suppress, and a remote with no login files at all is one the $ENV file
# below sources nothing from, which is what bash would have done anyway.
kido_decode "$kido_bash_b64" "$kido_dir/integration.bash" || kido_plain
cat > "$kido_dir/env.bash" <<'KIDO_BASHENV' || kido_plain
%sKIDO_BASHENV
export ENV="$kido_dir/env.bash"
exec "$kido_shell" --login --posix
`, zshPayload, bashPayload, kidoZshenv, kidoBashEnv)
}
