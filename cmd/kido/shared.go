package main

import (
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
// the path kido writes into the server's configuration, or puts on a
// pane's PATH, would name a directory the next `brew cleanup` deletes.
// argv[0] keeps the spelling: used as-is when it has a separator, looked
// up on PATH when it does not. os.Executable stays the fallback, for a
// caller that cleared argv[0] or a lookup that fails.
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
// found here outlives the call - it goes into the server's configuration,
// and on the PATH of every pane. Homebrew's /opt/homebrew/bin/kido and
// /opt/homebrew/share/kido are both symlinks it repoints at the new Cellar
// directory on every upgrade, so the unresolved spelling stays valid while
// the resolved one names a version directory that the next `brew cleanup`
// deletes. Resolving is only the fallback, for an install whose bin is a
// symlink somewhere with no share beside it. The caller has to pass an
// unresolved exe for that ordering to mean anything: see invokedPath.
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
