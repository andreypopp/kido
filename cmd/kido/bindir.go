package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// kido's bin directory is <prefix>/share/kido/bin: the shims standing in
// for tmux, ssh, pi and claude inside a kido pane (shims/bin). It goes
// first on PATH twice over. The launcher starts the server with it there,
// which is the PATH of everything tmux runs without a shell of the user's
// in between - run-shell, a new-window command, a subagent's pi - and the
// integration of every primed shell puts it back in front after the
// user's login files, which may have rewritten PATH on the way (macOS
// path_helper, Debian's /etc/profile).

// binDir is the bin directory shipped with the kido at exe. ok is false
// for a kido with no share/kido beside it, a build in a checkout, which
// runs with no shims at all; and for a directory PATH cannot hold, which
// is one whose name has a colon in it.
func binDir(exe string) (string, bool) {
	shim, err := findShared(exe, "bin/tmux")
	if err != nil {
		return "", false
	}
	dir := filepath.Dir(shim)
	if strings.ContainsRune(dir, filepath.ListSeparator) {
		return "", false
	}
	return dir, true
}

// ownBinDir is binDir for this kido.
func ownBinDir() (string, bool) {
	exe, err := invokedPath(os.Args[0])
	if err != nil {
		return "", false
	}
	return binDir(exe)
}

// pathWithFirst is the PATH value path with dir moved to its front: every
// occurrence removed, then dir prepended, so running it again - a nested
// shell, a second launch - leaves the value as it was. pathPrependScript
// is the same rule in sh.
func pathWithFirst(dir, path string) string {
	out := []string{dir}
	for _, entry := range filepath.SplitList(path) {
		if entry != dir {
			out = append(out, entry)
		}
	}
	return strings.Join(out, string(filepath.ListSeparator))
}

// pathPrependScript is sh, and zsh and bash with it, that moves dir to
// the front of PATH as pathWithFirst does. It is the last thing a primed
// shell's integration runs. dir is single-quoted, which carries any byte
// sh can hold; binDir has already refused the one character PATH cannot.
func pathPrependScript(dir string) string {
	return fmt.Sprintf(`
# Written by kido shell: its bin directory goes first on PATH, after the
# login files that may have rewritten PATH, and only once.
_kido_bin=%s
_kido_rest=":$PATH:"
while :; do
  case $_kido_rest in
  *":$_kido_bin:"*) _kido_rest="${_kido_rest%%%%":$_kido_bin:"*}:${_kido_rest#*":$_kido_bin:"}" ;;
  *) break ;;
  esac
done
_kido_rest=${_kido_rest#:}
_kido_rest=${_kido_rest%%:}
PATH="$_kido_bin${_kido_rest:+:$_kido_rest}"
export PATH
unset _kido_bin _kido_rest
`, shellQuote(dir))
}

// realOnPath finds name on PATH the way the shims do (shims/shim.sh): the
// first one after kido's own bin directory, or, with that directory
// nowhere on PATH, the first that is not kido's own shim. A kido
// subcommand a shim runs has to look past the shim, or it runs itself.
func realOnPath(name string) (string, error) {
	dir, ok := ownBinDir()
	if !ok {
		return exec.LookPath(name)
	}
	return lookPathPast(name, dir, os.Getenv("PATH"))
}

// lookPathPast is realOnPath over a given bin directory and PATH.
func lookPathPast(name, dir, path string) (string, error) {
	dirInfo, dirErr := os.Stat(dir)
	shimInfo, shimErr := os.Stat(filepath.Join(dir, name))
	seen := false
	var after, anywhere string
	for _, entry := range filepath.SplitList(path) {
		if entry == "" {
			entry = "."
		}
		if fi, err := os.Stat(entry); err == nil && dirErr == nil && os.SameFile(fi, dirInfo) {
			seen = true
			continue
		}
		candidate := filepath.Join(entry, name)
		fi, err := os.Stat(candidate)
		if err != nil || fi.IsDir() || fi.Mode()&0o111 == 0 {
			continue
		}
		if shimErr == nil && os.SameFile(fi, shimInfo) {
			continue
		}
		if seen && after == "" {
			after = candidate
		}
		if !seen && anywhere == "" {
			anywhere = candidate
		}
	}
	found := anywhere
	if seen {
		found = after
	}
	if found == "" {
		return "", fmt.Errorf("no %s on PATH past %s", name, dir)
	}
	return found, nil
}
