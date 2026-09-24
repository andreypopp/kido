package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"kido/shell"
)

// Priming is how kido gives a login shell its OSC 133 integration without
// writing anything into the user's dotfiles: a throwaway directory holding
// the integration and one startup file that reads it, removes the
// directory and hands control back to the user's own files.
//
// Two commands prime a shell, and they differ only in where the work
// happens. `kido shell` builds the directory and execs the shell itself.
// `kido ssh` has no way to run Go on the far side, so sshBootstrap renders
// the same plan as a POSIX sh program and sends it as the remote command.
// What they share is this file: which mode a shell gets, what that mode's
// directory holds, and what the shell is exec'd with. The one rule spelled
// twice is the bash version floor, because the remote has only sh to check
// it with (bashHasPS0 here, kido_bash_has_ps0 there).

// primeMode is one way of priming a login shell.
type primeMode int

const (
	primePlain primeMode = iota // no markers: the shell exactly as it was
	primeZsh                    // the ZDOTDIR swap
	primeBash                   // $ENV read through --posix
)

// primeModeFor is the mode a login shell at path gets, by its basename -
// the only thing about a shell that can be known without running it. A
// bash has one more gate to pass, bashHasPS0, which costs a process to
// ask and so is left to the caller.
func primeModeFor(path string) primeMode {
	switch filepath.Base(path) {
	case "zsh":
		return primeZsh
	case "bash":
		return primeBash
	}
	return primePlain
}

// The names inside a primed shell's throwaway directory. zsh finds its
// startup file by the name zsh looks for; bash is handed $ENV by path and
// so could use any name, but the two are spelled alike here.
const (
	zshEnvFile          = ".zshenv"
	zshIntegrationFile  = "integration.zsh"
	bashEnvFile         = "env.bash"
	bashIntegrationFile = "integration.bash"
)

// primeFiles is what mode's throwaway directory holds, by name. A
// non-empty binDir puts kido's bin directory first on PATH at the end of
// the integration (pathPrependScript), which is only ever right locally:
// the far side of `kido ssh` has no kido and no shims, which is why
// sshBootstrap sends the integrations as they ship rather than these.
func primeFiles(mode primeMode, binDir string) map[string][]byte {
	withPath := func(integration []byte) []byte {
		if binDir == "" {
			return integration
		}
		return append(append([]byte{}, integration...), pathPrependScript(binDir)...)
	}
	switch mode {
	case primeZsh:
		return map[string][]byte{
			zshEnvFile:         []byte(kidoZshenv),
			zshIntegrationFile: withPath(shell.ZshIntegration),
		}
	case primeBash:
		return map[string][]byte{
			bashEnvFile:         []byte(kidoBashEnv),
			bashIntegrationFile: withPath(shell.BashIntegration),
		}
	}
	return nil
}

// primeShellArgs is the argv tail the shell is exec'd with. Every mode is
// a login shell: that is what tmux gives a pane and what ssh gives a
// session, and priming may not change it. --posix is what makes bash read
// $ENV at all (see kidoBashEnv), and the file turns it straight back off.
func primeShellArgs(mode primeMode) []string {
	if mode == primeBash {
		return []string{"--login", "--posix"}
	}
	return []string{"-l"}
}

// bashPS0Major and bashPS0Minor are the oldest bash whose PS0 the
// integration can hang its "command started" marker on. Apple ships 3.2.
const (
	bashPS0Major = 4
	bashPS0Minor = 4
)

// bashVersionProbe asks a bash its own version in the form bashHasPS0
// reads. It is run as `bash -c <probe>`, which is one process on top of
// the session and the only reliable answer: a floor checked inside the
// $ENV file would be a floor an old bash never reaches, because a bash
// that old does not read $ENV under --posix at all - leaving the session
// in posix mode for its whole life.
const bashVersionProbe = `echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"`

// bashHasPS0 reads bashVersionProbe's output and reports whether this
// bash is new enough to be primed. Anything unparsable is not.
func bashHasPS0(out string) bool {
	major, minor, ok := strings.Cut(strings.TrimSpace(out), ".")
	if !ok {
		return false
	}
	maj, err := strconv.Atoi(major)
	if err != nil {
		return false
	}
	min, err := strconv.Atoi(minor)
	if err != nil {
		return false
	}
	return maj > bashPS0Major || (maj == bashPS0Major && min >= bashPS0Minor)
}

// kidoZshenv is the .zshenv kido puts in the throwaway ZDOTDIR it hands a
// zsh. It is the whole of the ZDOTDIR technique: zsh looks up $ZDOTDIR
// again for each startup file, so restoring it here - before the user's
// own .zshenv is sourced - leaves .zprofile, .zshrc and .zlogin to come
// from the real dotfiles directory, and the user's $HOME is never written
// to.
//
// The integration is read into a parameter and sourced at the first
// precmd rather than here: a .zshrc that replaces precmd_functions
// wholesale, or prints its own OSC 133, would otherwise land on top of
// hooks registered before it ran. Reading it first means the directory
// can go now (unlinking a file zsh still has open is harmless), which is
// what leaves nothing at all behind.
const kidoZshenv = `# Written by kido into a throwaway ZDOTDIR.
# It removes itself; nothing kido writes here is meant to outlive the session.
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
  _kido_src="$(<"$_kido_dir/` + zshIntegrationFile + `")"
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
// Nothing here reads $BASH_VERSINFO: the caller has already asked this
// bash its version (bashVersionProbe) and sent a bash too old for PS0
// down the plain path, which never reaches --posix at all.
const kidoBashEnv = `# Written by kido into a throwaway $ENV file.
# It removes itself; nothing kido writes here is meant to outlive the session.
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
[ ! -f "$_kido_dir/` + bashIntegrationFile + `" ] || . "$_kido_dir/` + bashIntegrationFile + `"
rm -rf -- "$_kido_dir"
unset _kido_dir
`

// primeLocal builds the throwaway directory for mode, with binDir as
// primeFiles takes it, under the local temporary directory and returns
// the environment additions the primed shell needs. The directory
// removes itself, from the startup file kido just wrote into it, so there
// is nothing left to clean up after the exec that follows - which is as
// well, because nothing of kido's survives it.
func primeLocal(mode primeMode, binDir string) ([]string, error) {
	files := primeFiles(mode, binDir)
	if len(files) == 0 {
		return nil, nil
	}
	dir, err := os.MkdirTemp("", "kido-shell.")
	if err != nil {
		return nil, err
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), body, 0o600); err != nil {
			os.RemoveAll(dir)
			return nil, err
		}
	}
	switch mode {
	case primeZsh:
		env := []string{"ZDOTDIR=" + dir}
		if old, ok := os.LookupEnv("ZDOTDIR"); ok {
			env = append(env, "KIDO_ORIG_ZDOTDIR="+old)
		}
		return env, nil
	case primeBash:
		return []string{"ENV=" + filepath.Join(dir, bashEnvFile)}, nil
	}
	os.RemoveAll(dir)
	return nil, fmt.Errorf("no priming for mode %d", mode)
}

// hasZshDotfiles reports whether this login has zsh dotfiles of its own.
// A zsh with none is about to be offered zsh-newuser-install, and a
// ZDOTDIR pointing at kido's directory would suppress it - quietly
// changing what that first login does. kitty's ssh kitten carries the
// same guard, for the same reason, and it applies wherever the swap does.
func hasZshDotfiles() bool {
	dir := os.Getenv("ZDOTDIR")
	if dir == "" {
		dir = os.Getenv("HOME")
	}
	for _, name := range []string{".zshrc", ".zshenv", ".zprofile", ".zlogin"} {
		if fi, err := os.Stat(filepath.Join(dir, name)); err == nil && !fi.IsDir() {
			return true
		}
	}
	return false
}

// localPrimeMode is the mode a shell at path gets in a kido pane: the
// basename decision plus the two questions only this machine can answer,
// asked here rather than in primeModeFor because each costs a process or
// a stat.
func localPrimeMode(path string) primeMode {
	switch mode := primeModeFor(path); mode {
	case primeZsh:
		if !hasZshDotfiles() {
			return primePlain
		}
		return mode
	case primeBash:
		out, err := exec.Command(path, "-c", bashVersionProbe).Output()
		if err != nil || !bashHasPS0(string(out)) {
			return primePlain
		}
		return mode
	}
	return primePlain
}

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
// A bash is asked its own version before anything else is done to it, for
// the reason bashVersionProbe gives.
//
// The decode is tried twice because the flag is not portable: GNU
// coreutils spells it -d, and the BSD base64 some remotes carry spells it
// -D and rejects -d.
func sshBootstrap() string {
	return fmt.Sprintf(`kido_zsh_b64='%[1]s'
kido_bash_b64='%[2]s'
kido_dir=''
kido_shell=${SHELL:-/bin/sh}
[ -x "$kido_shell" ] || kido_shell=/bin/sh
kido_name=${kido_shell##*/}
kido_plain() {
  [ -n "$kido_dir" ] && rm -rf "$kido_dir"
  "$kido_shell" %[3]s -c : >/dev/null 2>&1 && exec "$kido_shell" %[3]s
  exec "$kido_shell"
}
kido_decode() {
  printf %%s "$1" | base64 -d > "$2" 2>/dev/null
  [ -s "$2" ] || printf %%s "$1" | base64 -D > "$2" 2>/dev/null
  [ -s "$2" ]
}
kido_bash_has_ps0() {
  kido_v=$("$kido_shell" -c '%[4]s' 2>/dev/null)
  kido_maj=${kido_v%%%%.*}
  kido_min=${kido_v#*.}
  case "$kido_maj$kido_min" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$kido_maj" -gt %[5]d ] || { [ "$kido_maj" -eq %[5]d ] && [ "$kido_min" -ge %[6]d ]; }
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
  kido_decode "$kido_zsh_b64" "$kido_dir/%[7]s" || kido_plain
  kido_zdotdir=${ZDOTDIR:-$HOME}
  [ -f "$kido_zdotdir/.zshrc" ] || [ -f "$kido_zdotdir/.zshenv" ] ||
    [ -f "$kido_zdotdir/.zprofile" ] || [ -f "$kido_zdotdir/.zlogin" ] || kido_plain
  cat > "$kido_dir/%[8]s" <<'KIDO_ZSHENV' || kido_plain
%[9]sKIDO_ZSHENV
  [ -n "$ZDOTDIR" ] && export KIDO_ORIG_ZDOTDIR="$ZDOTDIR"
  export ZDOTDIR="$kido_dir"
  exec "$kido_shell" %[14]s
fi
# No dotfile guard here, unlike the zsh branch above: kitty's
# exec_bash_with_integration has none either, and the guard it does have
# in exec_zsh_with_integration is commented "dont prevent
# zsh-newuser-install from running". bash has no first-login installer to
# suppress, and a remote with no login files at all is one the $ENV file
# below sources nothing from, which is what bash would have done anyway.
kido_decode "$kido_bash_b64" "$kido_dir/%[10]s" || kido_plain
cat > "$kido_dir/%[11]s" <<'KIDO_BASHENV' || kido_plain
%[12]sKIDO_BASHENV
export ENV="$kido_dir/%[11]s"
exec "$kido_shell" %[13]s
`,
		base64Payload(shell.ZshIntegration), base64Payload(shell.BashIntegration),
		strings.Join(primeShellArgs(primePlain), " "),
		bashVersionProbe, bashPS0Major, bashPS0Minor,
		zshIntegrationFile, zshEnvFile, kidoZshenv,
		bashIntegrationFile, bashEnvFile, kidoBashEnv,
		strings.Join(primeShellArgs(primeBash), " "),
		strings.Join(primeShellArgs(primeZsh), " "))
}

// base64Payload encodes an integration for the ssh command line. The
// base64 alphabet holds no single quote, which is what makes wrapping a
// payload in one pair of single quotes safe with no escaping at all.
func base64Payload(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
