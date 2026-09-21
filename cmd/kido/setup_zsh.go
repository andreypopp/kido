package main

import "fmt"

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

// setupZsh installs the zsh shell integration by sourcing the script that
// ships with kido from the user's ~/.zshrc.
func setupZsh() error {
	return installBlock(blockSpec{
		rcName: ".zshrc",
		rel:    "shell/zsh/integration.zsh",
		begin:  zshrcBegin,
		end:    zshrcEnd,
		// %q makes any path safe here, so there is nothing to refuse.
		body:   func(source string) (string, error) { return zshrcBlock(source), nil },
		reload: "open a new pane (or run `exec zsh`) to load it",
	})
}
