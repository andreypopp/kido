package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// invokedPath returns the path kido was started as, with symlinks left
// alone. os.Executable is not it on Linux, where it reads /proc/self/exe
// and so always comes back fully resolved - for a Homebrew install, the
// versioned Cellar directory rather than the prefix symlink pointing at
// it. findShared would then have no unresolved candidate to prefer, and
// the setup commands would write a path into a config file that the next
// `brew cleanup` deletes. argv[0] keeps the spelling: used as-is when it
// has a separator, looked up on PATH when it does not. os.Executable stays
// the fallback, for a caller that cleared argv[0] or a lookup that fails.
func invokedPath(arg0 string) (string, error) {
	var p string
	switch {
	case strings.ContainsRune(arg0, filepath.Separator):
		p = arg0
	case arg0 != "":
		if found, err := exec.LookPath(arg0); err == nil {
			p = found
		}
	}
	if p != "" {
		if abs, err := filepath.Abs(p); err == nil {
			if fi, err := os.Stat(abs); err == nil && !fi.IsDir() {
				return abs, nil
			}
		}
	}
	return os.Executable()
}

// findShared returns the absolute path of the file rel that ships with the
// kido binary at exe. Shipped files live under <prefix>/share/kido next to
// <prefix>/bin/kido: the layout Homebrew's `pkgshare.install` produces,
// which `make install` mirrors. The prefix comes from the binary's own
// location rather than from `brew --prefix`, which gives the same answer
// for a Homebrew install with no subprocess and works for any other
// prefix-style install too.
//
// The unresolved path is tried first, and that ordering matters: the path
// found here is written into a config file and has to keep working.
// Homebrew's /opt/homebrew/bin/kido and /opt/homebrew/share/kido are both
// symlinks it repoints at the new Cellar directory on every upgrade, so
// the unresolved spelling stays valid while the resolved one names a
// version directory that the next `brew cleanup` deletes - leaving the
// config pointing at nothing. Resolving is only the fallback, for an
// install whose bin is a symlink somewhere with no share beside it. The
// caller has to pass an unresolved exe for that ordering to mean anything:
// see invokedPath.
func findShared(exe, rel string) (string, error) {
	candidates := []string{exe}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil && resolved != exe {
		candidates = append(candidates, resolved)
	}
	var first string
	for _, c := range candidates {
		parts := append([]string{filepath.Dir(c), "..", "share", "kido"}, strings.Split(rel, "/")...)
		path, err := filepath.Abs(filepath.Join(parts...))
		if err != nil {
			return "", err
		}
		if first == "" {
			first = path
		}
		if fi, err := os.Stat(path); err == nil && !fi.IsDir() {
			return path, nil
		}
	}
	return "", fmt.Errorf("no %s at %s; it ships with kido, so this install looks incomplete", filepath.Base(rel), first)
}

// setMarkedBlock returns rc with the block between begin and end replaced
// by block, and which of "added", "updated" or "unchanged" it did. An
// existing block is rewritten in place - never appended a second time - so
// running a setup command twice, or after the shipped path changes,
// converges. A file holding only one of the two markers is an edit kido
// cannot make sense of, and is an error rather than a guess.
func setMarkedBlock(rc []byte, begin, end, block string) ([]byte, string, error) {
	b := bytes.Index(rc, []byte(begin))
	e := bytes.Index(rc, []byte(end))
	switch {
	case b < 0 && e >= 0:
		return nil, "", fmt.Errorf("has %q without %q", end, begin)
	case b >= 0 && e < 0:
		return nil, "", fmt.Errorf("has %q without %q", begin, end)
	case b >= 0:
		if e < b {
			return nil, "", fmt.Errorf("has %q before %q", end, begin)
		}
		// Swallow the newline the end marker's line ends with, which the
		// replacement carries itself; anything after it is kept as is.
		tail := rc[e+len(end):]
		if len(tail) > 0 && tail[0] == '\n' {
			tail = tail[1:]
		}
		out := append(append([]byte{}, rc[:b]...), block...)
		out = append(out, tail...)
		if bytes.Equal(out, rc) {
			return rc, "unchanged", nil
		}
		return out, "updated", nil
	}

	out := append([]byte{}, rc...)
	if len(out) > 0 {
		if out[len(out)-1] != '\n' {
			out = append(out, '\n')
		}
		out = append(out, '\n') // a blank line between their config and ours
	}
	return append(out, block...), "added", nil
}

// blockSpec describes one setup command's edit: which file in the user's
// home it keeps a marked block in, the markers around that block, the
// block itself for a given path, and how the user makes the change take
// effect.
type blockSpec struct {
	rcName     string                       // e.g. ".zshrc", relative to $HOME
	rel        string                       // the shipped file, under share/kido
	begin, end string                       // the markers around the block
	body       func(string) (string, error) // the whole block, markers included
	reload     string                       // printed last: how to load it, if anything
}

// installBlock is what every setup command that edits a config file does:
// find the file kido ships, then keep a marked block sourcing it in the
// user's config.
//
// Nothing is copied: the package owns the shipped file, so an upgrade
// refreshes it where it lies and the config keeps pointing at the same
// place. The config itself is edited through a symlink on purpose: one
// linked into a dotfiles repo should be edited for real, so the resolved
// path is what the messages print.
func installBlock(spec blockSpec) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	exe, err := invokedPath(os.Args[0])
	if err != nil {
		return err
	}
	shipped, err := findShared(exe, spec.rel)
	if err != nil {
		return err
	}

	rcPath := filepath.Join(home, spec.rcName)
	old, err := os.ReadFile(rcPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	shown := rcPath
	if err == nil {
		// Only meaningful for a file that exists; EvalSymlinks errors
		// otherwise. A plain file resolves to itself.
		if resolved, err := filepath.EvalSymlinks(rcPath); err == nil {
			shown = resolved
		}
	}
	block, err := spec.body(shipped)
	if err != nil {
		return err
	}
	out, action, err := setMarkedBlock(old, spec.begin, spec.end, block)
	if err != nil {
		return fmt.Errorf("%s: %w", shown, err)
	}
	if action == "unchanged" {
		// Not written at all: a no-op run must not touch the file.
		fmt.Printf("%s already sources %s\n", shown, shipped)
	} else {
		if err := os.WriteFile(rcPath, out, 0o644); err != nil {
			return err
		}
		fmt.Printf("%s the kido block sourcing %s in %s\n", action, shipped, shown)
	}
	if spec.reload != "" {
		fmt.Println(spec.reload)
	}
	return nil
}
