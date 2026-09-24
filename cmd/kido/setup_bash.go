package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
)

// The markers around the block setup-bash keeps in the user's rc files.
// They name bash because the block can land in a file zsh reads as well -
// ~/.profile - and the two must be findable apart.
const (
	bashrcBegin = "# >>> kido bash integration >>>"
	bashrcEnd   = "# <<< kido bash integration <<<"
)

// bashrcBlock is the block setup-bash keeps: the source guarded by the
// file being there, because the rc outlives the install. A kido
// uninstalled, or moved by an upgrade that repointed a prefix symlink,
// would otherwise make every new shell start with a "no such file or
// directory" from a line the user did not write and cannot place.
//
// Written in POSIX shell, and guarded on $BASH_VERSION, because the file
// a login bash reads can be ~/.profile - which dash and every other sh
// read too, and which would fail on the first bashism. The integration
// itself is bash, and only bash sources it.
func bashrcBlock(source string) string {
	return fmt.Sprintf(`%s
kido_integration=%q
if [ -n "$BASH_VERSION" ]; then
  if [ -r "$kido_integration" ]; then
    . "$kido_integration"
  else
    printf '%%s\n' "kido: no shell integration at $kido_integration; run: kido setup-bash" >&2
  fi
fi
unset kido_integration
%s
`, bashrcBegin, source, bashrcEnd)
}

// bashLoginFile names the file in home a login bash reads, or "" and why
// it needs nothing. tmux starts a pane's shell as a login shell, and a
// login bash reads the first of ~/.bash_profile, ~/.bash_login and
// ~/.profile that exists - not ~/.bashrc - so the block in ~/.bashrc
// alone would reach no pane at all on a machine whose profile does not
// reach ~/.bashrc itself.
//
// Which file matters: ~/.bash_profile is created only when none of the
// three exists, since creating it in front of an existing ~/.profile
// would stop bash reading that profile at all.
func bashLoginFile(home string) (name, why string) {
	for _, n := range []string{".bash_profile", ".bash_login", ".profile"} {
		b, err := os.ReadFile(filepath.Join(home, n))
		if err != nil {
			continue
		}
		if bytes.Contains(b, []byte(".bashrc")) {
			return "", fmt.Sprintf("~/%s reads ~/.bashrc already, so a login shell gets it from there", n)
		}
		return n, ""
	}
	return ".bash_profile", ""
}

// setupBash installs the bash shell integration by sourcing the script
// that ships with kido from the user's ~/.bashrc, and from the file a
// login shell reads when that is somewhere else.
func setupBash() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	spec := blockSpec{
		rcName: ".bashrc",
		rel:    "shell/bash/integration.bash",
		begin:  bashrcBegin,
		end:    bashrcEnd,
		// %q makes any path safe here, so there is nothing to refuse.
		body: func(source string) (string, error) { return bashrcBlock(source), nil },
		// Printed once at the end instead, the two edits being one change.
		reload: "",
	}
	if err := installBlock(spec); err != nil {
		return err
	}
	if login, why := bashLoginFile(home); why != "" {
		fmt.Println(why)
	} else {
		spec.rcName = login
		if err := installBlock(spec); err != nil {
			return err
		}
	}
	fmt.Println("open a new pane (or run `exec bash`) to load it")
	return nil
}
