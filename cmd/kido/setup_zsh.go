package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
)

// The markers around the block setup-zsh keeps in ~/.zshrc. They are what
// makes the edit idempotent: the block can be found again, rewritten when
// the path changes, and removed by hand without leaving anything behind.
const (
	zshrcBegin = "# >>> kido shell integration >>>"
	zshrcEnd   = "# <<< kido shell integration <<<"
)

// zshrcBlock is the block setup-zsh keeps in ~/.zshrc: the source guarded
// by the file being there, because the rc outlives the install. A kido
// uninstalled, or moved by an upgrade that repointed a prefix symlink,
// would otherwise make every new shell start with a "no such file or
// directory" from a line the user did not write and cannot place.
//
// The path goes in a variable rather than three times over, so nothing
// can drift, and is unset again so the rc leaves nothing behind. zsh does
// not word-split an unquoted parameter, so the uses need no quoting.
func zshrcBlock(source string) string {
	return fmt.Sprintf(`%s
kido_integration=%q
if [[ -r $kido_integration ]]; then
  source $kido_integration
else
  print -u2 "kido: no shell integration at $kido_integration; run: kido setup-zsh"
fi
unset kido_integration
%s
`, zshrcBegin, source, zshrcEnd)
}

// findIntegration returns the absolute path of the zsh integration script
// that ships with the kido binary at exe. It lives at
// <prefix>/share/kido/shell/zsh/integration.zsh next to <prefix>/bin/kido:
// the layout Homebrew's `pkgshare.install "shell"` produces, which `make
// install` mirrors. The prefix comes from the binary's own location rather
// than from `brew --prefix`, which gives the same answer for a Homebrew
// install with no subprocess and works for any other prefix-style install
// too.
//
// The unresolved path is tried first, and that ordering matters: the path
// found here is written into ~/.zshrc and has to keep working. Homebrew's
// /opt/homebrew/bin/kido and /opt/homebrew/share/kido are both symlinks it
// repoints at the new Cellar directory on every upgrade, so the unresolved
// spelling stays valid while the resolved one names a version directory
// that the next `brew cleanup` deletes - leaving every new shell printing
// a "no such file" from the rc. Resolving is only the fallback, for an
// install whose bin is a symlink somewhere with no share beside it.
func findIntegration(exe string) (string, error) {
	candidates := []string{exe}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil && resolved != exe {
		candidates = append(candidates, resolved)
	}
	var first string
	for _, c := range candidates {
		path, err := filepath.Abs(filepath.Join(filepath.Dir(c), "..", "share", "kido", "shell", "zsh", "integration.zsh"))
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
	return "", fmt.Errorf("no zsh integration script at %s; it ships with kido, so this install looks incomplete", first)
}

// setupZsh installs the zsh shell integration by sourcing the script that
// ships with kido from the user's ~/.zshrc.
//
// Nothing is copied: the package owns the script, so an upgrade refreshes
// it where it lies and the .zshrc line keeps pointing at the same place.
// The .zshrc itself is edited through a symlink on purpose: one linked
// into a dotfiles repo should be edited for real, so the resolved path is
// what the messages print.
func setupZsh() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	script, err := findIntegration(exe)
	if err != nil {
		return err
	}

	rcPath := filepath.Join(home, ".zshrc")
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
	out, action, err := setZshrcBlock(old, script)
	if err != nil {
		return fmt.Errorf("%s: %w", shown, err)
	}
	if action == "unchanged" {
		// Not written at all: a no-op run must not touch the file.
		fmt.Printf("%s already sources %s\n", shown, script)
	} else {
		if err := os.WriteFile(rcPath, out, 0o644); err != nil {
			return err
		}
		fmt.Printf("%s the kido block sourcing %s in %s\n", action, script, shown)
	}
	fmt.Println("open a new pane (or run `exec zsh`) to load it")
	return nil
}

// setZshrcBlock returns rc with the kido block sourcing source, and which
// of "added", "updated" or "unchanged" it did. An existing block is
// rewritten in place - never appended a second time - so running setup-zsh
// twice, or after the script path changes, converges. A file holding only
// one of the two markers is an edit kido cannot make sense of, and is an
// error rather than a guess.
func setZshrcBlock(rc []byte, source string) ([]byte, string, error) {
	block := zshrcBlock(source)

	begin := bytes.Index(rc, []byte(zshrcBegin))
	end := bytes.Index(rc, []byte(zshrcEnd))
	switch {
	case begin < 0 && end >= 0:
		return nil, "", fmt.Errorf("has %q without %q", zshrcEnd, zshrcBegin)
	case begin >= 0 && end < 0:
		return nil, "", fmt.Errorf("has %q without %q", zshrcBegin, zshrcEnd)
	case begin >= 0:
		if end < begin {
			return nil, "", fmt.Errorf("has %q before %q", zshrcEnd, zshrcBegin)
		}
		// Swallow the newline the end marker's line ends with, which the
		// replacement carries itself; anything after it is kept as is.
		tail := rc[end+len(zshrcEnd):]
		if len(tail) > 0 && tail[0] == '\n' {
			tail = tail[1:]
		}
		out := append(append([]byte{}, rc[:begin]...), block...)
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
		out = append(out, '\n') // a blank line between their rc and ours
	}
	return append(out, block...), "added", nil
}
