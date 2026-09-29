package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"kido/internal/tmux"
)

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
	var first string
	for _, c := range tmux.Candidates(exe) {
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
